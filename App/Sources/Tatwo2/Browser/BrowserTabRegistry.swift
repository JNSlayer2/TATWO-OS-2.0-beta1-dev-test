import Foundation
import Combine
import AppKit

// All browser surfaces share these records; engine/profile state stays outside the registry.
enum BrowserTabOwner: Codable, Hashable {
    case workSpace(spaceID: UUID)
    case chatSession(sessionID: String)
    case bot(botID: String)
}

struct BrowserTab: Codable, Identifiable, Equatable {
    let id: UUID
    var owner: BrowserTabOwner
    var url: URL?
    var title: String
    var faviconPNG: Data?
    var isPinned: Bool
    var isSleeping: Bool
    var lastActiveAt: Date
    var createdAt: Date
    var folderID: UUID? = nil
    // W58: absent in old indexes means human. Never infer actor from who navigated last.
    var isAgentTab: Bool? = nil
    var usesAgentContext: Bool {
        if case .workSpace = owner { return false }
        return isAgentTab == true
    }
}

struct BrowserSpace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var folders: [BrowserFolder]
    var isSessionSpace: Bool
}

struct BrowserFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var bookmarks: [BrowserBookmark]
}

struct BrowserBookmark: Codable, Identifiable, Equatable {
    let id: UUID
    var url: URL
    var title: String
}

struct BrowserLaneSnapshot: Codable, Equatable {
    var laneState: TatwoBrowserLaneState
    var laneURLs: [String: URL]
    var updatedAt: Date
    var openURLs: [URL] { laneState.lanes.compactMap { laneURLs[$0.id.rawValue] } }
}

struct OpenBrowserSessionSummary: Identifiable {
    let sessionID: String
    let threadTitle: String
    let projectName: String
    let laneCount: Int
    let urls: [URL]
    let updatedAt: Date
    var id: String { sessionID }
}

@MainActor
final class BrowserTabRegistry: ObservableObject {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TATWO OS/Browser/tabs.json")
    static let shared = BrowserTabRegistry(storageURL: defaultURL)
    static let sessionSpaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000046")!
    typealias TitleProvider = (String) -> (threadTitle: String, projectName: String)

    @Published private(set) var spaces: [BrowserSpace] = []
    @Published private(set) var tabs: [BrowserTab] = []
    struct ClosedTab: Equatable {
        let url: URL?
        let title: String
        let owner: BrowserTabOwner
        let folderID: UUID?
        var isAgentTab: Bool? = nil
    }
    @Published private(set) var recentlyClosed: [ClosedTab] = []
    private func rememberClosed(_ tab: BrowserTab) {
        if case .bot = tab.owner { return }
        recentlyClosed.append(ClosedTab(url: tab.url, title: tab.title, owner: tab.owner,
                                       folderID: tab.folderID, isAgentTab: tab.isAgentTab))
        recentlyClosed = Array(recentlyClosed.suffix(10))
    }
    @discardableResult
    func reopenClosedTab(owner: BrowserTabOwner? = nil) -> BrowserTab? {
        guard let index = recentlyClosed.lastIndex(where: { (owner == nil || $0.owner == owner) && accepts($0.owner) }) else { return nil }
        let record = recentlyClosed.remove(at: index)
        let tab = openTab(owner: record.owner, url: record.url, title: record.title, folderID: record.folderID,
                          isAgentTab: record.isAgentTab == true)
        select(tab.id)
        return tabs.first { $0.id == tab.id }
    }
    @Published private(set) var persistenceError: String?
    /// Post-mutation event: projections never read the old value from @Published's willSet.
    let changes = PassthroughSubject<Void, Never>()
    var titleProvider: TitleProvider

