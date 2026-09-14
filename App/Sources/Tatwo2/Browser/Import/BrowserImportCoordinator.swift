import Combine
import Foundation

struct BrowserImportCount: Equatable, Sendable {
    var total: Int?
    var imported = 0
    var updated = 0
    var skipped = 0
    var finished = false
    var reason: String?
    mutating func note(_ text: String) {
        guard reason?.contains(text) != true else { return }
        reason = reason.map { $0 + " " + text } ?? text
    }
    var processed: Int { imported + updated + skipped }
    var label: String {
        if total == nil && !finished { return "等待讀取" }
        return "新增 \(imported) · 更新 \(updated) · 略過 \(skipped)"
    }
}

struct BrowserImportProgress: Equatable, Sendable {
    var kinds: [ImportData] = []
    var counts: [ImportData: BrowserImportCount] = [:]
    var fraction: Double {
        guard !kinds.isEmpty else { return 0 }
        return kinds.reduce(0.0) { value, kind in
            let count = counts[kind] ?? BrowserImportCount()
            if count.finished { return value + 1 }
            guard let total = count.total, total > 0 else { return value }
            return value + min(1, Double(count.processed) / Double(total))
        } / Double(kinds.count)
    }
}

struct BrowserImportSummary: Equatable, Sendable {
    let progress: BrowserImportProgress
    let extensions: [ImportedExtension]
    let cancelled: Bool
    var hasIssues: Bool { progress.counts.values.contains { $0.reason != nil || $0.skipped > 0 } }
}

enum BrowserImportState: Equatable, Sendable {
    case idle, chooseSource, chooseData, keychainNotice
    case running(progress: BrowserImportProgress)
    case done(summary: BrowserImportSummary)
    case failed(reason: String)

    var step: Int {
        switch self {
        case .idle, .chooseSource: 1
        case .chooseData: 2
        case .keychainNotice: 3
        case .running, .done, .failed: 4
        }
    }
}

@MainActor
final class BrowserImportCoordinator: ObservableObject {
    @Published private(set) var state: BrowserImportState = .idle
    @Published private(set) var sources: [BrowserImportSourceInfo] = []
    @Published private(set) var source: BrowserImportSource?
    @Published private(set) var profileID: String?
    @Published private(set) var selectedData: Set<ImportData> = [.bookmarks, .history]
    @Published private(set) var spaceID: UUID?
    @Published private(set) var hasPasswordFile = false
    @Published private(set) var passwordFileMessage: String?
    @Published private(set) var cancelRequested = false
    @Published private(set) var progress = BrowserImportProgress()
    private(set) var listedExtensions: [ImportedExtension] = []
    private let registry: BrowserTabRegistry
    private let vault: BrowserPasswordVault
    private let historyStore: BrowserHistoryStore
    private let importer: ChromiumImporter
    private let sourceFixtures: [BrowserImportSourceInfo]?
    private var passwordFile: URL?
    private var task: Task<Void, Never>?

    init(spaceID: UUID? = nil, registry: BrowserTabRegistry? = nil, vault: BrowserPasswordVault? = nil,
         historyStore: BrowserHistoryStore = .shared, importer: ChromiumImporter = ChromiumImporter(),
         sources: [BrowserImportSourceInfo]? = nil) {
        let registry = registry ?? .shared
        self.registry = registry
        self.vault = vault ?? .shared
        self.historyStore = historyStore
        self.importer = importer
        self.sourceFixtures = sources
        self.spaceID = spaceID ?? registry.spaces.first(where: { !$0.isSessionSpace })?.id
    }

    var destinationSpaces: [BrowserSpace] { registry.spaces.filter { !$0.isSessionSpace } }
    var selectedSourceInfo: BrowserImportSourceInfo? { sources.first { $0.source == source } }
    var profile: BrowserImportProfile? { selectedSourceInfo?.profiles.first { $0.id == profileID } }
    var isRunning: Bool { if case .running = state { return true }; return false }
    var canGoBack: Bool { state == .chooseData || state == .keychainNotice }
    var canAdvance: Bool {
        switch state {
        case .chooseSource: return selectedSourceInfo?.canSelect == true && profile != nil
        case .chooseData: return !selectedData.isEmpty && destinationSpaces.contains { $0.id == spaceID }
        case .keychainNotice: return selectedData.contains(.passwords) && profile != nil
        default: return false
        }
    }

