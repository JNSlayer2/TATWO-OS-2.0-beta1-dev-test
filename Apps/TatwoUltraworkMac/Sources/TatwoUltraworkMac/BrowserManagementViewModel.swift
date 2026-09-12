import Foundation
import Combine
import TatwoUltraworkCore

struct TatwoBrowserManagementSessionDescriptor: Equatable, Sendable {
    let sessionID: UUID
    let name: String
    let updatedAt: Date
    let isArchived: Bool
}

enum TatwoBrowserManagementPersistence: String, Equatable, Sendable {
    case persistent
    case ephemeral

    var label: String {
        switch self {
        case .persistent: "登入會記住"
        case .ephemeral: "關掉就忘"
        }
    }
}

struct TatwoBrowserManagementSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileIdentifier: UUID
    let name: String
    let lastUsedAt: Date
    let sizeBytes: UInt64?
    let persistence: TatwoBrowserManagementPersistence
    let isArchived: Bool
    let currentOriginURL: URL?
}

enum TatwoBrowserManagementSnapshotSource: Equatable, Sendable {
    case live
    case fixture
}

enum TatwoBrowserManagementAction: Equatable, Sendable {
    case clearCurrentSite
    case reset
    case archive
    case delete
}

struct TatwoBrowserManagementSnapshot: Equatable, Sendable {
    let usedBytes: UInt64?
    let byteLimit: UInt64
    let sessions: [TatwoBrowserManagementSession]
    let source: TatwoBrowserManagementSnapshotSource
}

enum TatwoBrowserManagementProviderError: Error, Equatable {
    case invalidProfileIdentity(sessionID: UUID)
    case invalidLedger
    case invalidProfilePath(profileIdentifier: UUID, generation: UInt64)
    case byteCountOverflow
}

protocol TatwoBrowserManagementProviding {
    func snapshot(
        for descriptors: [TatwoBrowserManagementSessionDescriptor]
    ) throws -> TatwoBrowserManagementSnapshot
}

enum TatwoBrowserManagementProviderFactory {
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any TatwoBrowserManagementProviding {
        if environment["TATWO_BROWSER_MANAGEMENT_FIXTURE"] == "1" {
            return TatwoBrowserManagementFixtureProvider()
        }
        return TatwoBrowserManagementLiveProvider()
    }
}

struct TatwoBrowserManagementFixtureProvider:
    TatwoBrowserManagementProviding
{
    static let persistentID = UUID(
        uuidString: "6c3e255b-54ec-4b7a-8c8b-34ccfb0ca3ef")!
    static let archivedID = UUID(
        uuidString: "12df78b7-5974-4f50-b00f-56082a944cf4")!
    static let ephemeralID = UUID(
        uuidString: "f6865414-6176-4f79-8464-8247968bb889")!

    func snapshot(
        for _: [TatwoBrowserManagementSessionDescriptor]
    ) throws -> TatwoBrowserManagementSnapshot {
        let base = Date(timeIntervalSince1970: 1_788_133_200)
        return TatwoBrowserManagementSnapshot(
            usedBytes: 318 * 1_024 * 1_024,
            byteLimit:
                EmbeddedBrowserSessionPersistenceContract
                    .maximumCEFProfileBytes,
            sessions: [
                TatwoBrowserManagementSession(
                    id: Self.persistentID,
                    profileIdentifier: Self.persistentID,
                    name: "TATWO OS APP 設計審查",
                    lastUsedAt: base,
                    sizeBytes: 184 * 1_024 * 1_024,
                    persistence: .persistent,
                    isArchived: false,
                    currentOriginURL: URL(string: "https://chatgpt.com")),
                TatwoBrowserManagementSession(
                    id: Self.archivedID,
                    profileIdentifier: Self.archivedID,
                    name: "瀏覽器安全副審",
                    lastUsedAt: base.addingTimeInterval(-7_200),
                    sizeBytes: 126 * 1_024 * 1_024,
                    persistence: .persistent,
                    isArchived: true,
                    currentOriginURL: URL(string: "https://example.com")),
                TatwoBrowserManagementSession(
                    id: Self.ephemeralID,
                    profileIdentifier: Self.ephemeralID,
                    name: "未綁定暫時瀏覽",
                    lastUsedAt: base.addingTimeInterval(-18_000),
                    sizeBytes: 8 * 1_024 * 1_024,
                    persistence: .ephemeral,
                    isArchived: false,
                    currentOriginURL: nil),
            ],
            source: .fixture)
    }
}

