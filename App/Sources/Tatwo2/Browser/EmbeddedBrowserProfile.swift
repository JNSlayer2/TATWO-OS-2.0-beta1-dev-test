// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/EmbeddedBrowserProfile.swift；改動 3 行（原因：加入照搬來源標記；移除薄殼不可依賴的 TatwoCEFBridge、TatwoUltraworkCore import）
import AppKit
import SwiftUI
import WebKit
import Darwin

enum EmbeddedBrowserRuntimeProfile: Hashable, Sendable {
    case persistent(UUID)
    case ephemeral(UUID)

    var registryKey: UUID {
        switch self {
        case let .persistent(identifier), let .ephemeral(identifier):
            identifier
        }
    }

    var dataStoreIdentifier: UUID? {
        switch self {
        case let .persistent(identifier):
            identifier
        case .ephemeral:
            nil
        }
    }
}

struct EmbeddedBrowserPasswordFormMetadata: Equatable, Sendable {
    let hasPasswordField: Bool
    let actionOrigin: String?
    let isHTTP: Bool
    let isCrossOrigin: Bool
    let hasIDNHost: Bool
    let hasMixedScriptHost: Bool
    let hasConfusableHost: Bool
}

enum EmbeddedBrowserPasswordFormMetadataExtractor {
    enum ExtractionError: Error {
        case invalidResult
    }

