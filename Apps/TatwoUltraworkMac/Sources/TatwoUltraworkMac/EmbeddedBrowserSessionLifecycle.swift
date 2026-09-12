import AppKit
import SwiftUI
import TatwoCEFBridge
import TatwoUltraworkCore
import WebKit
import Darwin

enum EmbeddedBrowserLifecycleStage: String, Codable, Equatable, Sendable {
    case pendingPurge
    case purgedCommitRequired
    case archivePrepared
    case finalMutationApplied
    case committed
}

struct EmbeddedBrowserLifecycleIntent: Codable, Equatable, Sendable {
    static let schema = "EmbeddedBrowserLifecycleIntentV1"

    var schema = Self.schema
    let intentID: UUID
    let disposition: EmbeddedBrowserSessionDisposition
    let sessionID: String
    let profileIdentifier: UUID
    let generation: UInt64
    var stage: EmbeddedBrowserLifecycleStage
    let createdAt: Date
    var updatedAt: Date
}

enum EmbeddedBrowserLifecycleIntentFactory {
    static func make(
        disposition: EmbeddedBrowserSessionDisposition,
        sessionID: String,
        profileIdentifier: UUID,
        generation: UInt64,
        intentID: UUID = UUID(),
        at date: Date = Date()
    ) -> EmbeddedBrowserLifecycleIntent {
        EmbeddedBrowserLifecycleIntent(
            intentID: intentID,
            disposition: disposition,
            sessionID: sessionID,
            profileIdentifier: profileIdentifier,
            generation: generation,
            stage: .pendingPurge,
            createdAt: date,
            updatedAt: date)
    }
}

enum EmbeddedBrowserLifecycleIntentStoreOperation: Equatable, Sendable {
    case save(stage: EmbeddedBrowserLifecycleStage)
    case remove
}

struct EmbeddedBrowserLifecycleIntentStore: Sendable {
    static let live = EmbeddedBrowserLifecycleIntentStore(
        root: TatwoRuntimeLayout.applicationSupportRoot()
            .appendingPathComponent("browser-lifecycle-intents", isDirectory: true))

    let root: URL
    let failureInjector:
        @Sendable (EmbeddedBrowserLifecycleIntentStoreOperation) -> Bool

    init(
        root: URL,
        failureInjector: @escaping @Sendable
            (EmbeddedBrowserLifecycleIntentStoreOperation) -> Bool = { _ in false }
    ) {
        self.root = root
        self.failureInjector = failureInjector
    }