struct TatwoBrowserManagementLiveProvider:
    TatwoBrowserManagementProviding
{
    let ledgerStore: EmbeddedBrowserProfileCapacityLedgerStore
    let cefStore: TatwoCEFProfileStore?
    let journalStore: EmbeddedBrowserNavigationJournalStore

    init(
        ledgerStore: EmbeddedBrowserProfileCapacityLedgerStore = .live,
        cefStore: TatwoCEFProfileStore? = .live,
        journalStore: EmbeddedBrowserNavigationJournalStore = .live
    ) {
        self.ledgerStore = ledgerStore
        self.cefStore = cefStore
        self.journalStore = journalStore
    }

    func snapshot(
        for descriptors: [TatwoBrowserManagementSessionDescriptor]
    ) throws -> TatwoBrowserManagementSnapshot {
        let ledger: EmbeddedBrowserProfileCapacityLedger
        do {
            ledger = try ledgerStore.snapshot()
        } catch {
            throw TatwoBrowserManagementProviderError.invalidLedger
        }
        guard ledger.schema == EmbeddedBrowserProfileCapacityLedger.schema else {
            throw TatwoBrowserManagementProviderError.invalidLedger
        }

        var measuredByProfile: [UUID: UInt64] = [:]
        var measuredTotal: UInt64?
        if let cefStore {
            measuredTotal = 0
            for entry in ledger.entries where entry.storageKind == .cefAppOwned {
                let bytes = try measuredBytes(
                    profileIdentifier: entry.profileIdentifier,
                    generation: entry.generation,
                    store: cefStore)
                let profileTotal =
                    measuredByProfile[entry.profileIdentifier, default: 0]
                        .addingReportingOverflow(bytes)
                guard !profileTotal.overflow else {
                    throw TatwoBrowserManagementProviderError.byteCountOverflow
                }
                measuredByProfile[entry.profileIdentifier] =
                    profileTotal.partialValue
                let total = measuredTotal!
                    .addingReportingOverflow(bytes)
                guard !total.overflow else {
                    throw TatwoBrowserManagementProviderError.byteCountOverflow
                }
                measuredTotal = total.partialValue
            }
        }

        let rows: [TatwoBrowserManagementSession] =
            try descriptors.compactMap {
                descriptor -> TatwoBrowserManagementSession? in
            guard let identity = TatwoBrowserProfileIdentity(
                sessionID: descriptor.sessionID.uuidString.lowercased())
            else {
                throw TatwoBrowserManagementProviderError
                    .invalidProfileIdentity(sessionID: descriptor.sessionID)
            }
            let profileIdentifier = identity.dataStoreIdentifier
            let entries = ledger.entries.filter {
                $0.profileIdentifier == profileIdentifier
            }
            let lastUsedAt =
                entries.map(\.lastAccessedAt).max() ?? descriptor.updatedAt
            let profile = EmbeddedBrowserRuntimeProfile.persistent(
                profileIdentifier)
            let journal = journalStore.load(profile: profile)
            let hasProfileDirectory: Bool
            if let cefStore {
                let profileURL: URL
                do {
                    profileURL = try cefStore.profileURL(
                        for: profileIdentifier)
                } catch {
                    throw TatwoBrowserManagementProviderError
                        .invalidProfilePath(
                            profileIdentifier: profileIdentifier,
                            generation: 0)
                }
                var isDirectory = ObjCBool(false)
                hasProfileDirectory =
                    FileManager.default.fileExists(
                        atPath: profileURL.path,
                        isDirectory: &isDirectory)
                    && isDirectory.boolValue
            } else {
                hasProfileDirectory = false
            }
            guard !entries.isEmpty
                    || journal != nil
                    || hasProfileDirectory
            else {
                return nil
            }
            let currentOriginURL = journal.flatMap { journal -> URL? in
                guard journal.urls.indices.contains(journal.currentIndex) else {
                    return nil
                }
                return journal.urls[journal.currentIndex]
            }
            return TatwoBrowserManagementSession(
                id: descriptor.sessionID,
                profileIdentifier: profileIdentifier,
                name: descriptor.name,
                lastUsedAt: lastUsedAt,
                sizeBytes:
                    cefStore == nil
                        ? nil
                        : measuredByProfile[profileIdentifier, default: 0],
                persistence: .persistent,
                isArchived:
                    descriptor.isArchived
                        || (!entries.isEmpty
                            && entries.allSatisfy(\.isArchived)),
                currentOriginURL: currentOriginURL)
        }.sorted {
            if $0.isArchived != $1.isArchived {
                return !$0.isArchived
            }
            if $0.lastUsedAt != $1.lastUsedAt {
                return $0.lastUsedAt > $1.lastUsedAt
            }
            return $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
        }

        return TatwoBrowserManagementSnapshot(
            usedBytes: measuredTotal,
            byteLimit:
                EmbeddedBrowserSessionPersistenceContract
                    .maximumCEFProfileBytes,
            sessions: rows,
            source: .live)
    }

    private func measuredBytes(
        profileIdentifier: UUID,
        generation: UInt64,
        store: TatwoCEFProfileStore
    ) throws -> UInt64 {
        let profileURL: URL
        do {
            profileURL = try store.profileURL(
                for: profileIdentifier,
                generation: generation)
        } catch {
            throw TatwoBrowserManagementProviderError.invalidProfilePath(
                profileIdentifier: profileIdentifier,
                generation: generation)
        }
        do {
            return try TatwoCEFDirectorySize.measuredAllocatedBytes(
                at: profileURL,
                containedIn: store.rootCacheURL)
        } catch TatwoCEFDirectorySizeError.byteCountOverflow {
            throw TatwoBrowserManagementProviderError.byteCountOverflow
        } catch {
            throw TatwoBrowserManagementProviderError.invalidProfilePath(
                profileIdentifier: profileIdentifier,
                generation: generation)
        }
    }
}