    /// The page-side result contains only origins and a password-field boolean.
    /// It never reads or returns input values, HTML, cookies, storage, or page
    /// text.
    static let javaScript = #"""
    (() => Array.from(document.forms).map(form => {
      const hasPasswordField = Array.from(form.elements).some(element =>
        element instanceof HTMLInputElement &&
        String(element.type || "").toLowerCase() === "password"
      );
      if (!hasPasswordField) return null;
      try {
        const action = new URL(form.action || document.location.href, document.baseURI);
        return {
          hasPasswordField: true,
          actionOrigin: action.origin,
          documentOrigin: document.location.origin
        };
      } catch (_) {
        return {
          hasPasswordField: true,
          actionOrigin: null,
          documentOrigin: document.location.origin
        };
      }
    }).filter(Boolean))()
    """#

    @MainActor
    static func extract(
        from webView: WKWebView
    ) async throws -> [EmbeddedBrowserPasswordFormMetadata] {
        let result = try await webView.evaluateJavaScript(javaScript)
        return try metadata(fromJavaScriptResult: result)
    }

    static func metadata(
        fromJavaScriptResult result: Any
    ) throws -> [EmbeddedBrowserPasswordFormMetadata] {
        guard let rows = result as? [[String: Any]] else {
            throw ExtractionError.invalidResult
        }
        return rows.compactMap { row in
            guard (row["hasPasswordField"] as? Bool) == true else {
                return nil
            }
            let actionOrigin = normalizedOrigin(
                row["actionOrigin"] as? String)
            let documentOrigin = normalizedOrigin(
                row["documentOrigin"] as? String)
            let host = actionOrigin.flatMap {
                URLComponents(string: $0)?.host
            } ?? ""
            let scripts = scriptClasses(in: host)
            let hasMixedScript =
                scripts.contains(.latin)
                && (scripts.contains(.cyrillic) || scripts.contains(.greek))
            let hasConfusable =
                hasMixedScript || host.unicodeScalars.contains {
                    isCommonConfusable($0)
                }
            return EmbeddedBrowserPasswordFormMetadata(
                hasPasswordField: true,
                actionOrigin: actionOrigin,
                isHTTP:
                    actionOrigin.flatMap {
                        URLComponents(string: $0)?.scheme?.lowercased()
                    } == "http",
                isCrossOrigin:
                    actionOrigin == nil
                    || documentOrigin == nil
                    || actionOrigin != documentOrigin,
                hasIDNHost:
                    host.lowercased().contains("xn--")
                    || host.unicodeScalars.contains { !$0.isASCII },
                hasMixedScriptHost: hasMixedScript,
                hasConfusableHost: hasConfusable)
        }
    }

    private enum ScriptClass: Hashable {
        case latin
        case cyrillic
        case greek
    }

    private static func normalizedOrigin(_ raw: String?) -> String? {
        guard let raw,
              let url = URL(string: raw)
        else {
            return nil
        }
        return BrowserRequestPolicyEvaluator.origin(of: url)
    }

    private static func scriptClasses(
        in host: String
    ) -> Set<ScriptClass> {
        host.unicodeScalars.reduce(into: Set<ScriptClass>()) {
            switch $1.value {
            case 0x0041 ... 0x005A, 0x0061 ... 0x007A:
                $0.insert(.latin)
            case 0x0370 ... 0x03FF, 0x1F00 ... 0x1FFF:
                $0.insert(.greek)
            case 0x0400 ... 0x052F, 0x2DE0 ... 0x2DFF,
                 0xA640 ... 0xA69F:
                $0.insert(.cyrillic)
            default:
                break
            }
        }
    }

    private static func isCommonConfusable(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        switch scalar.value {
        case 0x0391, 0x0392, 0x0395, 0x0397, 0x0399, 0x039A, 0x039C,
             0x039D, 0x039F, 0x03A1, 0x03A4, 0x03A5, 0x03A7,
             0x03B1, 0x03B5, 0x03B9, 0x03BF, 0x03C1, 0x03C5,
             0x0410, 0x0412, 0x0415, 0x041A, 0x041C, 0x041D, 0x041E,
             0x0420, 0x0421, 0x0422, 0x0425,
             0x0430, 0x0435, 0x043E, 0x0440, 0x0441, 0x0445:
            true
        default:
            false
        }
    }
}

struct EmbeddedBrowserNavigationJournal: Codable, Equatable, Sendable {
    static let maximumEntryCount = 32

    let entries: [String]
    let currentIndex: Int

    init?(
        urls: [URL],
        currentIndex: Int,
        maximumEntryCount: Int = maximumEntryCount
    ) {
        guard !urls.isEmpty,
              urls.indices.contains(currentIndex),
              maximumEntryCount > 0
        else {
            return nil
        }

        let lowerBound = max(
            urls.startIndex,
            currentIndex - (maximumEntryCount - 1) / 2)
        let upperBound = min(
            urls.endIndex,
            lowerBound + maximumEntryCount)
        let adjustedLowerBound = max(
            urls.startIndex,
            upperBound - maximumEntryCount)
        let boundedURLs = urls[adjustedLowerBound ..< upperBound]
        let sanitized = boundedURLs.compactMap(Self.sanitizedURL)
        guard !sanitized.isEmpty else {
            return nil
        }

        let boundedCurrentIndex = currentIndex - adjustedLowerBound
        guard sanitized.indices.contains(boundedCurrentIndex) else {
            return nil
        }
        entries = sanitized.map(\.absoluteString)
        self.currentIndex = boundedCurrentIndex
    }

    var urls: [URL] {
        entries.compactMap(URL.init(string:))
    }

    var currentURL: URL? {
        guard entries.indices.contains(currentIndex) else {
            return nil
        }
        return URL(string: entries[currentIndex])
    }

    private static func sanitizedURL(_ url: URL) -> URL? {
        guard EmbeddedBrowserNavigationPolicy.allows(url),
              var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if components.path.utf8.count > 512 {
            components.path = "/"
        }
        guard let sanitized = components.url,
              EmbeddedBrowserNavigationPolicy.allows(sanitized)
        else {
            return nil
        }
        return sanitized
    }
}

struct EmbeddedBrowserNavigationJournalStore: Sendable {
    static let live = EmbeddedBrowserNavigationJournalStore(
        profileRoot: TatwoRuntimeLayout.applicationSupportRoot()
            .appendingPathComponent("browser-profiles", isDirectory: true))

    let profileRoot: URL

    func load(
        profile: EmbeddedBrowserRuntimeProfile
    ) -> EmbeddedBrowserNavigationJournal? {
        guard let fileURL = journalFileURL(for: profile),
              let data = try? Data(contentsOf: fileURL),
              let journal = try? JSONDecoder().decode(
                EmbeddedBrowserNavigationJournal.self,
                from: data),
              journal.entries.count <=
                EmbeddedBrowserNavigationJournal.maximumEntryCount,
              journal.entries.indices.contains(journal.currentIndex),
              journal.urls.count == journal.entries.count
        else {
            return nil
        }
        return journal
    }

    func save(
        _ journal: EmbeddedBrowserNavigationJournal,
        profile: EmbeddedBrowserRuntimeProfile
    ) throws {
        guard let fileURL = journalFileURL(for: profile) else {
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: fileURL, options: .atomic)
    }

    func remove(profile: EmbeddedBrowserRuntimeProfile) throws {
        guard let fileURL = journalFileURL(for: profile),
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    func journalFileURL(
        for profile: EmbeddedBrowserRuntimeProfile
    ) -> URL? {
        guard let identifier = profile.dataStoreIdentifier else {
            return nil
        }
        return profileRoot
            .appendingPathComponent(
                identifier.uuidString.lowercased(),
                isDirectory: true)
            .appendingPathComponent("navigation-journal-v1.json")
    }
}

enum EmbeddedBrowserProfilePurgeError: Error, Equatable {
    case profileInUse
    case purgeInProgress
}

enum EmbeddedBrowserLeaseError: Error, Equatable {
    case profileBlockedForPurge
    case duplicateWebView
}

enum EmbeddedBrowserOriginClearError: Error, Equatable {
    case invalidOrigin
    case profileInUse
    case maintenanceInProgress
}

struct EmbeddedBrowserOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init?(url: URL) {
        guard EmbeddedBrowserNavigationPolicy.allows(url),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else {
            return nil
        }
        self.scheme = scheme
        self.host = host.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]"))
        port = url.port
    }

    var canonicalString: String {
        let hostLiteral = host.contains(":") ? "[\(host)]" : host
        if let port {
            return "\(scheme)://\(hostLiteral):\(port)"
        }
        return "\(scheme)://\(hostLiteral)"
    }
}

enum EmbeddedBrowserOriginDataPolicy {
    static func recordDisplayName(
        _ displayName: String,
        matches origin: EmbeddedBrowserOrigin
    ) -> Bool {
        displayName.compare(
            origin.host,
            options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
    }
}

enum EmbeddedBrowserSessionDisposition: Codable, Equatable, Sendable {
    case archive
    case reset
    case delete
}

enum EmbeddedBrowserHistoryPersistence: Equatable, Sendable {
    case boundedProfileJournal(maximumEntries: Int)
}

enum EmbeddedBrowserSessionPersistenceContract {
    static let maximumCEFProfileBytes: UInt64 = 512 * 1_024 * 1_024
    static let websiteDataCategories = [
        "cookies",
        "localStorage",
        "indexedDB",
        "serviceWorkers",
        "diskCache",
    ]
    static let history: EmbeddedBrowserHistoryPersistence =
        .boundedProfileJournal(
            maximumEntries:
                EmbeddedBrowserNavigationJournal.maximumEntryCount)

    static func profile(for sessionID: String) -> EmbeddedBrowserRuntimeProfile? {
        TatwoBrowserProfileIdentity(sessionID: sessionID)
            .map { .persistent($0.dataStoreIdentifier) }
    }

    static func clonedProfile(
        from sourceSessionID: String,
        to clonedSessionID: String
    ) -> EmbeddedBrowserRuntimeProfile? {
        guard profile(for: sourceSessionID) != nil else {
            return nil
        }
        // Deriving solely from the new session ID guarantees that website
        // data and authentication state are not copied from the source.
        return profile(for: clonedSessionID)
    }

    static func shouldPurgeProfile(
        for disposition: EmbeddedBrowserSessionDisposition
    ) -> Bool {
        switch disposition {
        case .archive:
            false
        case .reset, .delete:
            true
        }
    }
}

enum EmbeddedBrowserProfileStorageKind: String, Codable, Equatable, Sendable {
    case webKitPersistent
    case cefAppOwned
}

struct EmbeddedBrowserProfileCapacityEntry: Codable, Equatable, Sendable {
    let profileIdentifier: UUID
    let storageKind: EmbeddedBrowserProfileStorageKind
    var generation: UInt64
    var lastAccessedAt: Date
    var isArchived: Bool
    var pendingArchiveIntentID: UUID?

    init(
        profileIdentifier: UUID,
        storageKind: EmbeddedBrowserProfileStorageKind,
        generation: UInt64,
        lastAccessedAt: Date,
        isArchived: Bool,
        pendingArchiveIntentID: UUID? = nil
    ) {
        self.profileIdentifier = profileIdentifier
        self.storageKind = storageKind
        self.generation = generation
        self.lastAccessedAt = lastAccessedAt
        self.isArchived = isArchived
        self.pendingArchiveIntentID = pendingArchiveIntentID
    }

    private enum CodingKeys: String, CodingKey {
        case profileIdentifier
        case storageKind
        case generation
        case lastAccessedAt
        case isArchived
        case pendingArchiveIntentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileIdentifier = try container.decode(
            UUID.self, forKey: .profileIdentifier)
        storageKind = try container.decode(
            EmbeddedBrowserProfileStorageKind.self,
            forKey: .storageKind)
        generation = try container.decode(UInt64.self, forKey: .generation)
        lastAccessedAt = try container.decode(
            Date.self, forKey: .lastAccessedAt)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        pendingArchiveIntentID = try container.decodeIfPresent(
            UUID.self, forKey: .pendingArchiveIntentID)
    }
}

struct EmbeddedBrowserProfileCapacityLedger: Codable, Equatable, Sendable {
    static let schema = "EmbeddedBrowserProfileCapacityLedgerV2"

    var schema: String = Self.schema
    var entries: [EmbeddedBrowserProfileCapacityEntry] = []
}

struct EmbeddedBrowserProfileCapacityReport: Equatable, Sendable {
    let persistentProfileCountBeforeEviction: Int
    let persistentProfileCountAfterEviction: Int
    let evictedProfileIdentifiers: [UUID]
}

enum EmbeddedBrowserProfileCapacityError: Error, Equatable, Sendable {
    case invalidMaximumPersistentProfileCount
    case persistentProfileRequired
    case invalidLedger
    case unsupportedWebKitIdentifierRemoval
    case protectedProfilesExceedCapacity(count: Int, maximumCount: Int)
}

/// WebKit has no reliable public per-identifier byte accounting API. This
/// ledger therefore governs WebKit by persistent-profile count and recency.
/// CEF byte accounting is performed separately against its authoritative root.
final class EmbeddedBrowserProfileCapacityLedgerStore: @unchecked Sendable {
    static let live = EmbeddedBrowserProfileCapacityLedgerStore(
        profileRoot: EmbeddedBrowserNavigationJournalStore.live.profileRoot,
        maximumPersistentProfileCount: 24)

    typealias WebKitProfileRemover = @MainActor @Sendable
        (UUID) async throws -> Void

    let profileRoot: URL
    let maximumPersistentProfileCount: Int
    private let lock = NSLock()

    init(profileRoot: URL, maximumPersistentProfileCount: Int) {
        self.profileRoot = profileRoot.standardizedFileURL
        self.maximumPersistentProfileCount = maximumPersistentProfileCount
    }

    func recordAccess(
        profile: EmbeddedBrowserRuntimeProfile,
        storageKind: EmbeddedBrowserProfileStorageKind = .webKitPersistent,
        generation: UInt64 = 0,
        archived: Bool = false,
        at accessedAt: Date = Date()
    ) throws {
        try withLock {
            guard maximumPersistentProfileCount > 0 else {
                throw EmbeddedBrowserProfileCapacityError
                    .invalidMaximumPersistentProfileCount
            }
            let identifier = try persistentIdentifier(for: profile)
            var ledger = try loadUnlocked()
            if let index = ledger.entries.firstIndex(where: {
                $0.profileIdentifier == identifier
                    && $0.storageKind == storageKind
                    && $0.generation == generation
            }) {
                ledger.entries[index].lastAccessedAt = accessedAt
                ledger.entries[index].isArchived = archived
                if !archived {
                    ledger.entries[index].pendingArchiveIntentID = nil
                }
            } else {
                ledger.entries.append(
                    EmbeddedBrowserProfileCapacityEntry(
                        profileIdentifier: identifier,
                        storageKind: storageKind,
                        generation: generation,
                        lastAccessedAt: accessedAt,
                        isArchived: archived,
                        pendingArchiveIntentID: nil))
            }
            try saveUnlocked(ledger)
        }
    }

    func markPendingArchive(
        profile: EmbeddedBrowserRuntimeProfile,
        intentID: UUID,
        storageKind: EmbeddedBrowserProfileStorageKind = .webKitPersistent,
        generation: UInt64 = 0,
        at preparedAt: Date = Date()
    ) throws {
        try withLock {
            let identifier = try persistentIdentifier(for: profile)
            var ledger = try loadUnlocked()
            if let index = ledger.entries.firstIndex(where: {
                $0.profileIdentifier == identifier
                    && $0.storageKind == storageKind
                    && $0.generation == generation
            }) {
                ledger.entries[index].lastAccessedAt = preparedAt
                ledger.entries[index].isArchived = false
                ledger.entries[index].pendingArchiveIntentID = intentID
            } else {
                ledger.entries.append(
                    EmbeddedBrowserProfileCapacityEntry(
                        profileIdentifier: identifier,
                        storageKind: storageKind,
                        generation: generation,
                        lastAccessedAt: preparedAt,
                        isArchived: false,
                        pendingArchiveIntentID: intentID))
            }
            try saveUnlocked(ledger)
        }
    }

    /// Commits every storage backend required by one archive intent through a
    /// single ledger write. All entries are validated before any entry becomes
    /// eviction-eligible, so a missing or mismatched CEF row cannot leave only
    /// the WebKit profile archived.
    func commitArchiveAtomically(
        profile: EmbeddedBrowserRuntimeProfile,
        intentID: UUID,
        cefGeneration: UInt64?,
        at committedAt: Date = Date()
    ) throws {
        try withLock {
            let identifier = try persistentIdentifier(for: profile)
            var ledger = try loadUnlocked()
            var requirements: [
                (
                    storageKind: EmbeddedBrowserProfileStorageKind,
                    generation: UInt64
                )
            ] = [(.webKitPersistent, 0)]
            if let cefGeneration {
                requirements.append((.cefAppOwned, cefGeneration))
            }

            var indexes: [Int] = []
            for requirement in requirements {
                guard let index = ledger.entries.firstIndex(where: {
                    $0.profileIdentifier == identifier
                        && $0.storageKind == requirement.storageKind
                        && $0.generation == requirement.generation
                })
                else {
                    throw EmbeddedBrowserProfileCapacityError.invalidLedger
                }
                let entry = ledger.entries[index]
                let isSamePendingIntent =
                    !entry.isArchived
                    && entry.pendingArchiveIntentID == intentID
                let isAlreadyCommitted =
                    entry.isArchived
                    && entry.pendingArchiveIntentID == nil
                guard isSamePendingIntent || isAlreadyCommitted else {
                    throw EmbeddedBrowserProfileCapacityError.invalidLedger
                }
                indexes.append(index)
            }

            guard indexes.contains(where: {
                !ledger.entries[$0].isArchived
                    || ledger.entries[$0].pendingArchiveIntentID != nil
            }) else {
                return
            }
            for index in indexes {
                ledger.entries[index].lastAccessedAt = committedAt
                ledger.entries[index].isArchived = true
                ledger.entries[index].pendingArchiveIntentID = nil
            }
            try saveUnlocked(ledger)
        }
    }

    func cancelPendingArchive(
        profile: EmbeddedBrowserRuntimeProfile,
        intentID: UUID
    ) throws {
        try withLock {
            let identifier = try persistentIdentifier(for: profile)
            var ledger = try loadUnlocked()
            for index in ledger.entries.indices
            where ledger.entries[index].profileIdentifier == identifier
                && ledger.entries[index].pendingArchiveIntentID == intentID
            {
                ledger.entries[index].pendingArchiveIntentID = nil
                ledger.entries[index].isArchived = false
            }
            try saveUnlocked(ledger)
        }
    }

    func removeRecord(
        profile: EmbeddedBrowserRuntimeProfile,
        storageKind: EmbeddedBrowserProfileStorageKind? = nil
    ) throws {
        try withLock {
            let identifier = try persistentIdentifier(for: profile)
            var ledger = try loadUnlocked()
            ledger.entries.removeAll {
                $0.profileIdentifier == identifier
                    && (storageKind == nil || $0.storageKind == storageKind)
            }
            try saveUnlocked(ledger)
        }
    }

    func removeRecord(
        profile: EmbeddedBrowserRuntimeProfile,
        storageKind: EmbeddedBrowserProfileStorageKind,
        generation: UInt64
    ) throws {
        try withLock {
            let identifier = try persistentIdentifier(for: profile)
            var ledger = try loadUnlocked()
            ledger.entries.removeAll {
                $0.profileIdentifier == identifier
                    && $0.storageKind == storageKind
                    && $0.generation == generation
            }
            try saveUnlocked(ledger)
        }
    }

    func snapshot() throws -> EmbeddedBrowserProfileCapacityLedger {
        try withLock { try loadUnlocked() }
    }

    func enforceWebKitCapacity(
        currentProfile: EmbeddedBrowserRuntimeProfile?,
        activeProfiles: Set<EmbeddedBrowserRuntimeProfile>,
        // 2026-09-11: the default eviction is ledger-only — it drops the least-recently-used entry from the
        // capacity ledger (freeing a slot so a new chat's browser never hits the wall) but does NOT call
        // WKWebsiteDataStore.remove(forIdentifier:). That WebKit API crashes (bad pointer deref in
        // removeDataStoreWithIdentifierImpl → os_unfair_lock) when it races a concurrent surface open, which
        // is exactly when eviction fires. The evicted profile's on-disk data is left as harmless orphaned
        // bytes (a bounded disk-cleanup debt to reclaim later, off the hot path). Tests may inject a remover.
        remover: @escaping WebKitProfileRemover = { _ in }
    ) async throws -> EmbeddedBrowserProfileCapacityReport {
        let plan: (before: Int, candidates: [EmbeddedBrowserProfileCapacityEntry]) = try withLock {
            guard maximumPersistentProfileCount > 0 else {
                throw EmbeddedBrowserProfileCapacityError
                    .invalidMaximumPersistentProfileCount
            }
            let ledger = try loadUnlocked()
            let webKitEntries = ledger.entries.filter {
                $0.storageKind == .webKitPersistent
            }
            let currentIdentifier = currentProfile?.dataStoreIdentifier
            let activeIdentifiers = Set(
                activeProfiles.compactMap(\.dataStoreIdentifier))
            // 2026-09-11 使用者：滿了就自動清最久沒用的獨立資料（不再只清使用者手動封存的那種）。
            // 仍然不動「目前這條聊天正在用」與「其他 App 分頁正開著」的 profile。封存過的優先被清，
            // 其餘照最久沒存取（LRU）排序。
            let candidates = webKitEntries.filter {
                $0.pendingArchiveIntentID == nil
                    && $0.profileIdentifier != currentIdentifier
                    && !activeIdentifiers.contains($0.profileIdentifier)
            }.sorted {
                if $0.isArchived != $1.isArchived { return $0.isArchived && !$1.isArchived }
                if $0.lastAccessedAt != $1.lastAccessedAt {
                    return $0.lastAccessedAt < $1.lastAccessedAt
                }
                return $0.profileIdentifier.uuidString
                    < $1.profileIdentifier.uuidString
            }
            return (webKitEntries.count, candidates)
        }

        let required = max(0, plan.before - maximumPersistentProfileCount)
        guard plan.candidates.count >= required else {
            throw EmbeddedBrowserProfileCapacityError
                .protectedProfilesExceedCapacity(
                    count: plan.before,
                    maximumCount: maximumPersistentProfileCount)
        }
        var evicted: [UUID] = []
        for candidate in plan.candidates.prefix(required) {
            try await remover(candidate.profileIdentifier)
            try withLock {
                var ledger = try loadUnlocked()
                ledger.entries.removeAll {
                    $0.profileIdentifier == candidate.profileIdentifier
                        && $0.storageKind == .webKitPersistent
                }
                try saveUnlocked(ledger)
            }
            evicted.append(candidate.profileIdentifier)
        }
        return EmbeddedBrowserProfileCapacityReport(
            persistentProfileCountBeforeEviction: plan.before,
            persistentProfileCountAfterEviction: plan.before - evicted.count,
            evictedProfileIdentifiers: evicted)
    }

    private var ledgerFileURL: URL {
        profileRoot.appendingPathComponent("profile-capacity-ledger-v2.json")
    }

    private func loadUnlocked() throws -> EmbeddedBrowserProfileCapacityLedger {
        guard FileManager.default.fileExists(atPath: ledgerFileURL.path) else {
            return EmbeddedBrowserProfileCapacityLedger()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let ledger = try decoder.decode(
                EmbeddedBrowserProfileCapacityLedger.self,
                from: Data(contentsOf: ledgerFileURL))
            let keys = ledger.entries.map {
                "\($0.storageKind.rawValue):\($0.profileIdentifier.uuidString):\($0.generation)"
            }
            guard ledger.schema == EmbeddedBrowserProfileCapacityLedger.schema,
                  Set(keys).count == keys.count
            else {
                throw EmbeddedBrowserProfileCapacityError.invalidLedger
            }
            return ledger
        } catch let error as EmbeddedBrowserProfileCapacityError {
            throw error
        } catch {
            throw EmbeddedBrowserProfileCapacityError.invalidLedger
        }
    }

    private func saveUnlocked(_ ledger: EmbeddedBrowserProfileCapacityLedger) throws {
        try FileManager.default.createDirectory(
            at: profileRoot,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: ledgerFileURL, options: .atomic)
    }

    private func persistentIdentifier(
        for profile: EmbeddedBrowserRuntimeProfile
    ) throws -> UUID {
        guard let identifier = profile.dataStoreIdentifier else {
            throw EmbeddedBrowserProfileCapacityError.persistentProfileRequired
        }
        return identifier
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum EmbeddedBrowserProfileAccessFailure: Error, Equatable, Sendable {
    case pendingLifecycleIntent(intentID: UUID, stage: EmbeddedBrowserLifecycleStage)
    case capacity(EmbeddedBrowserProfileCapacityError)
    case cefCapacity(String)
    case cefLeaseWaitTimedOut(profileKey: UUID)
    case cefLeaseWaitCancelled(profileKey: UUID)

    var visibleMessage: String {
        switch self {
        case let .pendingLifecycleIntent(intentID, stage):
            return "Browser profile blocked by recoverable lifecycle intent \(intentID.uuidString.lowercased()) at \(stage.rawValue)."
        case let .capacity(error):
            return "Browser profile capacity failed closed: \(error)."
        case let .cefCapacity(reason):
            return "CEF profile capacity failed closed: \(reason)."
        case let .cefLeaseWaitTimedOut(profileKey):
            return "上一個 Chromium mount 未在期限內關閉（\(profileKey.uuidString.lowercased())）。請重試。"
        case let .cefLeaseWaitCancelled(profileKey):
            return "Chromium profile 等待已取消（\(profileKey.uuidString.lowercased())），未建立 runtime。"
        }
    }
}

@MainActor
struct EmbeddedBrowserProfileAccessCoordinator {
    static let live = EmbeddedBrowserProfileAccessCoordinator()

    let ledgerStore: EmbeddedBrowserProfileCapacityLedgerStore
    let intentStore: EmbeddedBrowserLifecycleIntentStore
    let webKitRegistry: EmbeddedBrowserWebViewRegistry
    let cefRegistry: TatwoCEFProfileLeaseRegistry
    let cefStore: TatwoCEFProfileStore?
    let cefLeaseWaitTimeoutNanoseconds: UInt64
    let cefProfileByteCeiling: UInt64

    init(
        ledgerStore: EmbeddedBrowserProfileCapacityLedgerStore = .live,
        intentStore: EmbeddedBrowserLifecycleIntentStore = .live,
        webKitRegistry: EmbeddedBrowserWebViewRegistry = .shared,
        cefRegistry: TatwoCEFProfileLeaseRegistry = .shared,
        cefStore: TatwoCEFProfileStore? = .live,
        cefLeaseWaitTimeoutNanoseconds: UInt64 =
            TatwoCEFProfileLeaseRegistry
                .defaultAvailabilityWaitTimeoutNanoseconds,
        cefProfileByteCeiling: UInt64 =
            EmbeddedBrowserSessionPersistenceContract.maximumCEFProfileBytes
    ) {
        self.ledgerStore = ledgerStore
        self.intentStore = intentStore
        self.webKitRegistry = webKitRegistry
        self.cefRegistry = cefRegistry
        self.cefStore = cefStore
        self.cefLeaseWaitTimeoutNanoseconds =
            cefLeaseWaitTimeoutNanoseconds
        self.cefProfileByteCeiling = cefProfileByteCeiling
    }

    func recordAccessAndEnforce(
        profile: EmbeddedBrowserRuntimeProfile,
        engine: EmbeddedBrowserEngine
    ) async -> Result<Void, EmbeddedBrowserProfileAccessFailure> {
        guard let identifier = profile.dataStoreIdentifier else {
            return .success(())
        }
        do {
            if let intent = try await Task.detached(priority: .utility, operation: {
                try intentStore.pendingIntent(profileIdentifier: identifier)
            }).value {
                return .failure(
                    .pendingLifecycleIntent(
                        intentID: intent.intentID,
                        stage: intent.stage))
            }
            switch engine {
            case .webKitLegacy:
                try await Task.detached(priority: .utility) {
                    try ledgerStore.recordAccess(profile: profile)
                }.value
                let activeProfiles = webKitRegistry.activeProfiles
                let report = try await Task.detached(priority: .utility) {
                    try await ledgerStore.enforceWebKitCapacity(
                        currentProfile: profile,
                        activeProfiles: activeProfiles)
                }.value
                // 使用者：滿了自動清最久沒用的；提前 20 個時在 Island 通知。
                ComputerUseIslandNotice.browserCapacity(
                    count: report.persistentProfileCountAfterEviction,
                    limit: ledgerStore.maximumPersistentProfileCount,
                    warnAt: 20)
            case .chromiumCEF:
                guard let cefStore else {
                    return .failure(.cefCapacity("authoritative_root_unavailable"))
                }
                switch await cefRegistry.waitUntilAvailable(
                    identifier: identifier,
                    timeoutNanoseconds: cefLeaseWaitTimeoutNanoseconds)
                {
                case .available:
                    break
                case .timedOut:
                    return .failure(
                        .cefLeaseWaitTimedOut(profileKey: identifier))
                case .cancelled:
                    return .failure(
                        .cefLeaseWaitCancelled(profileKey: identifier))
                }
                guard !Task.isCancelled else {
                    return .failure(
                        .cefLeaseWaitCancelled(profileKey: identifier))
                }
                let generation = try await Task.detached(priority: .utility) {
                    try cefStore.currentGeneration(for: identifier)
                }.value
                let activeIdentifiers = cefRegistry.activeProfileIdentifiers
                let ledger = try await Task.detached(priority: .utility) {
                    try ledgerStore.snapshot()
                }.value
                _ = try TatwoCEFProfileCeilingController(store: cefStore)
                    .enforce(
                        byteCeiling: cefProfileByteCeiling,
                        currentIdentifier: identifier,
                        activeIdentifiers: activeIdentifiers,
                        ledger: ledger,
                        leaseRegistry: cefRegistry,
                        removeLedgerRecord: { row in
                            try ledgerStore.removeRecord(
                                profile: .persistent(
                                    row.profileIdentifier),
                                storageKind: row.storageKind,
                                generation: row.generation)
                        })
                try await Task.detached(priority: .utility) {
                    try ledgerStore.recordAccess(
                        profile: profile,
                        storageKind: .cefAppOwned,
                        generation: generation)
                }.value
            case .chromiumUnavailable:
                return .failure(.cefCapacity("runtime_unavailable"))
            }
            return .success(())
        } catch let error as EmbeddedBrowserProfileCapacityError {
            return .failure(.capacity(error))
        } catch {
            return .failure(.cefCapacity("\(type(of: error)):\(error)"))
        }
    }
}

@MainActor
final class EmbeddedBrowserWebViewRegistry {
    static let shared = EmbeddedBrowserWebViewRegistry()

    struct Lease {
        let webView: WKWebView
        let isNew: Bool
    }

    typealias PersistentDataStoreRemover =
        (UUID, @escaping @Sendable (Error?) -> Void) -> Void
    typealias OriginDataRemover =
        (
            UUID,
            EmbeddedBrowserOrigin,
            @escaping @Sendable (Result<Int, Error>) -> Void
        ) -> Void

    private struct Entry {
        let profile: EmbeddedBrowserRuntimeProfile
        let webView: WKWebView
        let ownerID: UUID
    }

    private enum PurgeState: Equatable {
        case purging(generation: UInt64)
        case clearingOrigin(generation: UInt64)
        case failed
    }

    private final class PurgeCompletionBox: @unchecked Sendable {
        let completion: (Result<Void, Error>) -> Void

        init(_ completion: @escaping (Result<Void, Error>) -> Void) {
            self.completion = completion
        }
    }

    private final class OriginClearCompletionBox: @unchecked Sendable {
        let completion: (Result<Int, Error>) -> Void

        init(_ completion: @escaping (Result<Int, Error>) -> Void) {
            self.completion = completion
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var purgeStates: [EmbeddedBrowserRuntimeProfile: PurgeState] = [:]
    private var nextPurgeGeneration: UInt64 = 0

    func acquire(
        profile: EmbeddedBrowserRuntimeProfile,
        ownerID: UUID,
        make: () -> WKWebView
    ) -> Result<Lease, EmbeddedBrowserLeaseError> {
        guard purgeStates[profile] == nil else {
            return .failure(.profileBlockedForPurge)
        }

        if let active = entries.first(where: {
            $0.value.profile == profile
                && $0.value.ownerID == ownerID
        }) {
            return .success(Lease(webView: active.value.webView, isNew: false))
        }

        let webView = make()
        let key = ObjectIdentifier(webView)
        guard entries[key] == nil else {
            return .failure(.duplicateWebView)
        }
        entries[key] = Entry(
            profile: profile,
            webView: webView,
            ownerID: ownerID)
        return .success(Lease(webView: webView, isNew: true))
    }

    @discardableResult
    func release(
        profile: EmbeddedBrowserRuntimeProfile,
        ownerID: UUID,
        webView: WKWebView
    ) -> Bool {
        let key = ObjectIdentifier(webView)
        guard let entry = entries[key],
              entry.profile == profile,
              entry.ownerID == ownerID
        else {
            return false
        }

        entries.removeValue(forKey: key)
        detach(webView)
        return true
    }

    func purge(
        profile: EmbeddedBrowserRuntimeProfile,
        persistentDataStoreRemover: @escaping PersistentDataStoreRemover = {
            identifier,
            completion in
            WKWebsiteDataStore.remove(
                forIdentifier: identifier,
                completionHandler: completion)
        },
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !entries.values.contains(where: {
            $0.profile == profile
        }) else {
            completion(.failure(EmbeddedBrowserProfilePurgeError.profileInUse))
            return
        }

        if purgeStates[profile] != nil,
           purgeStates[profile] != .failed
        {
            completion(.failure(EmbeddedBrowserProfilePurgeError.purgeInProgress))
            return
        }

        nextPurgeGeneration &+= 1
        let generation = nextPurgeGeneration
        purgeStates[profile] = .purging(generation: generation)
        discardEntries(for: profile)

        guard let identifier = profile.dataStoreIdentifier else {
            purgeStates.removeValue(forKey: profile)
            completion(.success(()))
            return
        }

        let completionBox = PurgeCompletionBox(completion)
        persistentDataStoreRemover(identifier) {
            [weak self, profile, generation, completionBox] error in
            let bridgedError = error.map { $0 as NSError }
            Task { @MainActor [weak self, completionBox] in
                self?.finishPurge(
                    profile: profile,
                    generation: generation,
                    error: bridgedError,
                    completionBox: completionBox)
            }
        }
    }

    func clearOriginData(
        profile: EmbeddedBrowserRuntimeProfile,
        originURL: URL,
        originDataRemover: @escaping OriginDataRemover = {
            identifier,
            origin,
            completion in
            let dataStore = WKWebsiteDataStore(forIdentifier: identifier)
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                let matching = records.filter {
                    EmbeddedBrowserOriginDataPolicy.recordDisplayName(
                        $0.displayName,
                        matches: origin)
                }
                guard !matching.isEmpty else {
                    completion(.success(0))
                    return
                }
                dataStore.removeData(
                    ofTypes: dataTypes,
                    for: matching
                ) {
                    completion(.success(matching.count))
                }
            }
        },
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard let origin = EmbeddedBrowserOrigin(url: originURL),
              profile.dataStoreIdentifier != nil
        else {
            completion(.failure(EmbeddedBrowserOriginClearError.invalidOrigin))
            return
        }
        guard !entries.values.contains(where: { $0.profile == profile }) else {
            completion(.failure(EmbeddedBrowserOriginClearError.profileInUse))
            return
        }
        if purgeStates[profile] != nil,
           purgeStates[profile] != .failed
        {
            completion(
                .failure(
                    EmbeddedBrowserOriginClearError.maintenanceInProgress))
            return
        }

        nextPurgeGeneration &+= 1
        let generation = nextPurgeGeneration
        purgeStates[profile] = .clearingOrigin(generation: generation)
        let completionBox = OriginClearCompletionBox(completion)
        guard let identifier = profile.dataStoreIdentifier else {
            purgeStates[profile] = .failed
            completion(.failure(EmbeddedBrowserOriginClearError.invalidOrigin))
            return
        }
        originDataRemover(identifier, origin) {
            [weak self, profile, generation, completionBox] result in
            Task { @MainActor [weak self, completionBox] in
                self?.finishOriginClear(
                    profile: profile,
                    generation: generation,
                    result: result,
                    completionBox: completionBox)
            }
        }
    }

    var activeLeaseCount: Int {
        entries.count
    }

    var retainedWebViewCount: Int {
        entries.count
    }

    var activeProfiles: Set<EmbeddedBrowserRuntimeProfile> {
        Set(entries.values.map(\.profile))
    }

    func isProfileBlocked(_ profile: EmbeddedBrowserRuntimeProfile) -> Bool {
        purgeStates[profile] != nil
    }

    func resetForTesting() {
        for entry in entries.values {
            detach(entry.webView)
        }
        entries.removeAll()
        purgeStates.removeAll()
    }

    private func finishPurge(
        profile: EmbeddedBrowserRuntimeProfile,
        generation: UInt64,
        error: Error?,
        completionBox: PurgeCompletionBox
    ) {
        guard purgeStates[profile] == .purging(generation: generation) else {
            return
        }

        if let error {
            purgeStates[profile] = .failed
            completionBox.completion(.failure(error))
        } else {
            purgeStates.removeValue(forKey: profile)
            completionBox.completion(.success(()))
        }
    }

    private func finishOriginClear(
        profile: EmbeddedBrowserRuntimeProfile,
        generation: UInt64,
        result: Result<Int, Error>,
        completionBox: OriginClearCompletionBox
    ) {
        guard purgeStates[profile] == .clearingOrigin(
            generation: generation)
        else {
            return
        }
        switch result {
        case let .success(count):
            purgeStates.removeValue(forKey: profile)
            completionBox.completion(.success(count))
        case let .failure(error):
            purgeStates[profile] = .failed
            completionBox.completion(.failure(error))
        }
    }

    private func discardEntries(
        for profile: EmbeddedBrowserRuntimeProfile
    ) {
        let keys = entries.compactMap { key, entry in
            entry.profile == profile ? key : nil
        }
        for key in keys {
            if let removed = entries.removeValue(forKey: key) {
                detach(removed.webView)
            }
        }
    }

    private func detach(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "tatwoAnnotate")
    }
}