    func begin() async {
        guard state == .idle else { return }
        do {
            sources = try await Self.background { [sourceFixtures] in
                sourceFixtures ?? BrowserImportSources.discover()
            }
            try Task.checkCancellation()
            state = .chooseSource
            if let first = sources.first(where: \.canSelect) { selectSource(first.source) }
        } catch { state = .failed(reason: "未能讀取來源清單；請重新開啟導入流程。") }
    }

    func selectSource(_ source: BrowserImportSource) {
        guard state == .chooseSource, let info = sources.first(where: { $0.source == source }), info.canSelect else { return }
        self.source = source
        profileID = info.profiles.first?.id
        selectedData = Set([ImportData.bookmarks, .history]).intersection(info.availableData)
        clearPasswordFile()
    }
    func selectProfile(_ id: String?) {
        guard state == .chooseSource, selectedSourceInfo?.profiles.contains(where: { $0.id == id }) == true else { return }
        profileID = id
        clearPasswordFile()
    }
    func selectSpace(_ id: UUID?) {
        guard state == .chooseData, destinationSpaces.contains(where: { $0.id == id }) else { return }
        spaceID = id
    }
    func setData(_ kind: ImportData, selected: Bool) {
        guard state == .chooseData, source?.availableData.contains(kind) == true else { return }
        if selected { selectedData.insert(kind) } else { selectedData.remove(kind) }
        if kind == .passwords { clearPasswordFile() }
    }
    func selectPasswordFile(_ url: URL?) {
        guard state == .chooseData, selectedData.contains(.passwords) else { return }
        passwordFile = url
        hasPasswordFile = url != nil
        passwordFileMessage = nil
    }
    func passwordFileSelectionFailed() {
        guard state == .chooseData, selectedData.contains(.passwords) else { return }
        passwordFileMessage = "未能選取檔案；請再試一次，或略過密碼。"
    }
    private func clearPasswordFile() {
        passwordFile = nil; hasPasswordFile = false; passwordFileMessage = nil
    }

    func advance() {
        guard canAdvance else { return }
        switch state {
        case .chooseSource: state = .chooseData
        case .chooseData:
            if selectedData.contains(.passwords) { state = .keychainNotice }
            else { start() }
        case .keychainNotice: start()
        default: break
        }
    }
    func back() {
        switch state {
        case .chooseData: state = .chooseSource
        case .keychainNotice: state = .chooseData
        default: break
        }
    }
    func skipPasswordsAndStart() {
        guard state == .keychainNotice else { return }
        clearPasswordFile()
        start(skipPasswords: true) // Keep the explicitly skipped category visible.
    }
    func cancel() {
        clearPasswordFile()
        guard isRunning else { return }
        cancelRequested = true
        task?.cancel()
    }
    func waitUntilFinished() async { await task?.value }