@MainActor
final class TatwoBrowserManagementViewModel: ObservableObject {
    @Published private(set) var snapshot: TatwoBrowserManagementSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeSessionID: UUID?
    @Published var statusMessage: String?

    private let provider: any TatwoBrowserManagementProviding

    init(provider: any TatwoBrowserManagementProviding) {
        self.provider = provider
    }

    var usesFixture: Bool {
        snapshot?.source == .fixture
    }

    func reload(
        descriptors: [TatwoBrowserManagementSessionDescriptor]
    ) {
        do {
            snapshot = try provider.snapshot(for: descriptors)
            errorMessage = nil
        } catch {
            snapshot = nil
            errorMessage = "瀏覽器資料無法安全讀取，管理操作已停用。"
        }
    }

    func beginAction(sessionID: UUID) -> Bool {
        guard activeSessionID == nil, errorMessage == nil else {
            return false
        }
        activeSessionID = sessionID
        statusMessage = nil
        return true
    }

    func finishAction(_ message: String) {
        activeSessionID = nil
        statusMessage = message
    }

    @discardableResult
    func performAction(
        _ action: TatwoBrowserManagementAction,
        sessionID: UUID,
        operation: @MainActor () async -> String
    ) async -> Bool {
        guard beginAction(sessionID: sessionID) else {
            return false
        }
        if usesFixture {
            finishAction(
                "預覽模式不會更動真實瀏覽資料。")
            return false
        }
        let message = await operation()
        finishAction(message)
        return true
    }
}