    func save(_ intent: EmbeddedBrowserLifecycleIntent) throws {
        guard intent.schema == EmbeddedBrowserLifecycleIntent.schema else {
            throw EmbeddedBrowserSessionLifecycleError
                .intentStoreFailed(stage: intent.stage, intentID: intent.intentID)
        }
        guard !failureInjector(.save(stage: intent.stage)) else {
            throw EmbeddedBrowserSessionLifecycleError
                .intentStoreFailed(stage: intent.stage, intentID: intent.intentID)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(intent).write(
            to: fileURL(for: intent.intentID),
            options: .atomic)
    }

    func load(intentID: UUID) throws -> EmbeddedBrowserLifecycleIntent? {
        let url = fileURL(for: intentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let intent = try decoder.decode(
                EmbeddedBrowserLifecycleIntent.self,
                from: Data(contentsOf: url))
            guard intent.schema == EmbeddedBrowserLifecycleIntent.schema else {
                throw EmbeddedBrowserSessionLifecycleError
                    .intentStoreFailed(stage: intent.stage, intentID: intent.intentID)
            }
            return intent
        } catch let error as EmbeddedBrowserSessionLifecycleError {
            throw error
        } catch {
            throw EmbeddedBrowserSessionLifecycleError
                .intentStoreFailed(stage: .pendingPurge, intentID: intentID)
        }
    }

    func pendingIntent(
        profileIdentifier: UUID
    ) throws -> EmbeddedBrowserLifecycleIntent? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        } catch {
            throw EmbeddedBrowserSessionLifecycleError
                .intentEnumerationFailed
        }
        for url in urls where url.pathExtension == "json" {
            guard let intentID = UUID(
                uuidString: url.deletingPathExtension().lastPathComponent),
                  let intent = try load(intentID: intentID),
                  intent.stage != .committed,
                  intent.profileIdentifier == profileIdentifier
            else { continue }
            return intent
        }
        return nil
    }

    func remove(intentID: UUID) throws {
        guard !failureInjector(.remove) else {
            throw EmbeddedBrowserSessionLifecycleError
                .intentStoreFailed(stage: .committed, intentID: intentID)
        }
        let url = fileURL(for: intentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(for intentID: UUID) -> URL {
        root.appendingPathComponent(
            "\(intentID.uuidString.lowercased()).json",
            isDirectory: false)
    }
}

enum EmbeddedBrowserSessionLifecycleError: Error, Equatable, Sendable {
    case invalidSessionID
    case webKitProfileInUse(intentID: UUID, stage: EmbeddedBrowserLifecycleStage)
    case webKitPurgeInProgress(intentID: UUID, stage: EmbeddedBrowserLifecycleStage)
    case webKitPurgeFailed(intentID: UUID, stage: EmbeddedBrowserLifecycleStage, reason: String)
    case cefProfileInUse(intentID: UUID, stage: EmbeddedBrowserLifecycleStage)
    case cefPurgeInProgress(intentID: UUID, stage: EmbeddedBrowserLifecycleStage)
    case cefInvalidProfilePath(intentID: UUID, stage: EmbeddedBrowserLifecycleStage)
    case cefProfileStoreUnavailable(intentID: UUID, stage: EmbeddedBrowserLifecycleStage)
    case cefPurgeFailed(intentID: UUID, stage: EmbeddedBrowserLifecycleStage, reason: String)
    case navigationJournalPurgeFailed(intentID: UUID, stage: EmbeddedBrowserLifecycleStage, reason: String)
    case capacityLedgerFailed(intentID: UUID, stage: EmbeddedBrowserLifecycleStage, reason: String)
    case intentStoreFailed(stage: EmbeddedBrowserLifecycleStage, intentID: UUID)
    case intentEnumerationFailed
    case intentMismatch(intentID: UUID)
    case finalMutationFailed(intentID: UUID, stage: EmbeddedBrowserLifecycleStage, reason: String)
    case finalMutationUnverifiable(
        intentID: UUID,
        stage: EmbeddedBrowserLifecycleStage,
        idempotencyKey: String)
    case deletedProfileStateUnverifiable(
        intentID: UUID,
        profileIdentifier: UUID)
    case unsupportedFormalMutation(disposition: EmbeddedBrowserSessionDisposition)
    case unexpectedFailure(intentID: UUID, stage: EmbeddedBrowserLifecycleStage, reason: String)

    var visibleMessage: String {
        switch self {
        case .invalidSessionID:
            return "Browser lifecycle blocked: invalid session identifier."
        case let .intentStoreFailed(stage, intentID):
            return "Browser lifecycle intent \(intentID.uuidString.lowercased()) could not be persisted at \(stage.rawValue)."
        case let .intentMismatch(intentID):
            return "Browser lifecycle recovery mismatch for intent \(intentID.uuidString.lowercased())."
        case let .finalMutationFailed(intentID, stage, reason):
            return "Browser lifecycle final mutation failed for \(intentID.uuidString.lowercased()) at \(stage.rawValue): \(reason)"
        case let .finalMutationUnverifiable(
            intentID,
            stage,
            idempotencyKey):
            return "Browser lifecycle final mutation is not durably verifiable for \(intentID.uuidString.lowercased()) at \(stage.rawValue) [\(idempotencyKey)]."
        case let .deletedProfileStateUnverifiable(
            intentID,
            profileIdentifier):
            return "Browser profile deletion \(intentID.uuidString.lowercased()) could not verify durable absence for \(profileIdentifier.uuidString.lowercased())."
        case let .unsupportedFormalMutation(disposition):
            return "Browser lifecycle action \(disposition) is unsupported because no reversible, durably verifiable production mutation is available."
        default:
            return "Browser lifecycle is blocked by a typed recovery failure: \(self)"
        }
    }
}

struct EmbeddedBrowserSessionLifecycleReceipt: Equatable, Sendable {
    let intentID: UUID
    let disposition: EmbeddedBrowserSessionDisposition
    let stage: EmbeddedBrowserLifecycleStage
    let profileIdentifier: UUID
    let generation: UInt64
    let profileWasPreserved: Bool
}

struct EmbeddedBrowserFinalMutationContract {
    let idempotencyKey: String
    let alreadyApplied: (_ intentID: UUID) throws -> Bool
    let apply: (_ intentID: UUID) throws -> Void

    init(
        idempotencyKey: String,
        alreadyApplied: @escaping (_ intentID: UUID) throws -> Bool,
        apply: @escaping (_ intentID: UUID) throws -> Void
    ) {
        self.idempotencyKey = idempotencyKey
        self.alreadyApplied = alreadyApplied
        self.apply = apply
    }
}

@MainActor
enum EmbeddedBrowserSessionLifecycleHook {
    static func apply(
        _ disposition: EmbeddedBrowserSessionDisposition,
        to sessionID: String,
        registry: EmbeddedBrowserWebViewRegistry = .shared,
        cefProfileLeaseRegistry: TatwoCEFProfileLeaseRegistry = .shared,
        cefProfileStore: TatwoCEFProfileStore? = .live,
        requiresCEFProfilePurge: Bool =
            EmbeddedBrowserEnginePolicy.current == .chromiumCEF,
        persistentDataStoreRemover: @escaping
            EmbeddedBrowserWebViewRegistry.PersistentDataStoreRemover = {
                identifier, completion in
                WKWebsiteDataStore.remove(
                    forIdentifier: identifier,
                    completionHandler: completion)
            },
        cefProfileDisposer: @escaping
            TatwoCEFProfileLeaseRegistry.ProfileDisposer = { url, completion in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    completion(nil)
                    return
                }
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(
                        at: url,
                        resultingItemURL: &resultingURL)
                    completion(nil)
                } catch { completion(error) }
            },
        navigationJournalStore: EmbeddedBrowserNavigationJournalStore = .live,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard EmbeddedBrowserSessionPersistenceContract.shouldPurgeProfile(
            for: disposition)
        else {
            completion(.success(()))
            return
        }
        guard let identity = TatwoBrowserProfileIdentity(sessionID: sessionID) else {
            completion(.failure(EmbeddedBrowserSessionLifecycleError.invalidSessionID))
            return
        }
        let profile = EmbeddedBrowserRuntimeProfile.persistent(
            identity.dataStoreIdentifier)
        let cefReservation: TatwoCEFProfileLeaseRegistry.PurgeReservation?
        if cefProfileStore != nil {
            switch cefProfileLeaseRegistry.reservePurge(
                identifier: identity.dataStoreIdentifier)
            {
            case let .success(reservation): cefReservation = reservation
            case let .failure(error):
                completion(.failure(error))
                return
            }
        } else if requiresCEFProfilePurge {
            completion(.failure(
                EmbeddedBrowserSessionLifecycleError.unsupportedFormalMutation(
                    disposition: disposition)))
            return
        } else {
            cefReservation = nil
        }
        registry.purge(
            profile: profile,
            persistentDataStoreRemover: persistentDataStoreRemover
        ) { webKitResult in
            guard case .success = webKitResult else {
                if let cefReservation {
                    cefProfileLeaseRegistry.cancelPurge(cefReservation)
                }
                if case let .failure(error) = webKitResult {
                    completion(.failure(error))
                }
                return
            }
            func finishJournal() {
                do {
                    try navigationJournalStore.remove(profile: profile)
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
            guard let cefReservation, let cefProfileStore else {
                finishJournal()
                return
            }
            cefProfileLeaseRegistry.commitPurge(
                cefReservation,
                store: cefProfileStore,
                disposer: cefProfileDisposer
            ) { result in
                switch result {
                case .success: finishJournal()
                case let .failure(error): completion(.failure(error))
                }
            }
        }
    }

    fileprivate static func errorReason(_ error: Error) -> String {
        "\(type(of: error)):\(String(describing: error))"
    }
}

@MainActor
struct EmbeddedBrowserSessionLifecycleTransaction {
    let disposition: EmbeddedBrowserSessionDisposition
    let sessionID: String
    let registry: EmbeddedBrowserWebViewRegistry
    let cefProfileLeaseRegistry: TatwoCEFProfileLeaseRegistry
    let cefProfileStore: TatwoCEFProfileStore?
    let requiresCEFProfilePurge: Bool
    let persistentDataStoreRemover:
        EmbeddedBrowserWebViewRegistry.PersistentDataStoreRemover
    let cefProfileDisposer: TatwoCEFProfileLeaseRegistry.ProfileDisposer
    let navigationJournalStore: EmbeddedBrowserNavigationJournalStore
    let capacityLedgerStore: EmbeddedBrowserProfileCapacityLedgerStore?
    let intentStore: EmbeddedBrowserLifecycleIntentStore

    init(
        disposition: EmbeddedBrowserSessionDisposition,
        sessionID: String,
        registry: EmbeddedBrowserWebViewRegistry = .shared,
        cefProfileLeaseRegistry: TatwoCEFProfileLeaseRegistry = .shared,
        cefProfileStore: TatwoCEFProfileStore? = .live,
        requiresCEFProfilePurge: Bool =
            EmbeddedBrowserEnginePolicy.current == .chromiumCEF,
        persistentDataStoreRemover: @escaping
            EmbeddedBrowserWebViewRegistry.PersistentDataStoreRemover = {
                identifier, completion in
                WKWebsiteDataStore.remove(
                    forIdentifier: identifier,
                    completionHandler: completion)
            },
        cefProfileDisposer: @escaping
            TatwoCEFProfileLeaseRegistry.ProfileDisposer = { url, completion in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    completion(nil)
                    return
                }
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(
                        at: url,
                        resultingItemURL: &resultingURL)
                    completion(nil)
                } catch { completion(error) }
            },
        navigationJournalStore: EmbeddedBrowserNavigationJournalStore = .live,
        capacityLedgerStore: EmbeddedBrowserProfileCapacityLedgerStore? = .live,
        intentStore: EmbeddedBrowserLifecycleIntentStore = .live
    ) {
        self.disposition = disposition
        self.sessionID = sessionID
        self.registry = registry
        self.cefProfileLeaseRegistry = cefProfileLeaseRegistry
        self.cefProfileStore = cefProfileStore
        self.requiresCEFProfilePurge = requiresCEFProfilePurge
        self.persistentDataStoreRemover = persistentDataStoreRemover
        self.cefProfileDisposer = cefProfileDisposer
        self.navigationJournalStore = navigationJournalStore
        self.capacityLedgerStore = capacityLedgerStore
        self.intentStore = intentStore
    }

    func prepare() async -> Result<
        EmbeddedBrowserSessionLifecycleReceipt,
        EmbeddedBrowserSessionLifecycleError
    > {
        guard let profile = EmbeddedBrowserSessionPersistenceContract.profile(
            for: sessionID),
              let identifier = profile.dataStoreIdentifier
        else { return .failure(.invalidSessionID) }
        let generation: UInt64
        do {
            generation = try cefProfileStore?.currentGeneration(for: identifier) ?? 0
        } catch {
            return .failure(.unexpectedFailure(
                intentID: UUID(), stage: .pendingPurge,
                reason: EmbeddedBrowserSessionLifecycleHook.errorReason(error)))
        }
        do {
            if let existing = try intentStore.pendingIntent(
                profileIdentifier: identifier),
               existing.disposition == disposition,
               existing.sessionID == sessionID
            {
                if existing.stage == .purgedCommitRequired
                    || existing.stage == .archivePrepared
                    || existing.stage == .finalMutationApplied
                {
                    return .success(receipt(for: existing))
                }
                return await continuePreparation(existing, profile: profile)
            }
            let intent = EmbeddedBrowserLifecycleIntentFactory.make(
                disposition: disposition,
                sessionID: sessionID,
                profileIdentifier: identifier,
                generation: generation)
            try intentStore.save(intent)
            return await continuePreparation(intent, profile: profile)
        } catch let error as EmbeddedBrowserSessionLifecycleError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedFailure(
                intentID: UUID(), stage: .pendingPurge,
                reason: EmbeddedBrowserSessionLifecycleHook.errorReason(error)))
        }
    }

    func execute() async -> Result<
        EmbeddedBrowserSessionLifecycleReceipt,
        EmbeddedBrowserSessionLifecycleError
    > {
        await prepare()
    }

    func commit(
        receipt: EmbeddedBrowserSessionLifecycleReceipt,
        finalMutation: EmbeddedBrowserFinalMutationContract
    ) -> Result<
        EmbeddedBrowserSessionLifecycleReceipt,
        EmbeddedBrowserSessionLifecycleError
    > {
        do {
            guard var intent = try intentStore.load(intentID: receipt.intentID),
                  intent.profileIdentifier == receipt.profileIdentifier,
                  intent.generation == receipt.generation,
                  intent.disposition == receipt.disposition,
                  intent.stage == receipt.stage
                    || intent.stage == .finalMutationApplied,
                  intent.stage == .purgedCommitRequired
                    || intent.stage == .archivePrepared
                    || intent.stage == .finalMutationApplied
            else { return .failure(.intentMismatch(intentID: receipt.intentID)) }

            if intent.stage != .finalMutationApplied {
                do {
                    if try !finalMutation.alreadyApplied(intent.intentID) {
                        try finalMutation.apply(intent.intentID)
                    }
                    guard try finalMutation.alreadyApplied(intent.intentID) else {
                        return .failure(
                            .finalMutationUnverifiable(
                                intentID: intent.intentID,
                                stage: intent.stage,
                                idempotencyKey: finalMutation.idempotencyKey))
                    }
                } catch let error as EmbeddedBrowserSessionLifecycleError {
                    return .failure(error)
                } catch {
                    return .failure(.finalMutationFailed(
                        intentID: intent.intentID,
                        stage: intent.stage,
                        reason:
                            "\(finalMutation.idempotencyKey):"
                            + EmbeddedBrowserSessionLifecycleHook
                                .errorReason(error)))
                }
                intent.stage = .finalMutationApplied
                intent.updatedAt = Date()
                do {
                    try intentStore.save(intent)
                } catch {
                    return .failure(.intentStoreFailed(
                        stage: .finalMutationApplied,
                        intentID: intent.intentID))
                }
            }

            if intent.disposition == .archive {
                guard let profile =
                        EmbeddedBrowserSessionPersistenceContract.profile(
                            for: intent.sessionID),
                      let capacityLedgerStore
                else {
                    return .failure(.capacityLedgerFailed(
                        intentID: intent.intentID,
                        stage: intent.stage,
                        reason: "archive_commit_state_unavailable"))
                }
                do {
                    try capacityLedgerStore.commitArchiveAtomically(
                        profile: profile,
                        intentID: intent.intentID,
                        cefGeneration:
                            cefProfileStore == nil
                                ? nil
                                : intent.generation)
                } catch {
                    return .failure(.capacityLedgerFailed(
                        intentID: intent.intentID,
                        stage: intent.stage,
                        reason: EmbeddedBrowserSessionLifecycleHook
                            .errorReason(error)))
                }
            }

            intent.stage = .committed
            intent.updatedAt = Date()
            try intentStore.save(intent)
            try intentStore.remove(intentID: intent.intentID)
            return .success(self.receipt(for: intent))
        } catch let error as EmbeddedBrowserSessionLifecycleError {
            return .failure(error)
        } catch {
            return .failure(.finalMutationFailed(
                intentID: receipt.intentID,
                stage: receipt.stage,
                reason: EmbeddedBrowserSessionLifecycleHook.errorReason(error)))
        }
    }

    func commitProfileOnly(
        receipt: EmbeddedBrowserSessionLifecycleReceipt
    ) -> Result<
        EmbeddedBrowserSessionLifecycleReceipt,
        EmbeddedBrowserSessionLifecycleError
    > {
        guard receipt.disposition == .reset else {
            return .failure(.unsupportedFormalMutation(
                disposition: receipt.disposition))
        }
        return commit(
            receipt: receipt,
            finalMutation: EmbeddedBrowserFinalMutationContract(
                idempotencyKey:
                    "browser-profile-reset:\(receipt.intentID.uuidString.lowercased())",
                alreadyApplied: { _ in true },
                apply: { _ in }))
    }

    func commitDeletedProfile(
        receipt: EmbeddedBrowserSessionLifecycleReceipt
    ) -> Result<
        EmbeddedBrowserSessionLifecycleReceipt,
        EmbeddedBrowserSessionLifecycleError
    > {
        guard receipt.disposition == .delete else {
            return .failure(.unsupportedFormalMutation(
                disposition: receipt.disposition))
        }
        let verifier = {
            try deletedProfileStateIsDurablyAbsent(receipt: receipt)
        }
        return commit(
            receipt: receipt,
            finalMutation: EmbeddedBrowserFinalMutationContract(
                idempotencyKey:
                    "browser-profile-delete:\(receipt.intentID.uuidString.lowercased())",
                alreadyApplied: { _ in try verifier() },
                apply: { _ in
                    guard try verifier() else {
                        throw EmbeddedBrowserSessionLifecycleError
                            .deletedProfileStateUnverifiable(
                                intentID: receipt.intentID,
                                profileIdentifier: receipt.profileIdentifier)
                    }
                }))
    }

    private func deletedProfileStateIsDurablyAbsent(
        receipt: EmbeddedBrowserSessionLifecycleReceipt
    ) throws -> Bool {
        if let capacityLedgerStore {
            let ledger = try capacityLedgerStore.snapshot()
            guard !ledger.entries.contains(where: {
                $0.profileIdentifier == receipt.profileIdentifier
            }) else {
                return false
            }
        }
        let profile = EmbeddedBrowserRuntimeProfile.persistent(
            receipt.profileIdentifier)
        if let journalURL = navigationJournalStore.journalFileURL(
            for: profile),
           FileManager.default.fileExists(atPath: journalURL.path)
        {
            return false
        }
        if let cefProfileStore {
            let deletedGenerationURL = try cefProfileStore.profileURL(
                for: receipt.profileIdentifier,
                generation: receipt.generation)
            if FileManager.default.fileExists(
                atPath: deletedGenerationURL.path)
            {
                return false
            }
        }
        return true
    }

    private func continuePreparation(
        _ original: EmbeddedBrowserLifecycleIntent,
        profile: EmbeddedBrowserRuntimeProfile
    ) async -> Result<
        EmbeddedBrowserSessionLifecycleReceipt,
        EmbeddedBrowserSessionLifecycleError
    > {
        var intent = original
        guard let capacityLedgerStore else {
            return .failure(.capacityLedgerFailed(
                intentID: intent.intentID,
                stage: intent.stage,
                reason: "capacity_ledger_unavailable"))
        }
        if disposition == .archive {
            do {
                try capacityLedgerStore.markPendingArchive(
                    profile: profile,
                    intentID: intent.intentID,
                    storageKind: .webKitPersistent,
                    generation: 0)
                if cefProfileStore != nil {
                    try capacityLedgerStore.markPendingArchive(
                        profile: profile,
                        intentID: intent.intentID,
                        storageKind: .cefAppOwned,
                        generation: intent.generation)
                }
                intent.stage = .archivePrepared
                intent.updatedAt = Date()
                try intentStore.save(intent)
                return .success(receipt(for: intent))
            } catch {
                return .failure(.capacityLedgerFailed(
                    intentID: intent.intentID,
                    stage: intent.stage,
                    reason: EmbeddedBrowserSessionLifecycleHook.errorReason(error)))
            }
        }

        let purgeResult: Result<Void, Error> = await withCheckedContinuation {
            continuation in
            EmbeddedBrowserSessionLifecycleHook.apply(
                disposition,
                to: sessionID,
                registry: registry,
                cefProfileLeaseRegistry: cefProfileLeaseRegistry,
                cefProfileStore: cefProfileStore,
                requiresCEFProfilePurge: requiresCEFProfilePurge,
                persistentDataStoreRemover: persistentDataStoreRemover,
                cefProfileDisposer: cefProfileDisposer,
                navigationJournalStore: navigationJournalStore
            ) { continuation.resume(returning: $0) }
        }
        if case let .failure(error) = purgeResult {
            return .failure(classify(error, intent: intent))
        }
        do {
            intent.stage = .purgedCommitRequired
            intent.updatedAt = Date()
            try intentStore.save(intent)
        } catch {
            return .failure(.intentStoreFailed(
                stage: .purgedCommitRequired,
                intentID: intent.intentID))
        }
        do {
            try capacityLedgerStore.removeRecord(profile: profile)
        } catch {
            return .failure(.capacityLedgerFailed(
                intentID: intent.intentID,
                stage: .purgedCommitRequired,
                reason: EmbeddedBrowserSessionLifecycleHook.errorReason(error)))
        }
        return .success(receipt(for: intent))
    }

    private func receipt(
        for intent: EmbeddedBrowserLifecycleIntent
    ) -> EmbeddedBrowserSessionLifecycleReceipt {
        EmbeddedBrowserSessionLifecycleReceipt(
            intentID: intent.intentID,
            disposition: intent.disposition,
            stage: intent.stage,
            profileIdentifier: intent.profileIdentifier,
            generation: intent.generation,
            profileWasPreserved: intent.disposition == .archive)
    }

    private func classify(
        _ error: Error,
        intent: EmbeddedBrowserLifecycleIntent
    ) -> EmbeddedBrowserSessionLifecycleError {
        if let typed = error as? EmbeddedBrowserProfilePurgeError {
            switch typed {
            case .profileInUse:
                return .webKitProfileInUse(
                    intentID: intent.intentID, stage: intent.stage)
            case .purgeInProgress:
                return .webKitPurgeInProgress(
                    intentID: intent.intentID, stage: intent.stage)
            }
        }
        if let typed = error as? TatwoCEFProfilePurgeError {
            switch typed {
            case .profileInUse:
                return .cefProfileInUse(
                    intentID: intent.intentID, stage: intent.stage)
            case .purgeInProgress:
                return .cefPurgeInProgress(
                    intentID: intent.intentID, stage: intent.stage)
            case .invalidProfilePath:
                return .cefInvalidProfilePath(
                    intentID: intent.intentID, stage: intent.stage)
            }
        }
        return .unexpectedFailure(
            intentID: intent.intentID,
            stage: intent.stage,
            reason: EmbeddedBrowserSessionLifecycleHook.errorReason(error))
    }
}