    private func start(skipPasswords: Bool = false) {
        guard !isRunning, let source, let profile,
              !selectedData.isEmpty, let spaceID,
              destinationSpaces.contains(where: { $0.id == spaceID }) else { return }
        guard registry.persistenceError == nil else {
            state = .failed(reason: BrowserImportError.destinationUnavailable.message); return
        }
        let order: [ImportData] = [.bookmarks, .history, .passwords, .extensions, .pinned]
        progress = BrowserImportProgress(kinds: order.filter { selectedData.contains($0) && source.availableData.contains($0) })
        listedExtensions = []
        cancelRequested = false
        state = .running(progress: progress)
        let file = passwordFile
        clearPasswordFile()
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(source: source, profile: profile, spaceID: spaceID, passwordFile: file, skipPasswords: skipPasswords)
        }
    }

    private func run(source: BrowserImportSource, profile: BrowserImportProfile, spaceID: UUID,
                     passwordFile: URL?, skipPasswords: Bool) async {
        do {
            for kind in progress.kinds {
                try Task.checkCancellation()
                do {
                    try await runCategory(kind, source: source, profile: profile, spaceID: spaceID,
                                          passwordFile: passwordFile, skipPasswords: skipPasswords)
                    mutate(kind) { $0.finished = true }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let reason: String
                    if kind == .passwords {
                        reason = (error as? BrowserImportError)?.message
                            ?? "密碼未能導入；來源無法讀取或保險庫存取被拒絕，其它資料繼續。"
                    }
                    else if source == .safari {
                        reason = "無法讀取 Safari 書籤；請確認完整磁碟取用權與書籤檔案。"
                    } else { reason = (error as? BrowserImportError)?.message ?? "此類資料無法讀取或儲存；其它資料繼續。" }
                    mutate(kind) {
                        if let total = $0.total { $0.skipped += max(0, total - $0.processed) }
                        $0.note(reason); $0.finished = true
                    }
                    if case BrowserImportError.destinationUnavailable = error { throw error }
                }
            }
            try Task.checkCancellation()
            try registry.flush()
            state = .done(summary: BrowserImportSummary(progress: progress, extensions: listedExtensions, cancelled: false))
        } catch is CancellationError {
            for kind in progress.kinds where progress.counts[kind]?.finished != true {
                mutate(kind) { $0.note("已取消；只保留已完成的項目。") }
            }
            do {
                try registry.flush()
                state = .done(summary: BrowserImportSummary(progress: progress, extensions: listedExtensions, cancelled: true))
            } catch {
                state = .failed(reason: "已取消，但未能確認已完成項目的儲存；請勿重複導入。")
            }
        } catch {
            state = .failed(reason: "未能確認目的空間的儲存。已完成項目可能已保留；請勿重複導入。")
        }
        clearPasswordFile()
    }

    private func mutate(_ kind: ImportData, _ body: (inout BrowserImportCount) -> Void) {
        var count = progress.counts[kind] ?? BrowserImportCount()
        body(&count)
        progress.counts[kind] = count
        state = .running(progress: progress)
    }
    private func prepare(_ kind: ImportData, total: Int, skipped: Int) {
        mutate(kind) {
            $0.total = total + skipped; $0.skipped = skipped
            if skipped > 0 { $0.reason = "部分資料格式不支援或網址無法安全導入。" }
        }
    }
    private func requireSpace(_ id: UUID) throws {
        guard registry.spaces.contains(where: { $0.id == id && !$0.isSessionSpace }),
              registry.persistenceError == nil else { throw BrowserImportError.destinationUnavailable }
    }

    private func runCategory(_ kind: ImportData, source: BrowserImportSource, profile: BrowserImportProfile,
                             spaceID: UUID, passwordFile: URL?, skipPasswords: Bool) async throws {
        let importer = self.importer
        switch kind {
        case .bookmarks:
            let read = try await Self.background {
                try source == .safari ? importer.safariBookmarks(profile: profile) : importer.bookmarks(profile: profile)
            }
            prepare(kind, total: read.items.count, skipped: read.skipped)
            let rootName = "\(source.rawValue) 書籤"
            var folders: [[String]: UUID] = [:]
            func folder(path: [String]) throws -> UUID {
                if let id = folders[path] { return id }
                try requireSpace(spaceID)
                // Escape slashes inside names so ["a/b"] and ["a", "b"] do not collide.
                let suffix = path.map { $0.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F") }.joined(separator: "/")
                let name = suffix.isEmpty ? rootName : "\(rootName)/\(suffix)"
                let existing = registry.spaces.first { $0.id == spaceID }?.folders.first { $0.name == name }
                guard let result = existing ?? registry.addFolder(spaceID: spaceID, name: name) else {
                    throw BrowserImportError.destinationUnavailable
                }
                folders[path] = result.id
                return result.id
            }
            if !read.items.isEmpty { _ = try folder(path: []) }
            for item in read.items {
                try Task.checkCancellation()
                try requireSpace(spaceID)
                let id = try folder(path: item.folderPath)
                let duplicate = registry.spaces.first { $0.id == spaceID }?.folders.first { $0.id == id }?
                    .bookmarks.contains { $0.url == item.url && $0.title == item.title } == true
                if duplicate { mutate(kind) { $0.skipped += 1; $0.note("已存在的書籤未重複導入。") } }
                else {
                    guard registry.addBookmark(folderID: id, url: item.url, title: item.title) != nil else {
                        throw BrowserImportError.destinationUnavailable
                    }
                    mutate(kind) { $0.imported += 1 }
                }
                await Task.yield()
            }
        case .history:
            let read = try await Self.background { try importer.history(profile: profile) }
            prepare(kind, total: read.items.count, skipped: read.skipped)
            let result = try await historyStore.append(read.items)
            // The atomic batch is already durable. Publish every committed record even if
            // cancellation arrives here; never report zero for a batch that was written.
            for index in read.items.indices {
                mutate(kind) {
                    if index < result.added { $0.imported += 1 }
                    else if index < result.stored { $0.updated += 1 }
                    else { $0.skipped += 1; $0.note("重複或超過 20,000 筆保留上限的紀錄未新增。") }
                }
                await Task.yield()
            }
        case .passwords:
            guard !skipPasswords else {
                mutate(kind) { $0.reason = "使用者選擇略過密碼；未讀取密碼保護金鑰或匯出檔。" }
                return
            }
            let read: BrowserImportReadResult<ImportedLogin>
            if let passwordFile {
                read = try await Self.background { try BrowserPasswordCSVImport.read(userSelectedFile: passwordFile) }
            } else {
                guard profile.source == source else { throw BrowserImportError.invalidData }
                let outcome = try await Self.background {
                    var skipped = 0
                    do {
                        let items = try importer.readLogins(profile: profile, skipped: &skipped)
                        return (BrowserImportReadResult(items: items, skipped: skipped), Optional<BrowserImportError>.none)
                    } catch let error as BrowserImportError {
                        return (BrowserImportReadResult<ImportedLogin>(skipped: skipped), Optional(error))
                    }
                }
                if let error = outcome.1 {
                    mutate(kind) { $0.total = outcome.0.skipped; $0.skipped = outcome.0.skipped }
                    throw error
                }
                read = outcome.0
            }
            prepare(kind, total: read.items.count, skipped: read.skipped)
            if passwordFile == nil && read.skipped > 0 {
                mutate(kind) { $0.reason = "部分密碼無法解密、格式不支援或網址無法安全導入，已略過。" }
            }
            for item in read.items {
                try Task.checkCancellation()
                let result = try vault.importCredentials([(origin: item.origin, username: item.username,
                    password: item.password, title: item.title, browser: source.rawValue)])
                mutate(kind) { $0.imported += result.added; $0.updated += result.updated; $0.skipped += result.skipped }
                await Task.yield()
            }
        case .extensions:
            let read = try await Self.background { try importer.extensions(profile: profile) }
            prepare(kind, total: read.items.count, skipped: read.skipped)
            listedExtensions = read.items
            for _ in read.items {
                try Task.checkCancellation()
                mutate(kind) { $0.skipped += 1 }
                await Task.yield()
            }
            mutate(kind) {
                $0.reason = "\(read.items.count) 個擴充功能未導入（2.0.7 尚未支援）"
                    + (read.skipped > 0 ? "；另有 \(read.skipped) 個清單無法讀取。" : "")
            }
        case .pinned:
            let read = try await Self.background { try importer.pinnedTabs(profile: profile) }
            prepare(kind, total: read.items.count, skipped: read.skipped)
            for url in read.items {
                try Task.checkCancellation()
                try requireSpace(spaceID)
                let owner = BrowserTabOwner.workSpace(spaceID: spaceID)
                if registry.tabs(ownedBy: owner).contains(where: { $0.url == url && $0.isPinned }) {
                    mutate(kind) { $0.skipped += 1; $0.note("已釘選的分頁未重複開啟。") }
                } else {
                    let tab = registry.openTab(owner: owner, url: url)
                    registry.setPinned(tab.id, true)
                    mutate(kind) { $0.imported += 1 }
                }
                await Task.yield()
            }
        }
    }

    private nonisolated static func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }
}