    private struct LaneIdentity: Codable {
        var sessionID: String
        var rawID: String
        var binding: TatwoBrowserLaneBinding
    }
    private struct SessionState: Codable {
        var schemaVersion: Int
        var maximumLaneCount: Int
        var selectedLaneID: TatwoBrowserLaneID?
        var updatedAt: Date
    }
    private struct StoredTab: Codable {
        var tab: BrowserTab
        var faviconFile: String?
    }
    private struct Document: Codable {
        var schemaVersion = 1
        var spaces: [BrowserSpace]
        var tabs: [StoredTab]
        var laneIdentities: [UUID: LaneIdentity]
        var sessions: [String: SessionState]
        var retiredLanes: [String: Set<String>]
        var legacyImported: Bool
        var bookmarksImported: Bool? = false
        /// Lane raw IDs the embedded panel has already reported per session; only those may be
        /// removed by a later snapshot. A tab moved into the session stays until the panel sees it.
        var storedLaneIDs: [String: Set<String>]? = [:]
    }
    private struct LegacyDocument: Decodable {
        var browserLanesBySession: [String: BrowserLaneSnapshot]
    }
    private var laneIdentities: [UUID: LaneIdentity] = [:]
    private var sessions: [String: SessionState] = [:]
    private var retiredLanes: [String: Set<String>] = [:]
    private var storedLaneIDs: [String: Set<String>] = [:]
    private var legacyImported = false
    private var bookmarksImported = false
    private let storageURL: URL?
    private var pendingSave: Task<Void, Never>?
    private var writable = true
    private var terminationObservation: AnyCancellable?