@MainActor
enum EmbeddedBrowserSessionDeletionHook {
    static func purgeProfile(
        forDeletedSessionID sessionID: String,
        registry: EmbeddedBrowserWebViewRegistry = .shared,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        _ = sessionID
        _ = registry
        completion(
            .failure(
                EmbeddedBrowserSessionLifecycleError
                    .unsupportedFormalMutation(disposition: .delete)))
    }
}

@MainActor
enum EmbeddedBrowserSiteDataClearingHook {
    static func clear(
        originURL: URL,
        for sessionID: String,
        registry: EmbeddedBrowserWebViewRegistry = .shared,
        originDataRemover: @escaping
            EmbeddedBrowserWebViewRegistry.OriginDataRemover = {
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
        guard let profile =
                EmbeddedBrowserSessionPersistenceContract.profile(
                    for: sessionID)
        else {
            completion(.failure(EmbeddedBrowserOriginClearError.invalidOrigin))
            return
        }
        registry.clearOriginData(
            profile: profile,
            originURL: originURL,
            originDataRemover: originDataRemover,
            completion: completion)
    }
}

enum EmbeddedBrowserSiteDataClearOutcome: Equatable, Sendable {
    case webKit(removedRecordCount: Int)
    case chromiumCEF(TatwoCEFOriginDataClearReceipt)