    /// nil storage is deliberately ephemeral (fixtures/previews). No production data is touched.
    /// The old implementation was memory-only. legacyURL accepts an explicitly supplied export;
    /// the sibling filename is a compatibility inbox, not a claimed historical app location.
    init(storageURL: URL? = nil, legacyURL: URL? = nil,
         titleProvider: @escaping TitleProvider = { _ in ("（已不存在的討論串）", "") }) {
        self.storageURL = storageURL
        self.titleProvider = titleProvider
        let exists = storageURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if let storageURL, exists {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: storageURL))
                guard document.schemaVersion == 1,
                      Set(document.spaces.map(\.id)).count == document.spaces.count,
                      Set(document.tabs.map { $0.tab.id }).count == document.tabs.count,
                      document.spaces.filter(\.isSessionSpace).count <= 1 else { throw CocoaError(.coderReadCorrupt) }
                spaces = document.spaces
                laneIdentities = document.laneIdentities
                sessions = document.sessions
                retiredLanes = document.retiredLanes
                storedLaneIDs = document.storedLaneIDs ?? [:]
                legacyImported = document.legacyImported
                bookmarksImported = document.bookmarksImported ?? false
                tabs = document.tabs.map { stored in
                    var tab = stored.tab
                    if stored.faviconFile == "\(tab.id.uuidString).png" {
                        tab.faviconPNG = try? Data(contentsOf: storageURL.deletingLastPathComponent()
                            .appendingPathComponent("favicons/\(tab.id.uuidString).png"))
                    }
                    return tab
                }
            } catch {
                writable = false // Never overwrite a corrupt or newer-schema document.
                persistenceError = "Browser registry load failed: \(error.localizedDescription)"
            }
        }
        if !spaces.contains(where: \.isSessionSpace) {
            spaces.append(BrowserSpace(id: Self.sessionSpaceID, name: "Session space", folders: [], isSessionSpace: true))
        }
        if !exists && tabs.isEmpty && spaces.allSatisfy(\.isSessionSpace) {
            spaces.insert(BrowserSpace(id: UUID(), name: "一般", folders: [BrowserFolder(id: UUID(), name: "新資料夾", bookmarks: [])], isSessionSpace: false), at: 0)
        }
        let inbox = legacyURL ?? storageURL?.deletingLastPathComponent().appendingPathComponent("browserLanesBySession.json")
        if writable, let inbox, FileManager.default.fileExists(atPath: inbox.path) {
            do { try migrateLegacy(at: inbox) }
            catch { persistenceError = "Browser migration failed: \(error.localizedDescription)" }
        }
        if !exists && writable { changed() }
        terminationObservation = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                do { try self.flush() } catch { self.persistenceError = error.localizedDescription }
            }
    }

    func tabs(ownedBy owner: BrowserTabOwner) -> [BrowserTab] { tabs.filter { $0.owner == owner } }
    /// Public tab UUIDs differ from legacy chat lane IDs used by the CEF host.
    /// Resolve only current records; a moved workspace tab uses its UUID.
    func runtimeTabID(for id: UUID) -> String? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        func key(_ tab: BrowserTab) -> String {
            if case .chatSession = tab.owner { return laneIdentities[tab.id]?.rawID ?? tab.id.uuidString }
            return tab.id.uuidString
        }
        let runtimeID = key(tab)
        // Legacy imports can contain the same raw ID in different sessions.
        // CEF callbacks only carry this ID: ambiguity must never select another chat's page.
        guard !tabs.contains(where: { $0.id != id && key($0) == runtimeID }) else { return nil }
        return runtimeID
    }
    private func accepts(_ owner: BrowserTabOwner) -> Bool {
        if case let .workSpace(id) = owner { return spaces.contains { $0.id == id && !$0.isSessionSpace } }
        return true
    }
    @discardableResult
    func openTab(owner: BrowserTabOwner, url: URL? = nil, title: String = "新分頁", folderID: UUID? = nil,
                 isAgentTab: Bool = false) -> BrowserTab {
        let now = Date()
        let tab = BrowserTab(id: UUID(), owner: owner, url: url, title: title, isPinned: false,
                             isSleeping: true, lastActiveAt: now, createdAt: now, folderID: folderID,
                             isAgentTab: isAgentTab ? true : nil)
        guard accepts(owner) else { return tab } // Session space is a read-only aggregate, never an owner.
        if case let .chatSession(sessionID) = owner {
            laneIdentities[tab.id] = LaneIdentity(sessionID: sessionID, rawID: tab.id.uuidString, binding: .unboundReadOnly)
        }
        tabs.append(tab)
        changed()
        return tab
    }

    /// AI navigation selects an isolated tab; it never converts the selected human tab.
    func tabForAgentNavigation(ownedBy owner: BrowserTabOwner) -> BrowserTab? {
        if case .workSpace = owner { return nil }
        let tab = selectedTab(ownedBy: owner).flatMap { $0.usesAgentContext ? $0 : nil }
            ?? tabs(ownedBy: owner).filter(\.usesAgentContext).max { $0.lastActiveAt < $1.lastActiveAt }
            ?? openTab(owner: owner, title: "AI 分頁", isAgentTab: true)
        select(tab.id)
        return tab
    }
    func selectedTab(ownedBy owner: BrowserTabOwner) -> BrowserTab? {
        let owned = tabs(ownedBy: owner)
        if case let .chatSession(sessionID) = owner,
           let selected = sessions[sessionID]?.selectedLaneID,
           let tab = owned.first(where: { (laneIdentities[$0.id]?.rawID ?? $0.id.uuidString) == selected.rawValue }) {
            return tab
        }
        return owned.max { $0.lastActiveAt < $1.lastActiveAt }
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if case let .chatSession(sessionID) = tab.owner {
            var state = sessions[sessionID] ?? SessionState(schemaVersion: 1, maximumLaneCount: 8,
                selectedLaneID: nil, updatedAt: Date())
            state.selectedLaneID = TatwoBrowserLaneID(rawValue: laneIdentities[id]?.rawID ?? id.uuidString)
            state.updatedAt = Date()
            sessions[sessionID] = state
        }
        touch(id)
    }

    func close(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        rememberClosed(tab)
        tabs.removeAll { $0.id == id }
        removeEmptySession(tab.owner)
        changed()
    }
    func closeAll(ownedBy owner: BrowserTabOwner) {
        for tab in tabs(ownedBy: owner) { rememberClosed(tab) }
        tabs.removeAll { $0.owner == owner }
        if case let .chatSession(id) = owner { sessions.removeValue(forKey: id) }
        changed()
    }
    func move(_ id: UUID, to owner: BrowserTabOwner) {
        guard accepts(owner), let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].owner != owner else { return }
        // Moving a credential-bearing AI tab into a human space must not relabel its context.
        if tabs[index].usesAgentContext, case .workSpace = owner { return }
        let previous = tabs[index].owner
        if case let .chatSession(sessionID) = previous {
            retiredLanes[sessionID, default: []].insert(laneIdentities[id]?.rawID ?? id.uuidString)
        }
        // A goal binding belongs to its original chat, not to the destination session.
        if case let .chatSession(sessionID) = owner {
            laneIdentities[id] = LaneIdentity(sessionID: sessionID, rawID: id.uuidString, binding: .unboundReadOnly)
        }
        tabs[index].owner = owner
        removeEmptySession(previous)
        changed()
    }
    private func removeEmptySession(_ owner: BrowserTabOwner) {
        if case let .chatSession(id) = owner, tabs(ownedBy: owner).isEmpty { sessions.removeValue(forKey: id) }
    }
    func update(_ id: UUID, url: URL?, title: String, favicon: Data?) {
        guard let tab = tabs.first(where: { $0.id == id }),
              tab.url != url || tab.title != title || tab.faviconPNG != favicon else { return }
        edit(id) { $0.url = url; $0.title = title; $0.faviconPNG = favicon }
    }
    func markSleeping(_ id: UUID, _ sleeping: Bool) { edit(id) { $0.isSleeping = sleeping } }
    /// Disk records describe tabs, not live engine instances. Call once before any launch surface mounts.
    func prepareForLaunch() {
        for index in tabs.indices { tabs[index].isSleeping = true }
        if !tabs.isEmpty { changed() }
    }
    func touch(_ id: UUID) { edit(id) { $0.lastActiveAt = Date() } }
    func setPinned(_ id: UUID, _ pinned: Bool) { edit(id) { $0.isPinned = pinned } }
    private func edit(_ id: UUID, _ body: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&tabs[index]); changed()
    }

    @discardableResult
    func addSpace(name: String) -> BrowserSpace {
        let space = BrowserSpace(id: UUID(), name: name, folders: [], isSessionSpace: false)
        spaces.append(space); changed(); return space
    }
    func renameSpace(_ id: UUID, to name: String) {
        guard let i = spaces.firstIndex(where: { $0.id == id && !$0.isSessionSpace }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        spaces[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines); changed()
    }
    func removeSpace(_ id: UUID, closingTabs: Bool) {
        guard spaces.contains(where: { $0.id == id && !$0.isSessionSpace }) else { return }
        // With closingTabs=false preserve the space until its tabs have been moved by the caller.
        guard closingTabs || tabs(ownedBy: .workSpace(spaceID: id)).isEmpty else { return }
        tabs.removeAll { $0.owner == .workSpace(spaceID: id) }
        spaces.removeAll { $0.id == id }; changed()
    }
    @discardableResult
    func addFolder(spaceID: UUID, name: String = "新資料夾") -> BrowserFolder? {
        guard let i = spaces.firstIndex(where: { $0.id == spaceID && !$0.isSessionSpace }) else { return nil }
        let folder = BrowserFolder(id: UUID(), name: name, bookmarks: [])
        spaces[i].folders.append(folder); changed(); return folder
    }
    private func folderLocation(_ id: UUID) -> (Int, Int)? {
        for (s, space) in spaces.enumerated() where !space.isSessionSpace {
            if let f = space.folders.firstIndex(where: { $0.id == id }) { return (s, f) }
        }
        return nil
    }
    func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let (s, f) = folderLocation(id) else { return }
        spaces[s].folders[f].name = name; changed()
    }
    @discardableResult
    func addBookmark(folderID: UUID, url: URL, title: String) -> BrowserBookmark? {
        guard let (s, f) = folderLocation(folderID) else { return nil }
        let bookmark = BrowserBookmark(id: UUID(), url: url, title: title)
        spaces[s].folders[f].bookmarks.append(bookmark); changed(); return bookmark
    }
    func removeBookmark(_ id: UUID) {
        for s in spaces.indices {
            for f in spaces[s].folders.indices { spaces[s].folders[f].bookmarks.removeAll { $0.id == id } }
        }
        changed()
    }
    @discardableResult
    func moveTabToBookmark(tabID: UUID, folderID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }), let url = tab.url,
              addBookmark(folderID: folderID, url: url, title: tab.title) != nil else { return false }
        close(tabID); return true
    }

    var openSessions: [OpenBrowserSessionSummary] {
        Set(tabs.compactMap { tab -> String? in
            if case let .chatSession(id) = tab.owner { return id }; return nil
        }).compactMap { id in
            let owned = tabs(ownedBy: .chatSession(sessionID: id))
            let urls = owned.compactMap(\.url)
            guard !owned.isEmpty else { return nil }
            let title = titleProvider(id)
            return OpenBrowserSessionSummary(sessionID: id, threadTitle: title.threadTitle, projectName: title.projectName,
                laneCount: owned.count, urls: urls, updatedAt: max(owned.map(\.lastActiveAt).max() ?? .distantPast, sessions[id]?.updatedAt ?? .distantPast))
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.sessionID < $1.sessionID : $0.updatedAt > $1.updatedAt }
    }

    var chatSessionIDs: Set<String> {
        Set(sessions.keys).union(tabs.compactMap { if case let .chatSession(id) = $0.owner { return id }; return nil })
    }
    func laneSnapshot(for sessionID: String) -> BrowserLaneSnapshot? {
        let owned = tabs(ownedBy: .chatSession(sessionID: sessionID))
        guard !owned.isEmpty || sessions[sessionID] != nil else { return nil }
        let state = sessions[sessionID]
        let lanes = owned.map { tab in
            TatwoBrowserLane(id: TatwoBrowserLaneID(rawValue: laneIdentities[tab.id]?.rawID ?? tab.id.uuidString),
                binding: laneIdentities[tab.id]?.binding ?? .unboundReadOnly, title: tab.title, isPinned: tab.isPinned,
                createdAt: tab.createdAt, lastActiveAt: tab.lastActiveAt)
        }
        let urls = Dictionary(uniqueKeysWithValues: zip(lanes, owned).compactMap { lane, tab in tab.url.map { (lane.id.rawValue, $0) } })
        return BrowserLaneSnapshot(laneState: TatwoBrowserLaneState(schemaVersion: state?.schemaVersion ?? 1,
            maximumLaneCount: max(state?.maximumLaneCount ?? 8, lanes.count), lanes: lanes, selectedLaneID: state?.selectedLaneID),
            laneURLs: urls, updatedAt: max(state?.updatedAt ?? .distantPast, owned.map(\.lastActiveAt).max() ?? .distantPast))
    }
    func storeLanes(_ snapshot: BrowserLaneSnapshot, for sessionID: String) {
        if let old = laneSnapshot(for: sessionID), old.laneState == snapshot.laneState, old.laneURLs == snapshot.laneURLs { return }
        let owner = BrowserTabOwner.chatSession(sessionID: sessionID)
        var replacement: [BrowserTab] = []
        for lane in snapshot.laneState.lanes {
            let known = laneIdentities.first { $0.value.sessionID == sessionID && $0.value.rawID == lane.id.rawValue }?.key
                ?? tabs.first { $0.owner == owner && $0.id.uuidString == lane.id.rawValue }?.id
            // Returning a tab to its original chat makes its identity valid again.
            if retiredLanes[sessionID]?.contains(lane.id.rawValue) == true,
               !tabs.contains(where: { $0.id == known && $0.owner == owner }) { continue }
            // A stale embedded panel must not resurrect closed tabs or steal moved tabs back.
            if let known, !tabs.contains(where: { $0.id == known && $0.owner == owner }) { continue }
            let id = known ?? UUID()
            let old = tabs.first { $0.id == id }
            laneIdentities[id] = LaneIdentity(sessionID: sessionID, rawID: lane.id.rawValue, binding: lane.binding)
            replacement.append(BrowserTab(id: id, owner: owner, url: snapshot.laneURLs[lane.id.rawValue], title: lane.title,
                faviconPNG: old?.faviconPNG, isPinned: lane.isPinned, isSleeping: old?.isSleeping ?? false,
                lastActiveAt: lane.lastActiveAt, createdAt: lane.createdAt, isAgentTab: old?.isAgentTab))
        }
        if replacement.isEmpty, !snapshot.laneState.lanes.isEmpty, tabs(ownedBy: owner).isEmpty { return }
        // Tabs the panel never reported (e.g. moved in from another owner) are kept; the panel
        // picks them up on its next laneSnapshot read and only then may close them.
        let seen = storedLaneIDs[sessionID] ?? []
        let replacementIDs = Set(replacement.map(\.id))
        let kept = tabs.filter { tab in
            tab.owner == owner && !replacementIDs.contains(tab.id)
                && !seen.contains(laneIdentities[tab.id]?.rawID ?? tab.id.uuidString)
        }
        tabs.removeAll { $0.owner == owner }
        tabs.append(contentsOf: replacement)
        tabs.append(contentsOf: kept)
        storedLaneIDs[sessionID] = Set(replacement.compactMap { laneIdentities[$0.id]?.rawID })
        sessions[sessionID] = SessionState(schemaVersion: snapshot.laneState.schemaVersion,
            maximumLaneCount: snapshot.laneState.maximumLaneCount, selectedLaneID: snapshot.laneState.selectedLaneID, updatedAt: snapshot.updatedAt)
        changed()
    }

    private func changed() {
        changes.send()
        pendingSave?.cancel()
        guard storageURL != nil, writable else { return }
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, let storageURL = self.storageURL else { return }
            // Encode and write off the main actor; only the value snapshot is taken here.
            let payload = self.savePayload()
            let result = await Task.detached(priority: .utility) { () -> String? in
                do { try Self.write(payload, to: storageURL); return nil }
                catch { return error.localizedDescription }
            }.value
            self.persistenceError = result.map { "Browser registry save failed: \($0)" }
        }
    }
    private struct SavePayload: Sendable {
        var documentData: Data
        var favicons: [(file: String, data: Data)]
    }
    private func savePayload() -> SavePayload {
        var favicons: [(String, Data)] = []
        let stored = tabs.map { tab -> StoredTab in
            var copy = tab
            copy.faviconPNG = nil
            let filename = tab.faviconPNG.map { _ in "\(tab.id.uuidString).png" }
            if let data = tab.faviconPNG, let filename { favicons.append((filename, data)) }
            return StoredTab(tab: copy, faviconFile: filename)
        }
        let document = Document(spaces: spaces, tabs: stored, laneIdentities: laneIdentities, sessions: sessions,
                                retiredLanes: retiredLanes, legacyImported: legacyImported, bookmarksImported: bookmarksImported, storedLaneIDs: storedLaneIDs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Encoding a value type cannot fail here except for programmer error; surface it as empty data.
        return SavePayload(documentData: (try? encoder.encode(document)) ?? Data(), favicons: favicons.map { (file: $0.0, data: $0.1) })
    }
    private nonisolated static func write(_ payload: SavePayload, to storageURL: URL) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("favicons"), withIntermediateDirectories: true)
        for favicon in payload.favicons {
            try favicon.data.write(to: directory.appendingPathComponent("favicons/\(favicon.file)"), options: .atomic)
        }
        guard !payload.documentData.isEmpty else { throw CocoaError(.coderInvalidValue) }
        try payload.documentData.write(to: storageURL, options: .atomic)
    }
    /// Synchronous durability barrier for migration, tests and app termination.
    func flush() throws {
        pendingSave?.cancel(); pendingSave = nil
        guard let storageURL else { return }
        guard writable else { throw CocoaError(.fileWriteNoPermission) }
        try Self.write(savePayload(), to: storageURL)
        persistenceError = nil
    }
    private struct LegacyBookmark: Decodable {
        let id: UUID
        let profileKey: UUID
        let url: String
        let title: String
        let createdAt: Date
    }

    /// Called once startup has loaded thread titles. Commit before rename; a rename failure
    /// can retry after restart without importing twice. Unknown profiles are never discarded.
    func migrateLegacyBookmarks(at url: URL, sessionIDs: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard storageURL != nil, writable else { throw CocoaError(.fileWriteNoPermission) }
        let backup = url.appendingPathExtension("migrated")
        guard !FileManager.default.fileExists(atPath: backup.path) else { throw CocoaError(.fileWriteFileExists) }
        if !bookmarksImported {
            let data = try Data(contentsOf: url)
            guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.coderReadCorrupt) }
            let bookmarks = try JSONDecoder().decode([LegacyBookmark].self, from: data)
            var profiles: [UUID: String] = [:]
            for id in sessionIDs.union(chatSessionIDs).sorted() {
                if let identity = TatwoBrowserProfileIdentity(sessionID: id) { profiles[identity.dataStoreIdentifier] = id }
            }
            guard Set(bookmarks.map(\.id)).count == bookmarks.count,
                  bookmarks.allSatisfy({ profiles[$0.profileKey] != nil && URL(string: $0.url) != nil }) else {
                throw CocoaError(.coderReadCorrupt)
            }
            let previousSpaces = spaces
            if !bookmarks.isEmpty {
                if !spaces.contains(where: { !$0.isSessionSpace }) { _ = addSpace(name: "一般") }
                let index = spaces.firstIndex { !$0.isSessionSpace }!
                for (profile, values) in Dictionary(grouping: bookmarks, by: \.profileKey).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                    let title = titleProvider(profiles[profile]!).threadTitle
                    spaces[index].folders.append(BrowserFolder(id: UUID(), name: "chat 書籤 · \(title)",
                        bookmarks: values.sorted { $0.createdAt < $1.createdAt }.map {
                            BrowserBookmark(id: $0.id, url: URL(string: $0.url)!, title: $0.title)
                        }))
                }
            }
            bookmarksImported = true
            do { try flush() }
            catch { spaces = previousSpaces; bookmarksImported = false; throw error }
            changes.send()
        } else { try flush() }
        try FileManager.default.moveItem(at: url, to: backup)
    }

    struct RemovedBookmark {
        let bookmark: BrowserBookmark
        let folderID: UUID
        let index: Int
    }
    func bookmarkRemoval(_ id: UUID) -> RemovedBookmark? {
        for space in spaces where !space.isSessionSpace {
            for folder in space.folders {
                if let index = folder.bookmarks.firstIndex(where: { $0.id == id }) {
                    return RemovedBookmark(bookmark: folder.bookmarks[index], folderID: folder.id, index: index)
                }
            }
        }
        return nil
    }
    @discardableResult
    func restoreBookmark(_ removed: RemovedBookmark) -> Bool {
        guard let (s, f) = folderLocation(removed.folderID), bookmarkRemoval(removed.bookmark.id) == nil else { return false }
        spaces[s].folders[f].bookmarks.insert(removed.bookmark, at: min(removed.index, spaces[s].folders[f].bookmarks.count))
        changed()
        return true
    }

    func migrateLegacy(at url: URL) throws {
        guard storageURL != nil, writable else { throw CocoaError(.fileWriteNoPermission) }
        let backup = url.appendingPathExtension("migrated")
        guard !FileManager.default.fileExists(atPath: backup.path) else { throw CocoaError(.fileWriteFileExists) }
        if !legacyImported {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let legacy: [String: BrowserLaneSnapshot]
            if let wrapped = try? decoder.decode(LegacyDocument.self, from: data) { legacy = wrapped.browserLanesBySession }
            else { legacy = try decoder.decode([String: BrowserLaneSnapshot].self, from: data) }
            // An export must never silently replace (or be discarded over) newer live tabs.
            for (id, snapshot) in legacy {
                if let current = laneSnapshot(for: id), current != snapshot { throw CocoaError(.fileWriteFileExists) }
            }
            for (id, snapshot) in legacy where laneSnapshot(for: id) == nil { storeLanes(snapshot, for: id) }
            guard legacy.allSatisfy({ laneSnapshot(for: $0.key) == $0.value }) else {
                throw CocoaError(.fileWriteFileExists) // Retired identities require explicit reconciliation.
            }
            legacyImported = true
        }
        try flush() // Commit first; a failed rename is retried without reimporting on next launch.
        try FileManager.default.moveItem(at: url, to: backup)
    }
}