    var visibleMessage: String {
        switch self {
        case let .webKit(removedRecordCount):
            return "已清除目前網站的 WebKit 資料（\(removedRecordCount) 筆紀錄）。"
        case let .chromiumCEF(receipt):
            guard receipt.siteDataCleared else {
                return "Chromium 單站資料清除未完整完成。"
            }
            return "已清除目前網站的 Cookie、LocalStorage、IndexedDB、Service Worker 與 CacheStorage；CEF 不支援單站 HTTP response cache 清除。"
        }
    }
}

enum EmbeddedBrowserSiteDataMaintenanceError: Error, Equatable, Sendable {
    case invalidSession
    case invalidOrigin
    case unsupportedEngine
    case webKit(EmbeddedBrowserOriginClearError)
    case chromiumCEF(TatwoCEFOriginDataClearError)

    var visibleMessage: String {
        switch self {
        case .invalidSession:
            return "單站資料清除受阻：目前瀏覽器未綁定持久 Session。"
        case .invalidOrigin:
            return "單站資料清除受阻：目前頁面不是可驗證的公開 HTTP(S) origin。"
        case .unsupportedEngine:
            return "單站資料清除受阻：目前瀏覽器引擎不支援此正式操作。"
        case let .webKit(error):
            return "WebKit 單站資料清除失敗並維持 fail-closed：\(error)"
        case let .chromiumCEF(error):
            return "Chromium 單站資料清除失敗並維持 fail-closed：\(error)"
        }
    }
}

@MainActor
struct EmbeddedBrowserSiteDataMaintenanceCoordinator {
    let webKitRegistry: EmbeddedBrowserWebViewRegistry
    let cefRegistry: TatwoCEFProfileLeaseRegistry
    let cefStore: TatwoCEFProfileStore?
    let webKitOriginDataRemover:
        EmbeddedBrowserWebViewRegistry.OriginDataRemover
    let cefOriginDataClearer:
        TatwoCEFProfileLeaseRegistry.OriginDataClearer

    init(
        webKitRegistry: EmbeddedBrowserWebViewRegistry = .shared,
        cefRegistry: TatwoCEFProfileLeaseRegistry = .shared,
        cefStore: TatwoCEFProfileStore? = .live,
        webKitOriginDataRemover: @escaping
            EmbeddedBrowserWebViewRegistry.OriginDataRemover = {
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
        cefOriginDataClearer: @escaping
            TatwoCEFProfileLeaseRegistry.OriginDataClearer = {
                origin,
                profilePath,
                completion in
                TatwoCEFOriginDataClearBridge.clear(
                    origin: origin,
                    persistentProfilePath: profilePath,
                    completion: completion)
            }
    ) {
        self.webKitRegistry = webKitRegistry
        self.cefRegistry = cefRegistry
        self.cefStore = cefStore
        self.webKitOriginDataRemover = webKitOriginDataRemover
        self.cefOriginDataClearer = cefOriginDataClearer
    }

    func clear(
        originURL: URL,
        sessionID: String,
        engine: EmbeddedBrowserEngine
    ) async -> Result<
        EmbeddedBrowserSiteDataClearOutcome,
        EmbeddedBrowserSiteDataMaintenanceError
    > {
        guard let profile =
                EmbeddedBrowserSessionPersistenceContract.profile(
                    for: sessionID),
              let identifier = profile.dataStoreIdentifier
        else {
            return .failure(.invalidSession)
        }
        guard let origin = EmbeddedBrowserOrigin(url: originURL) else {
            return .failure(.invalidOrigin)
        }

        switch engine {
        case .webKitLegacy:
            let result: Result<Int, Error> = await withCheckedContinuation {
                continuation in
                EmbeddedBrowserSiteDataClearingHook.clear(
                    originURL: originURL,
                    for: sessionID,
                    registry: webKitRegistry,
                    originDataRemover: webKitOriginDataRemover
                ) { continuation.resume(returning: $0) }
            }
            switch result {
            case let .success(count):
                return .success(.webKit(removedRecordCount: count))
            case let .failure(error):
                return .failure(
                    .webKit(
                        error as? EmbeddedBrowserOriginClearError
                            ?? .maintenanceInProgress))
            }

        case .chromiumCEF:
            guard let cefStore else {
                return .failure(.chromiumCEF(.invalidProfilePath))
            }
            let profileURL: URL
            do {
                profileURL = try cefStore.profileURL(for: identifier)
            } catch {
                return .failure(.chromiumCEF(.invalidProfilePath))
            }
            let reservation: TatwoCEFProfileLeaseRegistry
                .OriginClearReservation
            switch cefRegistry.reserveOriginDataClear(
                identifier: identifier,
                origin: origin.canonicalString,
                profileURL: profileURL)
            {
            case let .success(value):
                reservation = value
            case let .failure(error):
                return .failure(.chromiumCEF(error))
            }
            let result: Result<
                TatwoCEFOriginDataClearReceipt,
                TatwoCEFOriginDataClearError
            > = await withCheckedContinuation { continuation in
                cefRegistry.commitOriginDataClear(
                    reservation,
                    store: cefStore,
                    clearer: cefOriginDataClearer
                ) { continuation.resume(returning: $0) }
            }
            switch result {
            case let .success(receipt):
                return .success(.chromiumCEF(receipt))
            case let .failure(error):
                return .failure(.chromiumCEF(error))
            }

        case .chromiumUnavailable:
            return .failure(.unsupportedEngine)
        }
    }
}
