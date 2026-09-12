import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TatwoSkilletBundleManifestV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let repositoryID: String
    public let displayName: String
    public let summary: String
    public let exportedRevisionID: String
    public let canonicalRevision: String
    public let stableRevision: String?
    public let canaryRevision: String?
    public let rollbackRevision: String?
    public let revisions: [TatwoSkillRevisionV1]
    public let objectDigests: [String]
    public let createdAt: Date

    public init(
        schemaVersion: Int = 1,
        repositoryID: String,
        displayName: String,
        summary: String,
        exportedRevisionID: String,
        canonicalRevision: String,
        stableRevision: String?,
        canaryRevision: String?,
        rollbackRevision: String?,
        revisions: [TatwoSkillRevisionV1],
        objectDigests: [String],
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.repositoryID = repositoryID
        self.displayName = displayName
        self.summary = summary
        self.exportedRevisionID = exportedRevisionID
        self.canonicalRevision = canonicalRevision
        self.stableRevision = stableRevision
        self.canaryRevision = canaryRevision
        self.rollbackRevision = rollbackRevision
        self.revisions = revisions
        self.objectDigests = objectDigests
        self.createdAt = createdAt
    }
}

public struct TatwoSkilletBundleAuthorityBindingV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let repositoryID: String
    public let exportedRevisionID: String
    public let bundleDigest: String
    public let requestID: String
    public let sourceDeviceID: String
    public let targetDeviceID: String
    public let authorityEpoch: UInt64
    public let ledgerSequence: UInt64
    public let catalogRevision: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = 1,
        repositoryID: String,
        exportedRevisionID: String,
        bundleDigest: String,
        requestID: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.repositoryID = repositoryID
        self.exportedRevisionID = exportedRevisionID
        self.bundleDigest = bundleDigest
        self.requestID = requestID
        self.sourceDeviceID = sourceDeviceID
        self.targetDeviceID = targetDeviceID
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.catalogRevision = catalogRevision
        self.createdAt = createdAt
    }
}

public struct TatwoSkilletBoundBundleInputV1: Hashable, Sendable {
    public let repositoryID: String
    public let revisionID: String
    public let contentDigest: String
    public let bundleDigest: String
    public let bundleURL: URL
    public let binding: TatwoSkilletBundleAuthorityBindingV1

    public init(
        repositoryID: String,
        revisionID: String,
        contentDigest: String,
        bundleDigest: String,
        bundleURL: URL,
        binding: TatwoSkilletBundleAuthorityBindingV1
    ) {
        self.repositoryID = repositoryID
        self.revisionID = revisionID
        self.contentDigest = contentDigest
        self.bundleDigest = bundleDigest
        self.bundleURL = bundleURL
        self.binding = binding
    }
}

public enum TatwoSkilletBundleImportOutcomeV1: Equatable, Sendable {
    case imported(TatwoCapabilityRepositoryV1)
    case mergeProposed(TatwoMergeProposalV1)
}

public struct TatwoSkilletBranchPreservedRevisionV1: Equatable, Sendable {
    public let repositoryID: String
    public let revisionID: String
    public let contentDigest: String

    public init(
        repositoryID: String,
        revisionID: String,
        contentDigest: String
    ) {
        self.repositoryID = repositoryID
        self.revisionID = revisionID
        self.contentDigest = contentDigest
    }
}

public enum TatwoSkilletTargetPreservedStateV1: String, Codable, Sendable {
    case storePreserved = "store-preserved"
    case runtimePreserved = "runtime-preserved"
}

public struct TatwoSkilletTargetPreservedRepositoryV1:
    Codable, Equatable, Sendable
{
    public let repositoryID: String
    public let revisionID: String
    public let contentDigest: String
    public let state: TatwoSkilletTargetPreservedStateV1

    public init(
        repositoryID: String,
        revisionID: String,
        contentDigest: String,
        state: TatwoSkilletTargetPreservedStateV1
    ) {
        self.repositoryID = repositoryID
        self.revisionID = revisionID
        self.contentDigest = contentDigest
        self.state = state
    }
}

public struct TatwoSkilletAuthorityBoundSetActivationV1:
    Equatable, Sendable
{
    public let heads: [TatwoDeviceHeadV1]
    public let targetPreservedRepositories: [
        TatwoSkilletTargetPreservedRepositoryV1
    ]

    public init(
        heads: [TatwoDeviceHeadV1],
        targetPreservedRepositories: [
            TatwoSkilletTargetPreservedRepositoryV1
        ]
    ) {
        self.heads = heads
        self.targetPreservedRepositories = targetPreservedRepositories
    }
}

public struct TatwoSkilletPendingMergeSetV1: Equatable, Sendable {
    public let proposals: [TatwoMergeProposalV1]
    public let branchPreservedRevisions: [
        TatwoSkilletBranchPreservedRevisionV1
    ]
    public let targetPreservedRepositories: [
        TatwoSkilletTargetPreservedRepositoryV1
    ]

    public init(
        proposals: [TatwoMergeProposalV1],
        branchPreservedRevisions: [
            TatwoSkilletBranchPreservedRevisionV1
        ],
        targetPreservedRepositories: [
            TatwoSkilletTargetPreservedRepositoryV1
        ]
    ) {
        self.proposals = proposals
        self.branchPreservedRevisions = branchPreservedRevisions
        self.targetPreservedRepositories = targetPreservedRepositories
    }

    public var repositoryCount: Int {
        proposals.count + branchPreservedRevisions.count
    }
}

public enum TatwoSkilletAuthorityBoundSetOutcomeV1: Equatable, Sendable {
    case activated(TatwoSkilletAuthorityBoundSetActivationV1)
    case mergeProposed(TatwoSkilletPendingMergeSetV1)
}

public enum TatwoSkilletRuntimeReadbackStateV1: String, Codable, Sendable {
    case absent
    case present
}

public struct TatwoSkilletRuntimeReadbackV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let repositoryID: String
    public let state: TatwoSkilletRuntimeReadbackStateV1
    public let contentDigest: String?
    public let fileCount: Int
    public let byteCount: Int

    public init(
        schemaVersion: Int = 1,
        repositoryID: String,
        state: TatwoSkilletRuntimeReadbackStateV1,
        contentDigest: String?,
        fileCount: Int,
        byteCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.repositoryID = repositoryID
        self.state = state
        self.contentDigest = contentDigest
        self.fileCount = fileCount
        self.byteCount = byteCount
    }
}

public enum TatwoSkilletBundleError: Error, Equatable, LocalizedError {
    case invalidBundle(String)
    case invalidManifest(String)
    case missingObject(String)
    case corruptedObject(String)
    case destinationAlreadyExists(String)
    case repositoryConflict(String)
    case unsafeRuntimePath(String)
    case activeRuntimeMismatch(String)
    case atomicSwapFailed(String)
    case rollbackFailed(String)
    case authorityBindingMismatch(String)
    case mergeApprovalRequired(String)
    case runtimeMutationDetected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundle(let reason):
            return "Invalid Skillet bundle: \(reason)"
        case .invalidManifest(let reason):
            return "Invalid Skillet bundle manifest: \(reason)"
        case .missingObject(let digest):
            return "Skillet bundle object is missing: \(digest)"
        case .corruptedObject(let digest):
            return "Skillet bundle object failed verification: \(digest)"
        case .destinationAlreadyExists(let path):
            return "Skillet bundle destination already exists: \(path)"
        case .repositoryConflict(let repositoryID):
            return "Skillet repository cannot be imported without overwriting divergent state: \(repositoryID)"
        case .unsafeRuntimePath(let path):
            return "Skillet runtime path is unsafe: \(path)"
        case .activeRuntimeMismatch(let repositoryID):
            return "Skillet device head does not match the active runtime: \(repositoryID)"
        case .atomicSwapFailed(let path):
            return "Skillet runtime atomic swap failed: \(path)"
        case .rollbackFailed(let path):
            return "Skillet runtime rollback failed: \(path)"
        case .authorityBindingMismatch(let field):
            return "Skillet bundle authority binding does not match: \(field)"
        case .mergeApprovalRequired(let proposalID):
            return "Skillet merge proposal requires human approval: \(proposalID)"
        case .runtimeMutationDetected(let repositoryID):
            return "Skillet runtime changed while recording a merge decision: \(repositoryID)"
        }
    }
}

/// Portable, content-addressed transport for private Skillet repositories.
///
/// Bundles contain only the selected revision's complete ancestor closure.
/// Device heads, credentials, sessions, machine paths and runtime state are
/// intentionally excluded. Import verifies the complete bundle before it
/// mutates a repository, and activation commits its fenced device head only
/// after the new runtime tree is active.
public enum TatwoSkilletBundleTransport {
    struct ReceiveBundleTestHooks {
        let afterConflictDetected: (() throws -> Void)?
        let beforeDivergentStoreCommit: (() throws -> Void)?

        init(
            afterConflictDetected: (() throws -> Void)? = nil,
            beforeDivergentStoreCommit: (() throws -> Void)? = nil
        ) {
            self.afterConflictDetected = afterConflictDetected
            self.beforeDivergentStoreCommit = beforeDivergentStoreCommit
        }
    }

    struct SetTransactionTestHooks {
        let forceCompensatingExchange: Bool
        let beforeCompensatingExchangeStep: ((Int, URL, URL) throws -> Void)?
        let beforeCompensatingRollbackStep: ((Int, URL, URL) throws -> Void)?
        let prepareStagedStore: ((URL, URL, Bool) throws -> Void)?
        let prepareStagedRuntime: ((URL) throws -> Void)?

        init(
            forceCompensatingExchange: Bool = false,
            beforeCompensatingExchangeStep: ((Int, URL, URL) throws -> Void)? = nil,
            beforeCompensatingRollbackStep: ((Int, URL, URL) throws -> Void)? = nil,
            prepareStagedStore: ((URL, URL, Bool) throws -> Void)? = nil,
            prepareStagedRuntime: ((URL) throws -> Void)? = nil
        ) {
            self.forceCompensatingExchange = forceCompensatingExchange
            self.beforeCompensatingExchangeStep = beforeCompensatingExchangeStep
            self.beforeCompensatingRollbackStep = beforeCompensatingRollbackStep
            self.prepareStagedStore = prepareStagedStore
            self.prepareStagedRuntime = prepareStagedRuntime
        }
    }

    static func testOnlyAtomicExchange(
        _ first: URL,
        _ second: URL,
        hooks: SetTransactionTestHooks
    ) throws {
        try atomicExchange(first, second, testHooks: hooks)
    }

    @discardableResult
    public static func exportBundle(
        from store: TatwoSkilletRepositoryStore,
        repositoryID: String,
        revisionID: String,
        to destination: URL,
        createdAt: Date = Date()
    ) throws -> TatwoSkilletBundleManifestV1 {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TatwoSkilletBundleError.destinationAlreadyExists(destination.path)
        }

        let repository = try store.loadRepository(id: repositoryID)
        let approvedMergeProposals = try store.loadMergeProposals(
            repositoryID: repositoryID
        ).filter {
            $0.status == .approved
                && $0.mergedRevisionID == revisionID
        }
        let revisions = try exportRevisionClosure(
            repository: repository,
            exportedRevisionID: revisionID,
            approvedMergeProposals: approvedMergeProposals
        )
        let includedRevisionIDs = Set(revisions.map(\.id))
        let manifest = TatwoSkilletBundleManifestV1(
            repositoryID: repository.id,
            displayName: repository.displayName,
            summary: repository.summary,
            exportedRevisionID: revisionID,
            canonicalRevision: revisionID,
            stableRevision: includedPointer(repository.stableRevision, in: includedRevisionIDs),
            canaryRevision: includedPointer(repository.canaryRevision, in: includedRevisionIDs),
            rollbackRevision: includedPointer(repository.rollbackRevision, in: includedRevisionIDs),
            revisions: revisions,
            objectDigests: revisions.map(\.contentDigest),
            createdAt: iso8601Normalized(createdAt)
        )

        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: staging.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true
        )

        do {
            for revision in revisions {
                guard try store.verifyRevision(
                    repositoryID: repositoryID,
                    revisionID: revision.id
                ) else {
                    throw TatwoSkilletBundleError.corruptedObject(revision.contentDigest)
                }
                let snapshotManifest = try store.loadSnapshotManifest(
                    repositoryID: repositoryID,
                    revisionID: revision.id
                )
                let object = staging
                    .appendingPathComponent("objects", isDirectory: true)
                    .appendingPathComponent(revision.contentDigest, isDirectory: true)
                try store.materializeRevision(
                    repositoryID: repositoryID,
                    revisionID: revision.id,
                    to: object.appendingPathComponent("payload", isDirectory: true)
                )
                try writeJSON(
                    snapshotManifest,
                    to: object.appendingPathComponent("manifest.json")
                )
            }
            try writeJSON(manifest, to: staging.appendingPathComponent("bundle.json"))
            guard try verifyBundle(at: staging) == manifest else {
                throw TatwoSkilletBundleError.invalidBundle("self-verification mismatch")
            }
            try fileManager.moveItem(at: staging, to: destination)
            return manifest
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public static func verifyBundle(
        at bundleURL: URL
    ) throws -> TatwoSkilletBundleManifestV1 {
        let fileManager = FileManager.default
        do {
            try requireNoSymbolicLinkComponents(
                bundleURL,
                errorPath: bundleURL.path
            )
        } catch {
            throw TatwoSkilletBundleError.invalidBundle(
                "bundle path contains a symbolic-link component"
            )
        }
        try requireDirectory(bundleURL, errorPath: bundleURL.path)
        try requireExactChildren(
            at: bundleURL,
            expected: ["bundle.json", "objects"],
            objectDigest: nil
        )

        let manifestURL = bundleURL.appendingPathComponent("bundle.json")
        try requireRegularFile(manifestURL, errorPath: manifestURL.path)
        let manifest: TatwoSkilletBundleManifestV1
        do {
            manifest = try makeDecoder().decode(
                TatwoSkilletBundleManifestV1.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw TatwoSkilletBundleError.invalidManifest("bundle.json cannot be decoded")
        }
        try validateManifest(manifest)

        let objects = bundleURL.appendingPathComponent("objects", isDirectory: true)
        try requireDirectory(objects, errorPath: objects.path)
        let actualObjectNames = try directoryChildren(at: objects).map(\.lastPathComponent).sorted()
        guard actualObjectNames == manifest.objectDigests.sorted() else {
            if let missing = manifest.objectDigests.first(where: {
                !actualObjectNames.contains($0)
            }) {
                throw TatwoSkilletBundleError.missingObject(missing)
            }
            throw TatwoSkilletBundleError.invalidBundle("unexpected object payload")
        }

        for digest in manifest.objectDigests {
            let object = objects.appendingPathComponent(digest, isDirectory: true)
            guard fileManager.fileExists(atPath: object.path) else {
                throw TatwoSkilletBundleError.missingObject(digest)
            }
            do {
                try verifyObject(at: object, expectedDigest: digest)
            } catch let error as TatwoSkilletBundleError {
                throw error
            } catch {
                throw TatwoSkilletBundleError.corruptedObject(digest)
            }
        }
        return manifest
    }

    public static func makeAuthorityBinding(
        at bundleURL: URL,
        requestID: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        createdAt: Date = Date()
    ) throws -> TatwoSkilletBundleAuthorityBindingV1 {
        let manifest = try verifyBundle(at: bundleURL)
        guard isValidIdentifier(requestID),
              isValidIdentifier(sourceDeviceID),
              isValidIdentifier(targetDeviceID),
              isValidIdentifier(catalogRevision),
              ledgerSequence > 0
        else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("identity or ledger")
        }
        return TatwoSkilletBundleAuthorityBindingV1(
            repositoryID: manifest.repositoryID,
            exportedRevisionID: manifest.exportedRevisionID,
            bundleDigest: try bundleDigest(for: manifest),
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision,
            createdAt: iso8601Normalized(createdAt)
        )
    }

    @discardableResult
    public static func verifyAuthorityBoundBundle(
        at bundleURL: URL,
        binding: TatwoSkilletBundleAuthorityBindingV1,
        expectedRequestID: String,
        expectedSourceDeviceID: String,
        expectedTargetDeviceID: String,
        expectedAuthorityEpoch: UInt64,
        expectedLedgerSequence: UInt64,
        expectedCatalogRevision: String
    ) throws -> TatwoSkilletBundleManifestV1 {
        let manifest = try verifyBundle(at: bundleURL)
        guard binding.schemaVersion == 1,
              isValidIdentifier(binding.repositoryID),
              isRevisionID(binding.exportedRevisionID),
              isSHA256(binding.bundleDigest),
              isValidIdentifier(binding.requestID),
              isValidIdentifier(binding.sourceDeviceID),
              isValidIdentifier(binding.targetDeviceID),
              isValidIdentifier(binding.catalogRevision),
              binding.ledgerSequence > 0
        else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("binding schema")
        }
        guard binding.requestID == expectedRequestID else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("request id")
        }
        guard binding.sourceDeviceID == expectedSourceDeviceID else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("source device")
        }
        guard binding.targetDeviceID == expectedTargetDeviceID else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("target device")
        }
        guard binding.authorityEpoch == expectedAuthorityEpoch else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("authority epoch")
        }
        guard binding.ledgerSequence == expectedLedgerSequence else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("ledger sequence")
        }
        guard binding.catalogRevision == expectedCatalogRevision else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("catalog revision")
        }
        guard binding.repositoryID == manifest.repositoryID else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("repository id")
        }
        guard binding.bundleDigest == (try bundleDigest(for: manifest)) else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("bundle digest")
        }
        guard binding.exportedRevisionID == manifest.exportedRevisionID else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("revision id")
        }
        return manifest
    }

    @discardableResult
    public static func importBundle(
        at bundleURL: URL,
        into store: TatwoSkilletRepositoryStore
    ) throws -> TatwoCapabilityRepositoryV1 {
        try importBundle(
            at: bundleURL,
            into: store,
            beforeStoreCommit: nil
        )
    }

    /// Receives a verified bundle without ever overwriting divergent state.
    ///
    /// Strict fast-forwards keep the existing import behavior. Divergence
    /// persists the incoming branch plus a deterministic merge proposal and
    /// leaves canonical/stable/runtime pointers untouched.
    @discardableResult
    public static func receiveBundle(
        at bundleURL: URL,
        into store: TatwoSkilletRepositoryStore,
        sourceDeviceID: String,
        createdAt: Date = Date()
    ) throws -> TatwoSkilletBundleImportOutcomeV1 {
        try receiveBundle(
            at: bundleURL,
            into: store,
            sourceDeviceID: sourceDeviceID,
            createdAt: createdAt,
            testHooks: nil
        )
    }

    @discardableResult
    static func receiveBundle(
        at bundleURL: URL,
        into store: TatwoSkilletRepositoryStore,
        sourceDeviceID: String,
        createdAt: Date,
        testHooks: ReceiveBundleTestHooks?
    ) throws -> TatwoSkilletBundleImportOutcomeV1 {
        guard isValidIdentifier(sourceDeviceID) else {
            throw TatwoSkilletBundleError.invalidBundle(
                "source device identifier is unsafe"
            )
        }
        let manifest = try verifyBundle(at: bundleURL)
        let existing = try loadRepositoryIfPresent(
            id: manifest.repositoryID,
            from: store
        )
        if existing == nil {
            return .imported(
                try importBundle(at: bundleURL, into: store)
            )
        }
        do {
            try validateImportCompatibility(existing, manifest: manifest)
            return .imported(
                try importBundle(at: bundleURL, into: store)
            )
        } catch let error as TatwoSkilletBundleError {
            guard case .repositoryConflict = error else { throw error }
        }
        try testHooks?.afterConflictDetected?()

        return try receiveDivergentBundle(
            manifest: manifest,
            bundleURL: bundleURL,
            into: store,
            sourceDeviceID: sourceDeviceID,
            createdAt: iso8601Normalized(createdAt),
            testHooks: testHooks
        )
    }

    @discardableResult
    static func importBundle(
        at bundleURL: URL,
        into store: TatwoSkilletRepositoryStore,
        beforeStoreCommit: (() throws -> Void)?
    ) throws -> TatwoCapabilityRepositoryV1 {
        let manifest = try verifyBundle(at: bundleURL)

        let fileManager = FileManager.default
        let storeRoot = store.rootURL.standardizedFileURL
        try requireNoSymbolicLinkComponents(
            storeRoot,
            errorPath: storeRoot.path
        )
        let parent = storeRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(storeRoot.lastPathComponent).import-staging-\(UUID().uuidString)",
            isDirectory: true
        )

        return try store.withExclusiveMutationLock {
            let existing = try loadRepositoryIfPresent(
                id: manifest.repositoryID,
                from: store
            )
            try validateImportCompatibility(existing, manifest: manifest)
            let hadStore = fileManager.fileExists(atPath: storeRoot.path)
            if hadStore {
                do {
                    try requireDirectory(storeRoot, errorPath: storeRoot.path)
                } catch {
                    throw TatwoSkilletBundleError.invalidBundle(
                        "Skillet store root is not a safe directory"
                    )
                }
                try fileManager.copyItem(at: storeRoot, to: staging)
            } else {
                try fileManager.createDirectory(
                    at: staging,
                    withIntermediateDirectories: true
                )
            }

            let stagedStore = TatwoSkilletRepositoryStore(rootURL: staging)
            do {
                let imported = try importVerifiedBundleInPlace(
                    manifest: manifest,
                    bundleURL: bundleURL,
                    into: stagedStore
                )
                try beforeStoreCommit?()
                // No staged-store API may run after its private sibling lock is
                // removed. The outer stable-store lock remains held through the
                // directory commit.
                try removeEphemeralStoreMutationLock(for: stagedStore)
                if hadStore {
                    try atomicExchange(staging, storeRoot)
                    archivePreviousStore(
                        at: staging,
                        storeRoot: storeRoot,
                        fileManager: fileManager
                    )
                } else {
                    try atomicRename(staging, storeRoot)
                }
                return imported
            } catch {
                try? removeEphemeralStoreMutationLock(for: stagedStore)
                if fileManager.fileExists(atPath: staging.path) {
                    try? fileManager.removeItem(at: staging)
                }
                throw error
            }
        }
    }

    private static func importVerifiedBundleInPlace(
        manifest: TatwoSkilletBundleManifestV1,
        bundleURL: URL,
        into store: TatwoSkilletRepositoryStore
    ) throws -> TatwoCapabilityRepositoryV1 {
        let objects = bundleURL.appendingPathComponent("objects", isDirectory: true)
        for revision in manifest.revisions {
            let payload = objects
                .appendingPathComponent(revision.contentDigest, isDirectory: true)
                .appendingPathComponent("payload", isDirectory: true)
            let imported: TatwoSkillRevisionV1
            if revision.id == manifest.exportedRevisionID {
                imported = try store.snapshotCanonicalSkillDirectory(
                    repositoryID: manifest.repositoryID,
                    displayName: manifest.displayName,
                    summary: manifest.summary,
                    sourceDirectory: payload,
                    channel: revision.channel,
                    parentRevisionID: revision.parentRevisionID,
                    createdAt: revision.createdAt
                )
            } else {
                imported = try store.snapshotDetachedSkillDirectory(
                    repositoryID: manifest.repositoryID,
                    displayName: manifest.displayName,
                    summary: manifest.summary,
                    sourceDirectory: payload,
                    channel: revision.channel,
                    parentRevisionID: revision.parentRevisionID,
                    createdAt: revision.createdAt
                )
            }
            guard imported == revision else {
                throw TatwoSkilletBundleError.repositoryConflict(manifest.repositoryID)
            }
        }

        if let stable = manifest.stableRevision {
            try store.promoteRevision(
                repositoryID: manifest.repositoryID,
                revisionID: stable,
                to: .stable
            )
        }
        if let canary = manifest.canaryRevision {
            try store.promoteRevision(
                repositoryID: manifest.repositoryID,
                revisionID: canary,
                to: .canary
            )
        }
        if let rollback = manifest.rollbackRevision {
            try store.promoteRevision(
                repositoryID: manifest.repositoryID,
                revisionID: rollback,
                to: .rollback
            )
        }

        let imported = try store.loadRepository(id: manifest.repositoryID)
        let importedByID = Dictionary(
            imported.revisions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard imported.canonicalRevision == manifest.canonicalRevision,
              imported.stableRevision == manifest.stableRevision,
              imported.canaryRevision == manifest.canaryRevision,
              imported.rollbackRevision == manifest.rollbackRevision,
              manifest.revisions.allSatisfy({
                  importedByID[$0.id] == $0
              })
        else {
            throw TatwoSkilletBundleError.repositoryConflict(manifest.repositoryID)
        }
        return imported
    }

    @discardableResult
    public static func activateRevisionAtomically(
        in store: TatwoSkilletRepositoryStore,
        repositoryID: String,
        revisionID: String,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        verifiedAt: Date
    ) throws -> TatwoDeviceHeadV1 {
        try activateRevisionAtomically(
            in: store,
            repositoryID: repositoryID,
            revisionID: revisionID,
            runtimeRoot: runtimeRoot,
            deviceID: deviceID,
            requestID: requestID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            verifiedAt: verifiedAt,
            beforeDeviceHeadCommit: nil
        )
    }

    /// Imports and activates every authority-bound repository as one
    /// compensating transaction.
    ///
    /// All bundles are verified and applied to an isolated store/runtime first.
    /// The live runtime repositories are then exchanged under one global
    /// activation lock. If any repository commit or the final store commit
    /// fails, every already-exchanged repository is restored before returning.
    /// Previous live payloads and stores are archived rather than deleted.
    @discardableResult
    public static func importAndActivateAuthorityBoundSet(
        _ inputs: [TatwoSkilletBoundBundleInputV1],
        into store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        verifiedAt: Date = Date()
    ) throws -> [TatwoDeviceHeadV1] {
        try importAndActivateAuthorityBoundSet(
            inputs,
            into: store,
            runtimeRoot: runtimeRoot,
            deviceID: deviceID,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision,
            verifiedAt: verifiedAt,
            beforeRepositoryCommit: nil,
            afterStoreCommit: nil,
            testHooks: nil
        )
    }

    /// Captures incoming heads and target-only repositories before releasing
    /// the aggregate runtime/store locks.
    public static func importAndActivateAuthorityBoundSetWithEvidence(
        _ inputs: [TatwoSkilletBoundBundleInputV1],
        into store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        activateTargetPreservedRuntime: Bool = false,
        ownerInitiatedApply: Bool = false,
        verifiedAt: Date = Date()
    ) throws -> TatwoSkilletAuthorityBoundSetActivationV1 {
        try importAndActivateAuthorityBoundSetWithEvidence(
            inputs,
            into: store,
            runtimeRoot: runtimeRoot,
            deviceID: deviceID,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision,
            verifiedAt: verifiedAt,
            activateTargetPreservedRuntime:
                activateTargetPreservedRuntime,
            ownerInitiatedApply: ownerInitiatedApply,
            beforeRepositoryCommit: nil,
            afterStoreCommit: nil,
            testHooks: nil
        )
    }

    /// Aggregate receive path used by Hot Sync.
    ///
    /// If every repository is a strict fast-forward, the existing atomic
    /// import/activation transaction runs unchanged. If any repository
    /// diverges, the default path persists every incoming branch without
    /// moving canonical or runtime state, commits merge proposals, and fails
    /// closed pending human approval. A signed owner-initiated system-pull
    /// instead take-primaries the incoming head (LWW+archive) and activates.
    @discardableResult
    public static func receiveAndActivateAuthorityBoundSet(
        _ inputs: [TatwoSkilletBoundBundleInputV1],
        into store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        activateTargetPreservedRuntime: Bool = false,
        ownerInitiatedApply: Bool = false,
        verifiedAt: Date = Date()
    ) throws -> TatwoSkilletAuthorityBoundSetOutcomeV1 {
        var mergeStage = "verify-set"
        do {
            let manifests = try verifiedSetManifests(
                inputs,
                store: store,
                deviceID: deviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                catalogRevision: catalogRevision
            )
            mergeStage = "detect-divergence"
            let hasDivergence = try manifests.contains { element in
                let existing = try loadRepositoryIfPresent(
                    id: element.manifest.repositoryID,
                    from: store
                )
                guard existing != nil else { return false }
                do {
                    try validateImportCompatibility(
                        existing,
                        manifest: element.manifest
                    )
                    return false
                } catch let error as TatwoSkilletBundleError {
                    guard case .repositoryConflict = error else { throw error }
                    return true
                }
            }
            guard hasDivergence else {
                mergeStage = "fast-forward-activate"
                return .activated(
                    try importAndActivateAuthorityBoundSetWithEvidence(
                        inputs,
                        into: store,
                        runtimeRoot: runtimeRoot,
                        deviceID: deviceID,
                        requestID: requestID,
                        sourceDeviceID: sourceDeviceID,
                        authorityEpoch: authorityEpoch,
                        ledgerSequence: ledgerSequence,
                        catalogRevision: catalogRevision,
                        activateTargetPreservedRuntime:
                            activateTargetPreservedRuntime,
                        verifiedAt: verifiedAt
                    )
                )
            }

            if ownerInitiatedApply {
                mergeStage = "owner-take-primary"
                return .activated(
                    try importAndActivateAuthorityBoundSetWithEvidence(
                        inputs,
                        into: store,
                        runtimeRoot: runtimeRoot,
                        deviceID: deviceID,
                        requestID: requestID,
                        sourceDeviceID: sourceDeviceID,
                        authorityEpoch: authorityEpoch,
                        ledgerSequence: ledgerSequence,
                        catalogRevision: catalogRevision,
                        activateTargetPreservedRuntime:
                            activateTargetPreservedRuntime,
                        ownerInitiatedApply: true,
                        verifiedAt: verifiedAt
                    )
                )
            }

            mergeStage = "persist-pending"
            return .mergeProposed(
                try receiveAuthorityBoundSetWithPendingMerges(
                    manifests,
                    into: store,
                    runtimeRoot: runtimeRoot,
                    deviceID: deviceID,
                    requestID: requestID,
                    sourceDeviceID: sourceDeviceID,
                    createdAt: iso8601Normalized(verifiedAt)
                )
            )
        } catch {
            debugMergeFailure(
                "authority-bound-set",
                stage: mergeStage,
                error: error
            )
            throw error
        }
    }

    /// Reconstructs the target-side evidence for an already committed set
    /// without importing, activating, or advancing any device head.
    ///
    /// This is the recovery path for a process that committed the store and
    /// runtimes but exited before its channel ACK became durable. The complete
    /// authority binding, exact repository set, device heads, snapshot
    /// manifests, and active payloads are re-verified before evidence is
    /// returned.
    @discardableResult
    public static func verifyAuthorityBoundSetIsActive(
        _ inputs: [TatwoSkilletBoundBundleInputV1],
        in store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String
    ) throws -> [TatwoDeviceHeadV1] {
        try verifyAuthorityBoundSetActiveState(
            inputs,
            in: store,
            runtimeRoot: runtimeRoot,
            deviceID: deviceID,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision
        ).heads
    }

    /// Reconstructs incoming heads and target-only evidence while one
    /// runtime/store lock pair still defines the observed snapshot.
    public static func verifyAuthorityBoundSetActiveState(
        _ inputs: [TatwoSkilletBoundBundleInputV1],
        in store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String
    ) throws -> TatwoSkilletAuthorityBoundSetActivationV1 {
        guard !inputs.isEmpty else {
            throw TatwoSkilletBundleError.invalidBundle(
                "Skillet set must not be empty"
            )
        }
        guard isValidIdentifier(deviceID),
              isValidIdentifier(requestID),
              isValidIdentifier(sourceDeviceID),
              isValidIdentifier(catalogRevision),
              ledgerSequence > 0
        else {
            throw TatwoSkilletBundleError.authorityBindingMismatch(
                "set identity or ledger"
            )
        }
        let sortedInputs = inputs.sorted { $0.repositoryID < $1.repositoryID }
        guard Set(sortedInputs.map(\.repositoryID)).count == sortedInputs.count else {
            throw TatwoSkilletBundleError.invalidBundle(
                "Skillet set contains duplicate repositories"
            )
        }
        guard inputs.map(\.repositoryID) == sortedInputs.map(\.repositoryID) else {
            throw TatwoSkilletBundleError.invalidBundle(
                "Skillet set repositories must be sorted by repository id"
            )
        }
        for input in sortedInputs {
            try validateSetInput(
                input,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: deviceID,
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                catalogRevision: catalogRevision
            )
        }

        let runtimeRoot = runtimeRoot.standardizedFileURL
        try requireNoSymbolicLinkComponents(
            runtimeRoot,
            errorPath: runtimeRoot.path
        )
        try requireDirectory(runtimeRoot, errorPath: runtimeRoot.path)
        let runtimeSetLock = runtimeRoot.appendingPathComponent(
            ".set-activation",
            isDirectory: false
        )

        return try TatwoFileLock.withExclusiveLock(for: runtimeSetLock) {
            try store.withExclusiveMutationLock {
                let expectedRepositoryIDs = sortedInputs.map(\.repositoryID)
                let targetPreserved = try targetPreservedRepositories(
                    in: store,
                    runtimeRoot: runtimeRoot,
                    excluding: Set(expectedRepositoryIDs),
                    deviceID: deviceID
                )

                let heads = try sortedInputs.map { input in
                    let repository = try store.loadRepository(
                        id: input.repositoryID
                    )
                    guard let head = repository.deviceHeads.first(where: {
                        $0.deviceID == deviceID
                    }),
                        head.requestID == requestID,
                        head.authorityEpoch == authorityEpoch,
                        head.ledgerSequence == ledgerSequence,
                        head.revisionID == input.revisionID,
                        head.contentDigest == input.contentDigest,
                        head.activationState == .active
                    else {
                        throw TatwoSkilletBundleError.activeRuntimeMismatch(
                            input.repositoryID
                        )
                    }
                    let manifest = try store.loadSnapshotManifest(
                        repositoryID: input.repositoryID,
                        revisionID: input.revisionID
                    )
                    let active = runtimeRoot.appendingPathComponent(
                        input.repositoryID,
                        isDirectory: true
                    )
                    guard try verifyPayload(
                        at: active,
                        manifest: manifest,
                        expectedDigest: input.contentDigest
                    ) else {
                        throw TatwoSkilletBundleError.activeRuntimeMismatch(
                            input.repositoryID
                        )
                    }
                    return head
                }
                return TatwoSkilletAuthorityBoundSetActivationV1(
                    heads: heads,
                    targetPreservedRepositories: targetPreserved
                )
            }
        }
    }

    /// Verifies repositories that exist only on this target device.
    ///
    /// A target-only repository is not a divergent branch of an incoming
    /// repository with another identifier. Its store metadata, device head and
    /// active runtime remain untouched and are returned as explicit evidence.
    /// Runtime-only directories without matching Skillet metadata still fail
    /// closed.
    public static func verifyTargetPreservedRepositories(
        in store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        excluding repositoryIDs: [String],
        deviceID: String
    ) throws -> [TatwoSkilletTargetPreservedRepositoryV1] {
        guard isValidIdentifier(deviceID),
              repositoryIDs.allSatisfy(isValidIdentifier),
              Set(repositoryIDs).count == repositoryIDs.count
        else {
            throw TatwoSkilletBundleError.invalidBundle(
                "target-preserved repository identity is unsafe"
            )
        }
        let runtimeRoot = runtimeRoot.standardizedFileURL
        try requireNoSymbolicLinkComponents(
            runtimeRoot,
            errorPath: runtimeRoot.path
        )
        try requireDirectory(runtimeRoot, errorPath: runtimeRoot.path)
        let runtimeSetLock = runtimeRoot.appendingPathComponent(
            ".set-activation",
            isDirectory: false
        )
        return try TatwoFileLock.withExclusiveLock(for: runtimeSetLock) {
            try store.withExclusiveMutationLock {
                try targetPreservedRepositories(
                    in: store,
                    runtimeRoot: runtimeRoot,
                    excluding: Set(repositoryIDs),
                    deviceID: deviceID
                )
            }
        }
    }

    /// Reads one live runtime repository without mutating it.
    ///
    /// The read is serialized with aggregate activation so callers never
    /// mistake an in-flight atomic swap for a stable runtime snapshot.
    public static func readRuntimeRepository(
        runtimeRoot: URL,
        repositoryID: String
    ) throws -> TatwoSkilletRuntimeReadbackV1 {
        let runtimeRoot = runtimeRoot.standardizedFileURL
        guard isValidIdentifier(repositoryID) else {
            throw TatwoSkilletBundleError.unsafeRuntimePath(repositoryID)
        }
        try requireNoSymbolicLinkComponents(
            runtimeRoot,
            errorPath: runtimeRoot.path
        )
        try requireDirectory(runtimeRoot, errorPath: runtimeRoot.path)
        let runtimeSetLock = runtimeRoot.appendingPathComponent(
            ".set-activation",
            isDirectory: false
        )
        return try TatwoFileLock.withExclusiveLock(for: runtimeSetLock) {
            try readRuntimeRepositoryLocked(
                runtimeRoot: runtimeRoot,
                repositoryID: repositoryID
            )
        }
    }

    /// Executes a metadata-only operation while holding the same runtime-set
    /// lock used by activation, then proves the runtime tree is byte-identical.
    ///
    /// Merge approval/rejection advances repository metadata only. This helper
    /// prevents a receipt from claiming `unchanged` based on a literal string.
    public static func preservingRuntimeRepository<Result>(
        runtimeRoot: URL,
        repositoryID: String,
        operation: () throws -> Result
    ) throws -> (
        result: Result,
        before: TatwoSkilletRuntimeReadbackV1,
        after: TatwoSkilletRuntimeReadbackV1
    ) {
        let runtimeRoot = runtimeRoot.standardizedFileURL
        guard isValidIdentifier(repositoryID) else {
            throw TatwoSkilletBundleError.unsafeRuntimePath(repositoryID)
        }
        try requireNoSymbolicLinkComponents(
            runtimeRoot,
            errorPath: runtimeRoot.path
        )
        try requireDirectory(runtimeRoot, errorPath: runtimeRoot.path)
        let runtimeSetLock = runtimeRoot.appendingPathComponent(
            ".set-activation",
            isDirectory: false
        )
        return try TatwoFileLock.withExclusiveLock(for: runtimeSetLock) {
            let before = try readRuntimeRepositoryLocked(
                runtimeRoot: runtimeRoot,
                repositoryID: repositoryID
            )
            let result = try operation()
            let after = try readRuntimeRepositoryLocked(
                runtimeRoot: runtimeRoot,
                repositoryID: repositoryID
            )
            guard before == after else {
                throw TatwoSkilletBundleError.runtimeMutationDetected(
                    repositoryID
                )
            }
            return (result, before, after)
        }
    }

    @discardableResult
    static func importAndActivateAuthorityBoundSet(
        _ inputs: [TatwoSkilletBoundBundleInputV1],
        into store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        verifiedAt: Date,
        activateTargetPreservedRuntime: Bool = false,
        beforeRepositoryCommit: ((String, Int) throws -> Void)?,
        afterStoreCommit: (() throws -> Void)? = nil,
        testHooks: SetTransactionTestHooks? = nil
    ) throws -> [TatwoDeviceHeadV1] {
        try importAndActivateAuthorityBoundSetWithEvidence(
            inputs,
            into: store,
            runtimeRoot: runtimeRoot,
            deviceID: deviceID,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision,
            verifiedAt: verifiedAt,
            activateTargetPreservedRuntime:
                activateTargetPreservedRuntime,
            beforeRepositoryCommit: beforeRepositoryCommit,
            afterStoreCommit: afterStoreCommit,
            testHooks: testHooks
        ).heads
    }

    @discardableResult
    static func importAndActivateAuthorityBoundSetWithEvidence(
        _ inputs: [TatwoSkilletBoundBundleInputV1],
        into store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        verifiedAt: Date,
        activateTargetPreservedRuntime: Bool = false,
        ownerInitiatedApply: Bool = false,
        beforeRepositoryCommit: ((String, Int) throws -> Void)?,
        afterStoreCommit: (() throws -> Void)? = nil,
        testHooks: SetTransactionTestHooks? = nil
    ) throws -> TatwoSkilletAuthorityBoundSetActivationV1 {
        guard !inputs.isEmpty else {
            throw TatwoSkilletBundleError.invalidBundle(
                "Skillet set must not be empty"
            )
        }
        guard isValidIdentifier(deviceID),
              isValidIdentifier(requestID),
              isValidIdentifier(sourceDeviceID),
              isValidIdentifier(catalogRevision),
              ledgerSequence > 0
        else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("set identity or ledger")
        }
        let sortedInputs = inputs.sorted { $0.repositoryID < $1.repositoryID }
        guard Set(sortedInputs.map(\.repositoryID)).count == sortedInputs.count else {
            throw TatwoSkilletBundleError.invalidBundle(
                "Skillet set contains duplicate repositories"
            )
        }
        guard inputs.map(\.repositoryID) == sortedInputs.map(\.repositoryID) else {
            throw TatwoSkilletBundleError.invalidBundle(
                "Skillet set repositories must be sorted by repository id"
            )
        }
        for input in sortedInputs {
            try validateSetInput(
                input,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: deviceID,
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                catalogRevision: catalogRevision
            )
        }

        let fileManager = FileManager.default
        let storeRoot = store.rootURL.standardizedFileURL
        try requireNoSymbolicLinkComponents(storeRoot, errorPath: storeRoot.path)
        try prepareRuntimeRoot(runtimeRoot)
        let runtimeSetLock = runtimeRoot.appendingPathComponent(
            ".set-activation",
            isDirectory: false
        )

        return try TatwoFileLock.withExclusiveLock(for: runtimeSetLock) {
            try store.withExclusiveMutationLock {
                let incomingRepositoryIDs = Set(sortedInputs.map(\.repositoryID))
                let targetPreservedBefore = try targetPreservedRepositories(
                    in: store,
                    runtimeRoot: runtimeRoot,
                    excluding: incomingRepositoryIDs,
                    deviceID: deviceID
                )
                let targetPreservedExpectedAfter = targetPreservedBefore.map {
                    preserved in
                    guard activateTargetPreservedRuntime,
                          preserved.state == .storePreserved
                    else {
                        return preserved
                    }
                    return TatwoSkilletTargetPreservedRepositoryV1(
                        repositoryID: preserved.repositoryID,
                        revisionID: preserved.revisionID,
                        contentDigest: preserved.contentDigest,
                        state: .runtimePreserved
                    )
                }
                let storeParent = storeRoot.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: storeParent,
                    withIntermediateDirectories: true
                )
                let transactionID =
                    "\(requestID)-e\(authorityEpoch)-s\(ledgerSequence)-\(UUID().uuidString)"
                let stagedStoreRoot = storeParent.appendingPathComponent(
                    ".\(storeRoot.lastPathComponent).set-staging-\(transactionID)",
                    isDirectory: true
                )
                let stagedRuntimeRoot = runtimeRoot
                    .appendingPathComponent(".set-staging", isDirectory: true)
                    .appendingPathComponent(transactionID, isDirectory: true)
                let hadStore = fileManager.fileExists(atPath: storeRoot.path)
                let stagedStore = TatwoSkilletRepositoryStore(rootURL: stagedStoreRoot)
                var stagedHeads: [TatwoDeviceHeadV1] = []
                var promotedTargetRepositoryIDs: [String] = []
                var runtimeCommits: [RuntimeSetCommit] = []
                var storeCommitted = false
                var transactionStage = "prepare-staging"

                do {
                    if let prepareStagedStore = testHooks?.prepareStagedStore {
                        try prepareStagedStore(
                            storeRoot,
                            stagedStoreRoot,
                            hadStore
                        )
                    } else if hadStore {
                        try requireDirectory(storeRoot, errorPath: storeRoot.path)
                        try fileManager.copyItem(at: storeRoot, to: stagedStoreRoot)
                    } else {
                        try fileManager.createDirectory(
                            at: stagedStoreRoot,
                            withIntermediateDirectories: true
                        )
                    }
                    if let prepareStagedRuntime = testHooks?.prepareStagedRuntime {
                        try prepareStagedRuntime(stagedRuntimeRoot)
                    } else {
                        try prepareRuntimeRoot(stagedRuntimeRoot)
                    }

                    for input in sortedInputs {
                        transactionStage = "verify-import-\(input.repositoryID)"
                        let manifest = try verifyAuthorityBoundBundle(
                            at: input.bundleURL,
                            binding: input.binding,
                            expectedRequestID: requestID,
                            expectedSourceDeviceID: sourceDeviceID,
                            expectedTargetDeviceID: deviceID,
                            expectedAuthorityEpoch: authorityEpoch,
                            expectedLedgerSequence: ledgerSequence,
                            expectedCatalogRevision: catalogRevision
                        )
                        try validateSetManifest(manifest, input: input)
                        if ownerInitiatedApply {
                            try persistIncomingBranch(
                                manifest: manifest,
                                bundleURL: input.bundleURL,
                                into: stagedStore
                            )
                            _ = try stagedStore.adoptCanonicalRevision(
                                repositoryID: manifest.repositoryID,
                                revisionID: input.revisionID,
                                requestID: requestID,
                                sourceDeviceID: sourceDeviceID,
                                recordedAt: verifiedAt
                            )
                        } else {
                            let existing = try loadRepositoryIfPresent(
                                id: manifest.repositoryID,
                                from: stagedStore
                            )
                            try validateImportCompatibility(existing, manifest: manifest)
                            _ = try importVerifiedBundleInPlace(
                                manifest: manifest,
                                bundleURL: input.bundleURL,
                                into: stagedStore
                            )
                        }
                        transactionStage = "activate-staged-\(input.repositoryID)"
                        let head = try activateRevisionAtomically(
                            in: stagedStore,
                            repositoryID: input.repositoryID,
                            revisionID: input.revisionID,
                            runtimeRoot: stagedRuntimeRoot,
                            deviceID: deviceID,
                            requestID: requestID,
                            authorityEpoch: authorityEpoch,
                            ledgerSequence: ledgerSequence,
                            verifiedAt: verifiedAt,
                            beforeDeviceHeadCommit: nil
                        )
                        guard head.contentDigest == input.contentDigest else {
                            throw TatwoSkilletBundleError.authorityBindingMismatch(
                                "set content digest"
                            )
                        }
                        stagedHeads.append(head)
                    }

                    if activateTargetPreservedRuntime {
                        for preserved in targetPreservedBefore
                        where preserved.state == .storePreserved
                        {
                            let existingRuntime = runtimeRoot
                                .appendingPathComponent(
                                    preserved.repositoryID,
                                    isDirectory: true
                                )
                            guard !fileManager.fileExists(
                                atPath: existingRuntime.path
                            ) else {
                                throw TatwoSkilletBundleError
                                    .activeRuntimeMismatch(
                                        preserved.repositoryID
                                    )
                            }
                            transactionStage =
                                "activate-target-preserved-\(preserved.repositoryID)"
                            let head = try activateRevisionAtomically(
                                in: stagedStore,
                                repositoryID: preserved.repositoryID,
                                revisionID: preserved.revisionID,
                                runtimeRoot: stagedRuntimeRoot,
                                deviceID: deviceID,
                                requestID: requestID,
                                authorityEpoch: authorityEpoch,
                                ledgerSequence: ledgerSequence,
                                verifiedAt: verifiedAt,
                                beforeDeviceHeadCommit: nil
                            )
                            guard head.revisionID == preserved.revisionID,
                                  head.contentDigest == preserved.contentDigest,
                                  head.activationState == .active
                            else {
                                throw TatwoSkilletBundleError
                                    .activeRuntimeMismatch(
                                        preserved.repositoryID
                                    )
                            }
                            promotedTargetRepositoryIDs.append(
                                preserved.repositoryID
                            )
                        }
                    }

                    transactionStage = "remove-staged-store-lock"
                    // All staged-store APIs must finish before this point. The
                    // transaction keeps the stable store lock while it removes
                    // only the private UUID-bound staging lock, then commits
                    // runtimes and the staged directory without reopening it.
                    try removeEphemeralStoreMutationLock(for: stagedStore)

                    transactionStage = "commit-runtimes"
                    for (index, input) in sortedInputs.enumerated() {
                        try beforeRepositoryCommit?(input.repositoryID, index)
                        let stagedActive = stagedRuntimeRoot.appendingPathComponent(
                            input.repositoryID,
                            isDirectory: true
                        )
                        try requireDirectory(
                            stagedActive,
                            errorPath: stagedActive.path
                        )
                        let active = runtimeRoot.appendingPathComponent(
                            input.repositoryID,
                            isDirectory: true
                        )
                        try requireExistingRuntimeItemIsDirectory(active)
                        let hadActive = fileManager.fileExists(atPath: active.path)
                        let rollback = runtimeRoot
                            .appendingPathComponent(".set-rollback", isDirectory: true)
                            .appendingPathComponent(requestID, isDirectory: true)
                            .appendingPathComponent(input.repositoryID, isDirectory: true)
                            .appendingPathComponent(
                                UUID().uuidString,
                                isDirectory: true
                            )
                        if hadActive {
                            try fileManager.createDirectory(
                                at: rollback.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try atomicExchange(
                                stagedActive,
                                active,
                                testHooks: testHooks
                            )
                            do {
                                try atomicRename(stagedActive, rollback)
                            } catch {
                                do {
                                    try atomicExchange(
                                        stagedActive,
                                        active,
                                        testHooks: testHooks
                                    )
                                } catch {
                                    throw TatwoSkilletBundleError.rollbackFailed(
                                        active.path
                                    )
                                }
                                throw error
                            }
                        } else {
                            try atomicRename(stagedActive, active)
                        }
                        runtimeCommits.append(
                            .init(
                                repositoryID: input.repositoryID,
                                active: active,
                                rollback: hadActive ? rollback : nil
                            )
                        )
                    }
                    for repositoryID in promotedTargetRepositoryIDs.sorted() {
                        transactionStage =
                            "commit-target-preserved-runtime-\(repositoryID)"
                        let stagedActive = stagedRuntimeRoot.appendingPathComponent(
                            repositoryID,
                            isDirectory: true
                        )
                        try requireDirectory(
                            stagedActive,
                            errorPath: stagedActive.path
                        )
                        let active = runtimeRoot.appendingPathComponent(
                            repositoryID,
                            isDirectory: true
                        )
                        try requireExistingRuntimeItemIsDirectory(active)
                        let hadActive = fileManager.fileExists(atPath: active.path)
                        let rollback = runtimeRoot
                            .appendingPathComponent(
                                ".set-rollback",
                                isDirectory: true
                            )
                            .appendingPathComponent(
                                requestID,
                                isDirectory: true
                            )
                            .appendingPathComponent(
                                repositoryID,
                                isDirectory: true
                            )
                            .appendingPathComponent(
                                UUID().uuidString,
                                isDirectory: true
                            )
                        if hadActive {
                            try fileManager.createDirectory(
                                at: rollback.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try atomicExchange(
                                stagedActive,
                                active,
                                testHooks: testHooks
                            )
                            do {
                                try atomicRename(stagedActive, rollback)
                            } catch {
                                do {
                                    try atomicExchange(
                                        stagedActive,
                                        active,
                                        testHooks: testHooks
                                    )
                                } catch {
                                    throw TatwoSkilletBundleError.rollbackFailed(
                                        active.path
                                    )
                                }
                                throw error
                            }
                        } else {
                            try atomicRename(stagedActive, active)
                        }
                        runtimeCommits.append(
                            .init(
                                repositoryID: repositoryID,
                                active: active,
                                rollback: hadActive ? rollback : nil
                            )
                        )
                    }

                    transactionStage = "commit-store"
                    if hadStore {
                        try atomicExchange(
                            stagedStoreRoot,
                            storeRoot,
                            testHooks: testHooks
                        )
                    } else {
                        try atomicRename(stagedStoreRoot, storeRoot)
                    }
                    storeCommitted = true
                    try afterStoreCommit?()

                    transactionStage = "verify-active-store"
                    let activeStore = TatwoSkilletRepositoryStore(rootURL: storeRoot)
                    for input in sortedInputs {
                        let repository = try activeStore.loadRepository(
                            id: input.repositoryID
                        )
                        guard let head = repository.deviceHeads.first(where: {
                            $0.deviceID == deviceID
                        }),
                            head.requestID == requestID,
                            head.authorityEpoch == authorityEpoch,
                            head.ledgerSequence == ledgerSequence,
                            head.revisionID == input.revisionID,
                            head.contentDigest == input.contentDigest,
                            head.activationState == .active
                        else {
                            throw TatwoSkilletBundleError.activeRuntimeMismatch(
                                input.repositoryID
                            )
                        }
                        let manifest = try activeStore.loadSnapshotManifest(
                            repositoryID: input.repositoryID,
                            revisionID: input.revisionID
                        )
                        let active = runtimeRoot.appendingPathComponent(
                            input.repositoryID,
                            isDirectory: true
                        )
                        guard try verifyPayload(
                            at: active,
                            manifest: manifest,
                            expectedDigest: input.contentDigest
                        ) else {
                            throw TatwoSkilletBundleError.activeRuntimeMismatch(
                                input.repositoryID
                            )
                        }
                    }
                    let targetPreservedAfter = try targetPreservedRepositories(
                        in: activeStore,
                        runtimeRoot: runtimeRoot,
                        excluding: incomingRepositoryIDs,
                        deviceID: deviceID
                    )
                    guard targetPreservedAfter == targetPreservedExpectedAfter else {
                        throw TatwoSkilletBundleError.repositoryConflict(
                            targetPreservedExpectedAfter.first?.repositoryID
                                ?? targetPreservedAfter.first?.repositoryID
                                ?? requestID
                        )
                    }

                    transactionStage = "archive-transaction"
                    if hadStore {
                        archivePreviousStore(
                            at: stagedStoreRoot,
                            storeRoot: storeRoot,
                            fileManager: fileManager
                        )
                    }
                    archiveCompletedSetRuntime(
                        stagedRuntimeRoot,
                        runtimeRoot: runtimeRoot,
                        fileManager: fileManager
                    )
                    return TatwoSkilletAuthorityBoundSetActivationV1(
                        heads: stagedHeads.sorted {
                            $0.repositoryID < $1.repositoryID
                        },
                        targetPreservedRepositories: targetPreservedAfter
                    )
                } catch {
                    debugMergeFailure(
                        "authority-fast-forward-set",
                        stage: transactionStage,
                        error: error
                    )
                    let transactionError = error
                    var storeRollbackFailed = false
                    var runtimeRollbackFailed = false
                    if storeCommitted {
                        do {
                            if hadStore {
                                try atomicExchange(
                                    storeRoot,
                                    stagedStoreRoot,
                                    testHooks: testHooks
                                )
                            } else {
                                try atomicRename(storeRoot, stagedStoreRoot)
                            }
                        } catch {
                            storeRollbackFailed = true
                        }
                    }
                    try? removeEphemeralStoreMutationLock(for: stagedStore)
                    do {
                        try rollbackRuntimeSet(
                            runtimeCommits,
                            runtimeRoot: runtimeRoot,
                            requestID: requestID,
                            fileManager: fileManager,
                            testHooks: testHooks
                        )
                    } catch {
                        runtimeRollbackFailed = true
                    }
                    if !storeRollbackFailed {
                        archiveFailedSetStore(
                            stagedStoreRoot,
                            storeRoot: storeRoot,
                            requestID: requestID,
                            fileManager: fileManager
                        )
                    }
                    if !runtimeRollbackFailed {
                        archiveFailedSetRuntime(
                            stagedRuntimeRoot,
                            runtimeRoot: runtimeRoot,
                            requestID: requestID,
                            fileManager: fileManager
                        )
                    }
                    if storeRollbackFailed {
                        throw TatwoSkilletBundleError.rollbackFailed(storeRoot.path)
                    }
                    if runtimeRollbackFailed {
                        throw TatwoSkilletBundleError.rollbackFailed(runtimeRoot.path)
                    }
                    throw transactionError
                }
            }
        }
    }

    static func removeEphemeralStoreMutationLock(
        for store: TatwoSkilletRepositoryStore
    ) throws {
        let stagedRootName = store.rootURL.standardizedFileURL.lastPathComponent
        let stagingMarkers = [
            ".import-staging-",
            ".set-staging-",
            ".pending-merge-",
            ".merge-staging-",
        ]
        guard stagedRootName.hasPrefix("."),
              stagingMarkers.contains(where: stagedRootName.contains),
              stagedRootName.count > 36,
              UUID(uuidString: String(stagedRootName.suffix(36))) != nil
        else {
            throw TatwoSkilletBundleError.unsafeRuntimePath(store.rootURL.path)
        }
        let lock = store.mutationLockFileURL
        var status = stat()
        guard lstat(lock.path, &status) == 0 else {
            if errno == ENOENT {
                return
            }
            throw TatwoSkilletBundleError.unsafeRuntimePath(lock.path)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_uid == geteuid(),
              status.st_size == 0
        else {
            throw TatwoSkilletBundleError.unsafeRuntimePath(lock.path)
        }
        guard unlink(lock.path) == 0 || errno == ENOENT else {
            throw TatwoSkilletBundleError.unsafeRuntimePath(lock.path)
        }
    }

    private struct RuntimeSetCommit {
        let repositoryID: String
        let active: URL
        let rollback: URL?
    }

    private static func runtimeSkillRepositoryIDs(at runtimeRoot: URL) throws -> [String] {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: runtimeRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: []
        )
        var repositoryIDs: [String] = []
        for child in children {
            let repositoryID = child.lastPathComponent
            guard !repositoryID.hasPrefix(".") else { continue }
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                throw TatwoSkilletBundleError.unsafeRuntimePath(child.path)
            }
            guard values.isDirectory == true else { continue }
            let skillManifest = child.appendingPathComponent(
                "SKILL.md",
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: skillManifest.path) else {
                continue
            }
            try requireNoSymbolicLinkComponents(child, errorPath: child.path)
            repositoryIDs.append(repositoryID)
        }
        return repositoryIDs.sorted()
    }

    private static func targetPreservedRepositories(
        in store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        excluding incomingRepositoryIDs: Set<String>,
        deviceID: String
    ) throws -> [TatwoSkilletTargetPreservedRepositoryV1] {
        let existingRepositoryIDs = Set(try store.listRepositoryIDs())
        let runtimeRepositoryIDs: Set<String>
        if FileManager.default.fileExists(atPath: runtimeRoot.path) {
            runtimeRepositoryIDs = Set(
                try runtimeSkillRepositoryIDs(at: runtimeRoot)
            )
        } else {
            runtimeRepositoryIDs = []
        }
        if let runtimeOnlyRepositoryID = runtimeRepositoryIDs
            .subtracting(existingRepositoryIDs)
            .sorted()
            .first
        {
            throw TatwoSkilletBundleError.repositoryConflict(
                runtimeOnlyRepositoryID
            )
        }

        return try existingRepositoryIDs
            .subtracting(incomingRepositoryIDs)
            .sorted()
            .map { repositoryID in
                let repository = try store.loadRepository(id: repositoryID)
                let runtimeIsPresent = runtimeRepositoryIDs.contains(repositoryID)
                let deviceHead = repository.deviceHeads.first {
                    $0.deviceID == deviceID
                }
                if runtimeIsPresent {
                    guard let deviceHead,
                          deviceHead.activationState == .active,
                          isRevisionID(deviceHead.revisionID),
                          isSHA256(deviceHead.contentDigest),
                          repository.revisions.contains(where: {
                              $0.id == deviceHead.revisionID
                                  && $0.contentDigest == deviceHead.contentDigest
                          })
                    else {
                        throw TatwoSkilletBundleError.activeRuntimeMismatch(
                            repositoryID
                        )
                    }
                    let manifest = try store.loadSnapshotManifest(
                        repositoryID: repositoryID,
                        revisionID: deviceHead.revisionID
                    )
                    let active = runtimeRoot.appendingPathComponent(
                        repositoryID,
                        isDirectory: true
                    )
                    guard try verifyPayload(
                        at: active,
                        manifest: manifest,
                        expectedDigest: deviceHead.contentDigest
                    ) else {
                        throw TatwoSkilletBundleError.activeRuntimeMismatch(
                            repositoryID
                        )
                    }
                    return TatwoSkilletTargetPreservedRepositoryV1(
                        repositoryID: repositoryID,
                        revisionID: deviceHead.revisionID,
                        contentDigest: deviceHead.contentDigest,
                        state: .runtimePreserved
                    )
                }

                if deviceHead?.activationState == .active {
                    throw TatwoSkilletBundleError.activeRuntimeMismatch(
                        repositoryID
                    )
                }
                guard let revisionID = repository.canonicalRevision,
                      let revision = repository.revisions.first(where: {
                          $0.id == revisionID
                      }),
                      isSHA256(revision.contentDigest)
                else {
                    throw TatwoSkilletBundleError.repositoryConflict(
                        repositoryID
                    )
                }
                guard try store.verifyRevision(
                    repositoryID: repositoryID,
                    revisionID: revisionID
                ) else {
                    throw TatwoSkilletBundleError.repositoryConflict(
                        repositoryID
                    )
                }
                return TatwoSkilletTargetPreservedRepositoryV1(
                    repositoryID: repositoryID,
                    revisionID: revisionID,
                    contentDigest: revision.contentDigest,
                    state: .storePreserved
                )
            }
    }

    private static func readRuntimeRepositoryLocked(
        runtimeRoot: URL,
        repositoryID: String
    ) throws -> TatwoSkilletRuntimeReadbackV1 {
        let active = runtimeRoot.appendingPathComponent(
            repositoryID,
            isDirectory: true
        )
        var status = stat()
        guard lstat(active.path, &status) == 0 else {
            if errno == ENOENT {
                return TatwoSkilletRuntimeReadbackV1(
                    repositoryID: repositoryID,
                    state: .absent,
                    contentDigest: nil,
                    fileCount: 0,
                    byteCount: 0
                )
            }
            throw TatwoSkilletBundleError.unsafeRuntimePath(active.path)
        }
        try requireNoSymbolicLinkComponents(active, errorPath: active.path)
        do {
            try requireDirectory(active, errorPath: active.path)
        } catch {
            throw TatwoSkilletBundleError.unsafeRuntimePath(active.path)
        }

        let paths = try enumerateRegularFiles(in: active).sorted(by: {
            portablePathPrecedes($0, $1)
        })
        guard paths.contains("SKILL.md") else {
            throw TatwoSkilletBundleError.activeRuntimeMismatch(repositoryID)
        }
        var files: [(relativePath: String, data: Data)] = []
        files.reserveCapacity(paths.count)
        var byteCount = 0
        for path in paths {
            guard isSafeRelativePath(path),
                  !isProhibited(relativePath: path)
            else {
                throw TatwoSkilletBundleError.unsafeRuntimePath(
                    active.appendingPathComponent(path).path
                )
            }
            let fileURL = active.appendingPathComponent(path)
            try requireRegularFile(fileURL, errorPath: fileURL.path)
            let data = try Data(contentsOf: fileURL)
            guard !TatwoSkilletSnapshotSecurityPolicy
                .containsProhibitedContent(data)
            else {
                throw TatwoSkilletBundleError.unsafeRuntimePath(fileURL.path)
            }
            files.append((path, data))
            byteCount += data.count
        }
        return TatwoSkilletRuntimeReadbackV1(
            repositoryID: repositoryID,
            state: .present,
            contentDigest: snapshotDigest(files),
            fileCount: files.count,
            byteCount: byteCount
        )
    }

    private static func validateSetInput(
        _ input: TatwoSkilletBoundBundleInputV1,
        requestID: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String
    ) throws {
        guard isValidIdentifier(input.repositoryID),
              isRevisionID(input.revisionID),
              isSHA256(input.contentDigest),
              isSHA256(input.bundleDigest),
              input.binding.repositoryID == input.repositoryID,
              input.binding.exportedRevisionID == input.revisionID,
              input.binding.bundleDigest == input.bundleDigest
        else {
            throw TatwoSkilletBundleError.authorityBindingMismatch("set manifest")
        }
        let manifest = try verifyAuthorityBoundBundle(
            at: input.bundleURL,
            binding: input.binding,
            expectedRequestID: requestID,
            expectedSourceDeviceID: sourceDeviceID,
            expectedTargetDeviceID: targetDeviceID,
            expectedAuthorityEpoch: authorityEpoch,
            expectedLedgerSequence: ledgerSequence,
            expectedCatalogRevision: catalogRevision
        )
        try validateSetManifest(manifest, input: input)
    }

    private static func validateSetManifest(
        _ manifest: TatwoSkilletBundleManifestV1,
        input: TatwoSkilletBoundBundleInputV1
    ) throws {
        guard manifest.repositoryID == input.repositoryID,
              manifest.exportedRevisionID == input.revisionID,
              manifest.revisions.last?.contentDigest == input.contentDigest
        else {
            throw TatwoSkilletBundleError.authorityBindingMismatch(
                "set repository revision"
            )
        }
    }

    private static func rollbackRuntimeSet(
        _ commits: [RuntimeSetCommit],
        runtimeRoot: URL,
        requestID: String,
        fileManager: FileManager,
        testHooks: SetTransactionTestHooks?
    ) throws {
        var restorationFailurePath: String?
        for commit in commits.reversed() {
            let failed = runtimeRoot
                .appendingPathComponent(".set-failed", isDirectory: true)
                .appendingPathComponent(requestID, isDirectory: true)
                .appendingPathComponent(commit.repositoryID, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(
                at: failed.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let rollback = commit.rollback {
                do {
                    try atomicExchange(
                        commit.active,
                        rollback,
                        testHooks: testHooks
                    )
                } catch {
                    if restorationFailurePath == nil {
                        restorationFailurePath = commit.active.path
                    }
                    continue
                }
                // The prior active payload is already restored. If quarantine
                // fails, preserve the failed candidate at the rollback path and
                // continue restoring the remaining repositories.
                try? atomicRename(rollback, failed)
            } else {
                do {
                    try atomicRename(commit.active, failed)
                } catch {
                    if restorationFailurePath == nil {
                        restorationFailurePath = commit.active.path
                    }
                }
            }
        }
        if let restorationFailurePath {
            throw TatwoSkilletBundleError.rollbackFailed(restorationFailurePath)
        }
    }

    private static func archiveFailedSetStore(
        _ stagedStore: URL,
        storeRoot: URL,
        requestID: String,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: stagedStore.path) else { return }
        let archive = storeRoot.deletingLastPathComponent()
            .appendingPathComponent(".skillet-set-failed", isDirectory: true)
            .appendingPathComponent(requestID, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: archive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: stagedStore, to: archive)
        } catch {
            // Preserve the staged store in place for later inspection.
        }
    }

    private static func archiveCompletedSetRuntime(
        _ stagedRuntime: URL,
        runtimeRoot: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: stagedRuntime.path) else { return }
        let archive = runtimeRoot
            .appendingPathComponent(".set-transaction-archive", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: archive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: stagedRuntime, to: archive)
        } catch {
            // Preserve the completed staging tree in place for later review.
        }
    }

    private static func archiveFailedSetRuntime(
        _ stagedRuntime: URL,
        runtimeRoot: URL,
        requestID: String,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: stagedRuntime.path) else { return }
        let archive = runtimeRoot
            .appendingPathComponent(".set-failed", isDirectory: true)
            .appendingPathComponent(requestID, isDirectory: true)
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: archive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: stagedRuntime, to: archive)
        } catch {
            // Preserve the failed staging tree in place for later inspection.
        }
    }

    @discardableResult
    static func activateRevisionAtomically(
        in store: TatwoSkilletRepositoryStore,
        repositoryID: String,
        revisionID: String,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        verifiedAt: Date,
        beforeDeviceHeadCommit: (() throws -> Void)?
    ) throws -> TatwoDeviceHeadV1 {
        try prepareRuntimeRoot(runtimeRoot)
        let setLockTarget = runtimeRoot.appendingPathComponent(
            ".set-activation",
            isDirectory: false
        )
        return try TatwoFileLock.withExclusiveLock(for: setLockTarget) {
            try activateRevisionAtomicallyLocked(
                in: store,
                repositoryID: repositoryID,
                revisionID: revisionID,
                runtimeRoot: runtimeRoot,
                deviceID: deviceID,
                requestID: requestID,
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                verifiedAt: verifiedAt,
                beforeDeviceHeadCommit: beforeDeviceHeadCommit
            )
        }
    }

    @discardableResult
    private static func activateRevisionAtomicallyLocked(
        in store: TatwoSkilletRepositoryStore,
        repositoryID: String,
        revisionID: String,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        verifiedAt: Date,
        beforeDeviceHeadCommit: (() throws -> Void)?
    ) throws -> TatwoDeviceHeadV1 {
        guard isValidIdentifier(repositoryID),
              isRevisionID(revisionID),
              isValidIdentifier(deviceID),
              isValidIdentifier(requestID),
              ledgerSequence > 0
        else {
            throw TatwoSkilletBundleError.unsafeRuntimePath(repositoryID)
        }
        try prepareRuntimeRoot(runtimeRoot)

        let lockTarget = runtimeRoot
            .appendingPathComponent(".activation-locks", isDirectory: true)
            .appendingPathComponent(repositoryID)
        return try TatwoFileLock.withExclusiveLock(for: lockTarget) {
            let repository = try store.loadRepository(id: repositoryID)
            guard let revision = repository.revisions.first(where: { $0.id == revisionID }),
                  try store.verifyRevision(
                      repositoryID: repositoryID,
                      revisionID: revisionID
                  )
            else {
                throw TatwoSkilletRepositoryStoreError.revisionNotFound(revisionID)
            }
            let snapshotManifest = try store.loadSnapshotManifest(
                repositoryID: repositoryID,
                revisionID: revisionID
            )

            if let existing = repository.deviceHeads.first(where: { $0.deviceID == deviceID }) {
                if existing.authorityEpoch > authorityEpoch
                    || (existing.authorityEpoch == authorityEpoch
                        && (existing.ledgerSequence ?? 0) > ledgerSequence)
                {
                    throw TatwoSkilletRepositoryStoreError.staleDeviceHead(deviceID)
                }
                if existing.authorityEpoch == authorityEpoch,
                   existing.ledgerSequence == ledgerSequence
                {
                    guard existing.requestID == requestID,
                          existing.revisionID == revisionID,
                          existing.contentDigest == revision.contentDigest,
                          existing.activationState == .active
                    else {
                        throw TatwoSkilletRepositoryStoreError.staleDeviceHead(deviceID)
                    }
                    let active = runtimeRoot.appendingPathComponent(
                        repositoryID,
                        isDirectory: true
                    )
                    guard (try? verifyPayload(
                        at: active,
                        manifest: snapshotManifest,
                        expectedDigest: revision.contentDigest
                    )) == true
                    else {
                        throw TatwoSkilletBundleError.activeRuntimeMismatch(repositoryID)
                    }
                    return existing
                }
            }

            let fileManager = FileManager.default
            let staging = runtimeRoot
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent(
                    "\(repositoryID)-e\(authorityEpoch)-s\(ledgerSequence)-\(UUID().uuidString)",
                    isDirectory: true
                )
            try store.materializeRevision(
                repositoryID: repositoryID,
                revisionID: revisionID,
                to: staging
            )
            guard try verifyPayload(
                at: staging,
                manifest: snapshotManifest,
                expectedDigest: revision.contentDigest
            ) else {
                throw TatwoSkilletBundleError.corruptedObject(revision.contentDigest)
            }

            let active = runtimeRoot.appendingPathComponent(repositoryID, isDirectory: true)
            try requireExistingRuntimeItemIsDirectory(active)
            let rollbackArchive = runtimeRoot
                .appendingPathComponent(".rollback", isDirectory: true)
                .appendingPathComponent(repositoryID, isDirectory: true)
                .appendingPathComponent(
                    "e\(authorityEpoch)-s\(ledgerSequence)-\(requestID)-\(UUID().uuidString)",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: rollbackArchive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let hadActive = fileManager.fileExists(atPath: active.path)
            do {
                if hadActive {
                    try atomicExchange(staging, active)
                    do {
                        try fileManager.moveItem(at: staging, to: rollbackArchive)
                    } catch {
                        try? atomicExchange(staging, active)
                        throw TatwoSkilletBundleError.atomicSwapFailed(active.path)
                    }
                } else {
                    try atomicRename(staging, active)
                }
            } catch {
                if fileManager.fileExists(atPath: staging.path) {
                    try? fileManager.removeItem(at: staging)
                }
                throw error
            }

            let head = TatwoDeviceHeadV1(
                deviceID: deviceID,
                repositoryID: repositoryID,
                revisionID: revisionID,
                contentDigest: revision.contentDigest,
                requestID: requestID,
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                activationState: .active,
                lastVerifiedAt: verifiedAt
            )

            do {
                try beforeDeviceHeadCommit?()
                try store.upsertDeviceHead(head)
                return head
            } catch {
                do {
                    let failed = try prepareFailedDestination(
                        runtimeRoot: runtimeRoot,
                        repositoryID: repositoryID
                    )
                    if hadActive {
                        try atomicExchange(active, rollbackArchive)
                        try atomicRename(rollbackArchive, failed)
                    } else {
                        try atomicRename(active, failed)
                    }
                } catch {
                    throw TatwoSkilletBundleError.rollbackFailed(active.path)
                }
                throw error
            }
        }
    }
}

private extension TatwoSkilletBundleTransport {
    struct VerifiedSetManifest {
        let input: TatwoSkilletBoundBundleInputV1
        let manifest: TatwoSkilletBundleManifestV1
    }

    static func verifiedSetManifests(
        _ inputs: [TatwoSkilletBoundBundleInputV1],
        store: TatwoSkilletRepositoryStore,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String
    ) throws -> [VerifiedSetManifest] {
        guard !inputs.isEmpty else {
            throw TatwoSkilletBundleError.invalidBundle(
                "Skillet set must not be empty"
            )
        }
        guard isValidIdentifier(deviceID),
              isValidIdentifier(requestID),
              isValidIdentifier(sourceDeviceID),
              isValidIdentifier(catalogRevision),
              ledgerSequence > 0
        else {
            throw TatwoSkilletBundleError.authorityBindingMismatch(
                "set identity or ledger"
            )
        }
        let sortedInputs = inputs.sorted { $0.repositoryID < $1.repositoryID }
        guard Set(sortedInputs.map(\.repositoryID)).count == sortedInputs.count,
              inputs.map(\.repositoryID) == sortedInputs.map(\.repositoryID)
        else {
            throw TatwoSkilletBundleError.invalidBundle(
                "Skillet set repositories must be unique and sorted"
            )
        }
        return try sortedInputs.map { input in
            try validateSetInput(
                input,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: deviceID,
                authorityEpoch: authorityEpoch,
                ledgerSequence: ledgerSequence,
                catalogRevision: catalogRevision
            )
            let manifest = try verifyAuthorityBoundBundle(
                at: input.bundleURL,
                binding: input.binding,
                expectedRequestID: requestID,
                expectedSourceDeviceID: sourceDeviceID,
                expectedTargetDeviceID: deviceID,
                expectedAuthorityEpoch: authorityEpoch,
                expectedLedgerSequence: ledgerSequence,
                expectedCatalogRevision: catalogRevision
            )
            try validateSetManifest(manifest, input: input)
            return VerifiedSetManifest(input: input, manifest: manifest)
        }
    }

    static func receiveAuthorityBoundSetWithPendingMerges(
        _ manifests: [VerifiedSetManifest],
        into store: TatwoSkilletRepositoryStore,
        runtimeRoot: URL,
        deviceID: String,
        requestID: String,
        sourceDeviceID: String,
        createdAt: Date
    ) throws -> TatwoSkilletPendingMergeSetV1 {
        let fileManager = FileManager.default
        let storeRoot = store.rootURL.standardizedFileURL
        let runtimeRoot = runtimeRoot.standardizedFileURL
        try requireNoSymbolicLinkComponents(storeRoot, errorPath: storeRoot.path)
        let runtimeWasPresent = fileManager.fileExists(
            atPath: runtimeRoot.path
        )
        if runtimeWasPresent {
            try requireNoSymbolicLinkComponents(
                runtimeRoot,
                errorPath: runtimeRoot.path
            )
            try requireDirectory(runtimeRoot, errorPath: runtimeRoot.path)
        }
        let storeParent = storeRoot.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: storeParent,
            withIntermediateDirectories: true
        )
        let staging = storeParent.appendingPathComponent(
            ".\(storeRoot.lastPathComponent).pending-merge-\(requestID)-\(UUID().uuidString)",
            isDirectory: true
        )
        let runtimeSetLock = runtimeRoot.appendingPathComponent(
            ".set-activation",
            isDirectory: false
        )

        let transaction: () throws -> TatwoSkilletPendingMergeSetV1 = {
            try store.withExclusiveMutationLock {
                let hadStore = fileManager.fileExists(atPath: storeRoot.path)
                if hadStore {
                    try requireDirectory(storeRoot, errorPath: storeRoot.path)
                    try fileManager.copyItem(at: storeRoot, to: staging)
                } else {
                    try fileManager.createDirectory(
                        at: staging,
                        withIntermediateDirectories: true
                    )
                }

                let stagedStore = TatwoSkilletRepositoryStore(rootURL: staging)
                var mergeStage = "capture-original-pointers"
                do {
                var originalPointers: [
                    String: (
                        displayName: String?,
                        summary: String?,
                        canonical: String?,
                        stable: String?,
                        canary: String?,
                        rollback: String?
                    )
                ] = [:]
                for element in manifests {
                    if let existing = try loadRepositoryIfPresent(
                        id: element.manifest.repositoryID,
                        from: stagedStore
                    ) {
                        originalPointers[element.manifest.repositoryID] = (
                            existing.displayName,
                            existing.summary,
                            existing.canonicalRevision,
                            existing.stableRevision,
                            existing.canaryRevision,
                            existing.rollbackRevision
                        )
                    } else {
                        originalPointers[element.manifest.repositoryID] = (
                            nil, nil, nil, nil, nil, nil
                        )
                    }
                }

                var proposals: [TatwoMergeProposalV1] = []
                var branchPreservedRevisions: [
                    TatwoSkilletBranchPreservedRevisionV1
                ] = []
                for element in manifests {
                    mergeStage = "classify-\(element.manifest.repositoryID)"
                    let existing = try loadRepositoryIfPresent(
                        id: element.manifest.repositoryID,
                        from: stagedStore
                    )
                    var divergent = false
                    if existing != nil {
                        do {
                            try validateImportCompatibility(
                                existing,
                                manifest: element.manifest
                            )
                        } catch let error as TatwoSkilletBundleError {
                            guard case .repositoryConflict = error else {
                                throw error
                            }
                            divergent = true
                        }
                    }

                    if divergent {
                        mergeStage =
                            "receive-divergent-\(element.manifest.repositoryID)"
                        let proposal = try receiveDivergentBundleInPlace(
                            manifest: element.manifest,
                            bundleURL: element.input.bundleURL,
                            into: stagedStore,
                            sourceDeviceID: sourceDeviceID,
                            createdAt: createdAt
                        )
                        proposals.append(proposal)
                    } else {
                        mergeStage =
                            "preserve-branch-\(element.manifest.repositoryID)"
                        try persistIncomingBranch(
                            manifest: element.manifest,
                            bundleURL: element.input.bundleURL,
                            into: stagedStore
                        )
                        branchPreservedRevisions.append(
                            TatwoSkilletBranchPreservedRevisionV1(
                                repositoryID: element.manifest.repositoryID,
                                revisionID: element.manifest.exportedRevisionID,
                                contentDigest: element.input.contentDigest
                            )
                        )
                    }
                }
                guard !proposals.isEmpty else {
                    throw TatwoSkilletBundleError.repositoryConflict(requestID)
                }

                mergeStage = "verify-pointers"
                for element in manifests {
                    let repository = try stagedStore.loadRepository(
                        id: element.manifest.repositoryID
                    )
                    let expected = originalPointers[
                        element.manifest.repositoryID
                    ] ?? (nil, nil, nil, nil, nil, nil)
                    guard (expected.displayName == nil
                            || repository.displayName == expected.displayName),
                          (expected.summary == nil
                            || repository.summary == expected.summary),
                          repository.canonicalRevision == expected.canonical,
                          repository.stableRevision == expected.stable,
                          repository.canaryRevision == expected.canary,
                          repository.rollbackRevision == expected.rollback
                    else {
                        throw TatwoSkilletBundleError.repositoryConflict(
                            element.manifest.repositoryID
                        )
                    }
                }
                mergeStage = "verify-target-preserved"
                if !runtimeWasPresent,
                   fileManager.fileExists(atPath: runtimeRoot.path)
                {
                    throw TatwoSkilletBundleError.repositoryConflict(
                        runtimeRoot.path
                    )
                }
                let targetPreserved = try targetPreservedRepositories(
                    in: stagedStore,
                    runtimeRoot: runtimeRoot,
                    excluding: Set(manifests.map {
                        $0.manifest.repositoryID
                    }),
                    deviceID: deviceID
                )

                mergeStage = "remove-pending-store-lock"
                // The aggregate pending store is now immutable. Keep the stable
                // store lock while removing only this UUID-bound sibling lock.
                try removeEphemeralStoreMutationLock(for: stagedStore)
                mergeStage = "commit-pending-store"
                if hadStore {
                    try atomicExchange(staging, storeRoot)
                    archivePreviousStore(
                        at: staging,
                        storeRoot: storeRoot,
                        fileManager: fileManager
                    )
                } else {
                    try atomicRename(staging, storeRoot)
                }
                return TatwoSkilletPendingMergeSetV1(
                    proposals: proposals.sorted {
                        $0.repositoryID < $1.repositoryID
                    },
                    branchPreservedRevisions:
                        branchPreservedRevisions.sorted {
                            $0.repositoryID < $1.repositoryID
                        },
                    targetPreservedRepositories: targetPreserved
                )
                } catch {
                    debugMergeFailure(
                        "aggregate-pending",
                        stage: mergeStage,
                        error: error
                    )
                    try? removeEphemeralStoreMutationLock(for: stagedStore)
                    if fileManager.fileExists(atPath: staging.path) {
                        try? fileManager.removeItem(at: staging)
                    }
                    throw error
                }
            }
        }
        if runtimeWasPresent {
            return try TatwoFileLock.withExclusiveLock(for: runtimeSetLock) {
                try transaction()
            }
        }
        return try transaction()
    }

    static func receiveDivergentBundle(
        manifest: TatwoSkilletBundleManifestV1,
        bundleURL: URL,
        into store: TatwoSkilletRepositoryStore,
        sourceDeviceID: String,
        createdAt: Date,
        testHooks: ReceiveBundleTestHooks? = nil
    ) throws -> TatwoSkilletBundleImportOutcomeV1 {
        let fileManager = FileManager.default
        let storeRoot = store.rootURL.standardizedFileURL
        try requireNoSymbolicLinkComponents(
            storeRoot,
            errorPath: storeRoot.path
        )
        let parent = storeRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(storeRoot.lastPathComponent).merge-staging-\(UUID().uuidString)",
            isDirectory: true
        )

        return try store.withExclusiveMutationLock {
            let current = try loadRepositoryIfPresent(
                id: manifest.repositoryID,
                from: store
            )
            guard current != nil else {
                throw TatwoSkilletBundleError.repositoryConflict(
                    manifest.repositoryID
                )
            }
            do {
                try requireDirectory(storeRoot, errorPath: storeRoot.path)
            } catch {
                throw TatwoSkilletBundleError.invalidBundle(
                    "Skillet store root is not a safe directory"
                )
            }
            try fileManager.copyItem(at: storeRoot, to: staging)

            let stagedStore = TatwoSkilletRepositoryStore(rootURL: staging)
            var mergeStage = "load-existing"
            do {
                let stagedExisting = try stagedStore.loadRepository(
                    id: manifest.repositoryID
                )
                do {
                    mergeStage = "compatibility-check"
                    try validateImportCompatibility(
                        stagedExisting,
                        manifest: manifest
                    )
                    let imported = try importVerifiedBundleInPlace(
                        manifest: manifest,
                        bundleURL: bundleURL,
                        into: stagedStore
                    )
                    mergeStage = "remove-fast-forward-store-lock"
                    // All fast-forward staged-store APIs are complete. The
                    // outer stable-store lock remains held across the swap.
                    try removeEphemeralStoreMutationLock(for: stagedStore)
                    try atomicExchange(staging, storeRoot)
                    archivePreviousStore(
                        at: staging,
                        storeRoot: storeRoot,
                        fileManager: fileManager
                    )
                    return .imported(imported)
                } catch let error as TatwoSkilletBundleError {
                    guard case .repositoryConflict = error else { throw error }
                }

                mergeStage = "persist-incoming-branch"
                try persistIncomingBranch(
                    manifest: manifest,
                    bundleURL: bundleURL,
                    into: stagedStore
                )
                let repository = try stagedStore.loadRepository(
                    id: manifest.repositoryID
                )
                guard let canonicalRevisionID = stagedExisting.canonicalRevision else {
                    throw TatwoSkilletBundleError.repositoryConflict(
                        manifest.repositoryID
                    )
                }
                let proposedRevisionID = manifest.exportedRevisionID
                mergeStage = "find-common-ancestor"
                let baseRevisionID = try nearestCommonAncestor(
                    canonicalRevisionID: canonicalRevisionID,
                    proposedRevisionID: proposedRevisionID,
                    revisions: repository.revisions
                )
                let baseFiles = try baseRevisionID.map {
                    try stagedStore.loadSnapshotFiles(
                        repositoryID: manifest.repositoryID,
                        revisionID: $0
                    )
                }
                let canonicalFiles = try stagedStore.loadSnapshotFiles(
                    repositoryID: manifest.repositoryID,
                    revisionID: canonicalRevisionID
                )
                let proposedFiles = try stagedStore.loadSnapshotFiles(
                    repositoryID: manifest.repositoryID,
                    revisionID: proposedRevisionID
                )
                mergeStage = "merge-files"
                let merge = TatwoSkilletMergeEngine.merge(
                    repositoryID: manifest.repositoryID,
                    sourceDeviceID: sourceDeviceID,
                    baseRevisionID: baseRevisionID,
                    canonicalRevisionID: canonicalRevisionID,
                    proposedRevisionID: proposedRevisionID,
                    baseFiles: baseFiles,
                    canonicalFiles: canonicalFiles,
                    proposedFiles: proposedFiles
                )

                let mergedRevisionID: String?
                if merge.isClean {
                    let candidate = staging.appendingPathComponent(
                        ".merge-candidate-\(UUID().uuidString)",
                        isDirectory: true
                    )
                    do {
                        mergeStage = "materialize-merged-revision"
                        try materializeMergedFiles(
                            merge.mergedFiles,
                            at: candidate
                        )
                        let revision = try stagedStore
                            .snapshotDetachedSkillDirectory(
                                repositoryID: manifest.repositoryID,
                                displayName: manifest.displayName,
                                summary: manifest.summary,
                                sourceDirectory: candidate,
                                channel: .staging,
                                parentRevisionID: canonicalRevisionID,
                                createdAt: createdAt
                            )
                        mergedRevisionID = revision.id
                    } catch {
                        try? fileManager.removeItem(at: candidate)
                        throw error
                    }
                    try? fileManager.removeItem(at: candidate)
                } else {
                    mergedRevisionID = nil
                }

                let conflictIDs = merge.conflicts.map(\.id).sorted()
                let proposal = TatwoMergeProposalV1(
                    id: mergeProposalID(
                        repositoryID: manifest.repositoryID,
                        sourceDeviceID: sourceDeviceID,
                        baseRevisionID: baseRevisionID,
                        canonicalRevisionID: canonicalRevisionID,
                        proposedRevisionID: proposedRevisionID,
                        mergedRevisionID: mergedRevisionID,
                        conflictArtifactIDs: conflictIDs
                    ),
                    repositoryID: manifest.repositoryID,
                    sourceDeviceID: sourceDeviceID,
                    baseRevisionID: baseRevisionID,
                    canonicalRevisionID: canonicalRevisionID,
                    proposedRevisionID: proposedRevisionID,
                    mergedRevisionID: mergedRevisionID,
                    conflictArtifactIDs: conflictIDs,
                    createdAt: createdAt
                )
                mergeStage = "persist-merge-proposal"
                _ = try stagedStore.persistMergeProposal(
                    proposal,
                    conflicts: merge.conflicts
                )
                mergeStage = "verify-canonical-unchanged"
                guard try stagedStore.loadRepository(
                    id: manifest.repositoryID
                ).canonicalRevision == canonicalRevisionID else {
                    throw TatwoSkilletBundleError.repositoryConflict(
                        manifest.repositoryID
                    )
                }
                try testHooks?.beforeDivergentStoreCommit?()

                mergeStage = "remove-divergent-store-lock"
                // The proposal and branch are fully persisted; do not reopen
                // this staged store after removing its UUID-bound sibling lock.
                try removeEphemeralStoreMutationLock(for: stagedStore)
                mergeStage = "commit-divergent-store"
                try atomicExchange(staging, storeRoot)
                archivePreviousStore(
                    at: staging,
                    storeRoot: storeRoot,
                    fileManager: fileManager
                )
                return .mergeProposed(proposal)
            } catch {
                debugMergeFailure(
                    manifest.repositoryID,
                    stage: mergeStage,
                    error: error
                )
                try? removeEphemeralStoreMutationLock(for: stagedStore)
                if fileManager.fileExists(atPath: staging.path) {
                    try? fileManager.removeItem(at: staging)
                }
                throw error
            }
        }
    }

    /// Persists one divergent repository inside a caller-owned staged store.
    ///
    /// The aggregate set transaction already owns the only whole-store copy and
    /// atomic swap. Calling the public single-bundle receive path here would
    /// recursively copy and archive the staged store once per divergent
    /// repository.
    static func receiveDivergentBundleInPlace(
        manifest: TatwoSkilletBundleManifestV1,
        bundleURL: URL,
        into stagedStore: TatwoSkilletRepositoryStore,
        sourceDeviceID: String,
        createdAt: Date
    ) throws -> TatwoMergeProposalV1 {
        let stagedExisting = try stagedStore.loadRepository(
            id: manifest.repositoryID
        )
        try persistIncomingBranch(
            manifest: manifest,
            bundleURL: bundleURL,
            into: stagedStore
        )
        let repository = try stagedStore.loadRepository(
            id: manifest.repositoryID
        )
        guard let canonicalRevisionID = stagedExisting.canonicalRevision else {
            throw TatwoSkilletBundleError.repositoryConflict(
                manifest.repositoryID
            )
        }
        let proposedRevisionID = manifest.exportedRevisionID
        let baseRevisionID = try nearestCommonAncestor(
            canonicalRevisionID: canonicalRevisionID,
            proposedRevisionID: proposedRevisionID,
            revisions: repository.revisions
        )
        let baseFiles = try baseRevisionID.map {
            try stagedStore.loadSnapshotFiles(
                repositoryID: manifest.repositoryID,
                revisionID: $0
            )
        }
        let canonicalFiles = try stagedStore.loadSnapshotFiles(
            repositoryID: manifest.repositoryID,
            revisionID: canonicalRevisionID
        )
        let proposedFiles = try stagedStore.loadSnapshotFiles(
            repositoryID: manifest.repositoryID,
            revisionID: proposedRevisionID
        )
        let merge = TatwoSkilletMergeEngine.merge(
            repositoryID: manifest.repositoryID,
            sourceDeviceID: sourceDeviceID,
            baseRevisionID: baseRevisionID,
            canonicalRevisionID: canonicalRevisionID,
            proposedRevisionID: proposedRevisionID,
            baseFiles: baseFiles,
            canonicalFiles: canonicalFiles,
            proposedFiles: proposedFiles
        )

        let mergedRevisionID: String?
        if merge.isClean {
            let candidate = stagedStore.rootURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".merge-candidate-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: candidate) }
            try materializeMergedFiles(merge.mergedFiles, at: candidate)
            let revision = try stagedStore.snapshotDetachedSkillDirectory(
                repositoryID: manifest.repositoryID,
                displayName: stagedExisting.displayName,
                summary: stagedExisting.summary,
                sourceDirectory: candidate,
                channel: .staging,
                parentRevisionID: canonicalRevisionID,
                createdAt: createdAt
            )
            mergedRevisionID = revision.id
        } else {
            mergedRevisionID = nil
        }

        let conflictIDs = merge.conflicts.map(\.id).sorted()
        let proposal = TatwoMergeProposalV1(
            id: mergeProposalID(
                repositoryID: manifest.repositoryID,
                sourceDeviceID: sourceDeviceID,
                baseRevisionID: baseRevisionID,
                canonicalRevisionID: canonicalRevisionID,
                proposedRevisionID: proposedRevisionID,
                mergedRevisionID: mergedRevisionID,
                conflictArtifactIDs: conflictIDs
            ),
            repositoryID: manifest.repositoryID,
            sourceDeviceID: sourceDeviceID,
            baseRevisionID: baseRevisionID,
            canonicalRevisionID: canonicalRevisionID,
            proposedRevisionID: proposedRevisionID,
            mergedRevisionID: mergedRevisionID,
            conflictArtifactIDs: conflictIDs,
            createdAt: createdAt
        )
        _ = try stagedStore.persistMergeProposal(
            proposal,
            conflicts: merge.conflicts
        )
        let finalRepository = try stagedStore.loadRepository(
            id: manifest.repositoryID
        )
        guard finalRepository.displayName == stagedExisting.displayName,
              finalRepository.summary == stagedExisting.summary,
              finalRepository.canonicalRevision == canonicalRevisionID,
              finalRepository.stableRevision == stagedExisting.stableRevision,
              finalRepository.canaryRevision == stagedExisting.canaryRevision,
              finalRepository.rollbackRevision == stagedExisting.rollbackRevision
        else {
            throw TatwoSkilletBundleError.repositoryConflict(
                manifest.repositoryID
            )
        }
        return proposal
    }

    static func persistIncomingBranch(
        manifest: TatwoSkilletBundleManifestV1,
        bundleURL: URL,
        into store: TatwoSkilletRepositoryStore
    ) throws {
        let existing = try loadRepositoryIfPresent(
            id: manifest.repositoryID,
            from: store
        )
        var known = Dictionary(
            uniqueKeysWithValues: (existing?.revisions ?? []).map {
                ($0.id, $0)
            }
        )
        let objects = bundleURL.appendingPathComponent(
            "objects",
            isDirectory: true
        )
        for revision in manifest.revisions {
            if let existing = known[revision.id] {
                guard existing == revision else {
                    throw TatwoSkilletBundleError.repositoryConflict(
                        manifest.repositoryID
                    )
                }
                continue
            }
            let payload = objects
                .appendingPathComponent(
                    revision.contentDigest,
                    isDirectory: true
                )
                .appendingPathComponent("payload", isDirectory: true)
            let imported = try store.snapshotDetachedSkillDirectory(
                repositoryID: manifest.repositoryID,
                displayName: manifest.displayName,
                summary: manifest.summary,
                sourceDirectory: payload,
                channel: revision.channel,
                parentRevisionID: revision.parentRevisionID,
                createdAt: revision.createdAt
            )
            guard imported == revision else {
                throw TatwoSkilletBundleError.repositoryConflict(
                    manifest.repositoryID
                )
            }
            known[revision.id] = revision
        }
    }

    static func nearestCommonAncestor(
        canonicalRevisionID: String,
        proposedRevisionID: String,
        revisions: [TatwoSkillRevisionV1]
    ) throws -> String? {
        let byID = Dictionary(
            revisions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func ancestry(_ head: String) throws -> [String] {
            var result: [String] = []
            var visited = Set<String>()
            var cursor: String? = head
            while let revisionID = cursor {
                guard visited.insert(revisionID).inserted,
                      let revision = byID[revisionID]
                else {
                    throw TatwoSkilletBundleError.invalidBundle(
                        "revision ancestry is incomplete or cyclic"
                    )
                }
                result.append(revisionID)
                cursor = revision.parentRevisionID
            }
            return result
        }
        let proposedAncestors = Set(try ancestry(proposedRevisionID))
        return try ancestry(canonicalRevisionID).first {
            proposedAncestors.contains($0)
        }
    }

    static func materializeMergedFiles(
        _ files: [String: Data],
        at destination: URL
    ) throws {
        let fileManager = FileManager.default
        guard files["SKILL.md"] != nil else {
            throw TatwoSkilletRepositoryStoreError.missingSkillManifest
        }
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        for path in files.keys.sorted() {
            guard isSafeRelativePath(path),
                  !isProhibited(relativePath: path),
                  let data = files[path]
            else {
                throw TatwoSkilletBundleError.invalidBundle(
                    "merged snapshot contains an unsafe path"
                )
            }
            let target = destination.appendingPathComponent(path)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: target, options: [.atomic])
        }
    }

    static func mergeProposalID(
        repositoryID: String,
        sourceDeviceID: String,
        baseRevisionID: String?,
        canonicalRevisionID: String,
        proposedRevisionID: String,
        mergedRevisionID: String?,
        conflictArtifactIDs: [String]
    ) -> String {
        let fields = [
            repositoryID,
            sourceDeviceID,
            baseRevisionID ?? "",
            canonicalRevisionID,
            proposedRevisionID,
            mergedRevisionID ?? "",
        ] + conflictArtifactIDs.sorted()
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return "merge-\(sha256(data))"
    }

    static func exportRevisionClosure(
        repository: TatwoCapabilityRepositoryV1,
        exportedRevisionID: String,
        approvedMergeProposals: [TatwoMergeProposalV1]
    ) throws -> [TatwoSkillRevisionV1] {
        let revisionsByID = Dictionary(
            repository.revisions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard revisionsByID[exportedRevisionID] != nil else {
            throw TatwoSkilletRepositoryStoreError.revisionNotFound(exportedRevisionID)
        }

        var requiredHeadIDs = Set([exportedRevisionID])
        for proposal in approvedMergeProposals {
            guard proposal.repositoryID == repository.id,
                  proposal.status == .approved,
                  proposal.mergedRevisionID == exportedRevisionID
            else {
                throw TatwoSkilletBundleError.invalidBundle(
                    "approved merge proposal does not match the exported revision"
                )
            }
            requiredHeadIDs.insert(proposal.canonicalRevisionID)
            requiredHeadIDs.insert(proposal.proposedRevisionID)
            if let baseRevisionID = proposal.baseRevisionID {
                requiredHeadIDs.insert(baseRevisionID)
            }
        }

        var includedIDs = Set<String>()
        for headID in requiredHeadIDs.sorted() {
            var ancestryVisited = Set<String>()
            var cursor: String? = headID
            while let revisionID = cursor {
                guard ancestryVisited.insert(revisionID).inserted else {
                    throw TatwoSkilletBundleError.invalidBundle(
                        "revision ancestry contains a cycle"
                    )
                }
                guard let revision = revisionsByID[revisionID] else {
                    throw TatwoSkilletBundleError.invalidBundle(
                        "revision ancestry is incomplete"
                    )
                }
                includedIDs.insert(revisionID)
                cursor = revision.parentRevisionID
            }
        }

        var indegree = Dictionary(
            uniqueKeysWithValues: includedIDs.map { ($0, 0) }
        )
        var children: [String: [String]] = [:]
        for revisionID in includedIDs {
            guard let revision = revisionsByID[revisionID] else {
                throw TatwoSkilletBundleError.invalidBundle(
                    "revision ancestry is incomplete"
                )
            }
            if let parentRevisionID = revision.parentRevisionID {
                guard includedIDs.contains(parentRevisionID) else {
                    throw TatwoSkilletBundleError.invalidBundle(
                        "revision ancestry is incomplete"
                    )
                }
                indegree[revisionID] = 1
                children[parentRevisionID, default: []].append(revisionID)
            }
        }

        var ready = indegree.compactMap { key, value in
            value == 0 ? key : nil
        }.sorted()
        var ordered: [TatwoSkillRevisionV1] = []
        ordered.reserveCapacity(includedIDs.count)

        while !ready.isEmpty {
            let selectedIndex: Int
            if let nonExportedIndex = ready.firstIndex(where: {
                $0 != exportedRevisionID
            }) {
                selectedIndex = nonExportedIndex
            } else {
                guard ordered.count == includedIDs.count - 1,
                      ready == [exportedRevisionID]
                else {
                    throw TatwoSkilletBundleError.invalidBundle(
                        "exported revision is not a terminal merge head"
                    )
                }
                selectedIndex = 0
            }

            let revisionID = ready.remove(at: selectedIndex)
            guard let revision = revisionsByID[revisionID] else {
                throw TatwoSkilletBundleError.invalidBundle(
                    "revision ancestry is incomplete"
                )
            }
            ordered.append(revision)
            for childID in children[revisionID, default: []].sorted() {
                guard let childIndegree = indegree[childID],
                      childIndegree > 0
                else {
                    throw TatwoSkilletBundleError.invalidBundle(
                        "revision ancestry contains a cycle"
                    )
                }
                indegree[childID] = childIndegree - 1
                if childIndegree == 1 {
                    ready.append(childID)
                    ready.sort()
                }
            }
        }

        guard ordered.count == includedIDs.count,
              ordered.last?.id == exportedRevisionID
        else {
            throw TatwoSkilletBundleError.invalidBundle(
                "revision ancestry contains a cycle"
            )
        }
        return ordered
    }

    static func includedPointer(_ pointer: String?, in revisionIDs: Set<String>) -> String? {
        guard let pointer, revisionIDs.contains(pointer) else { return nil }
        return pointer
    }

    static func validateManifest(_ manifest: TatwoSkilletBundleManifestV1) throws {
        guard manifest.schemaVersion == 1,
              isValidIdentifier(manifest.repositoryID),
              isRevisionID(manifest.exportedRevisionID),
              manifest.canonicalRevision == manifest.exportedRevisionID,
              !manifest.revisions.isEmpty,
              manifest.revisions.last?.id == manifest.exportedRevisionID,
              Set(manifest.revisions.map(\.id)).count == manifest.revisions.count,
              Set(manifest.objectDigests).count == manifest.objectDigests.count,
              manifest.objectDigests == manifest.revisions.map(\.contentDigest)
        else {
            throw TatwoSkilletBundleError.invalidManifest("repository or revision fields are inconsistent")
        }

        let includedIDs = Set(manifest.revisions.map(\.id))
        var seenIDs = Set<String>()
        for revision in manifest.revisions {
            guard revision.repositoryID == manifest.repositoryID,
                  revision.id == "rev-\(revision.contentDigest)",
                  isSHA256(revision.contentDigest)
            else {
                throw TatwoSkilletBundleError.invalidManifest(
                    "revision ancestor closure is inconsistent"
                )
            }
            if let parentRevisionID = revision.parentRevisionID {
                guard includedIDs.contains(parentRevisionID),
                      seenIDs.contains(parentRevisionID)
                else {
                    throw TatwoSkilletBundleError.invalidManifest(
                        "revision ancestor closure is not topologically ordered"
                    )
                }
            }
            seenIDs.insert(revision.id)
        }

        let pointers = [
            manifest.stableRevision,
            manifest.canaryRevision,
            manifest.rollbackRevision,
        ].compactMap { $0 }
        guard pointers.allSatisfy(includedIDs.contains),
              manifest.stableRevision == nil
                  || manifest.stableRevision != manifest.canaryRevision,
              manifest.stableRevision == nil
                  || manifest.stableRevision != manifest.rollbackRevision
        else {
            throw TatwoSkilletBundleError.invalidManifest(
                "repository pointers escape the exported closure"
            )
        }
    }

    static func verifyObject(at object: URL, expectedDigest: String) throws {
        do {
            try requireDirectory(object, errorPath: object.path)
        } catch {
            if !FileManager.default.fileExists(atPath: object.path) {
                throw TatwoSkilletBundleError.missingObject(expectedDigest)
            }
            throw TatwoSkilletBundleError.corruptedObject(expectedDigest)
        }
        do {
            try requireExactChildren(
                at: object,
                expected: ["manifest.json", "payload"],
                objectDigest: expectedDigest
            )
            let manifestURL = object.appendingPathComponent("manifest.json")
            try requireRegularFile(manifestURL, errorPath: manifestURL.path)
            let manifest = try makeDecoder().decode(
                TatwoSkillSnapshotManifestV1.self,
                from: Data(contentsOf: manifestURL)
            )
            guard try verifyPayload(
                at: object.appendingPathComponent("payload", isDirectory: true),
                manifest: manifest,
                expectedDigest: expectedDigest
            ) else {
                throw TatwoSkilletBundleError.corruptedObject(expectedDigest)
            }
        } catch let error as TatwoSkilletBundleError {
            throw error
        } catch {
            throw TatwoSkilletBundleError.corruptedObject(expectedDigest)
        }
    }

    static func verifyPayload(
        at payload: URL,
        manifest: TatwoSkillSnapshotManifestV1,
        expectedDigest: String
    ) throws -> Bool {
        guard manifest.schemaVersion == 1,
              manifest.contentDigest == expectedDigest,
              isSHA256(expectedDigest),
              !manifest.files.isEmpty,
              manifest.files.map(\.relativePath).contains("SKILL.md"),
              manifest.files.map(\.relativePath).allSatisfy({
                  $0 == $0.precomposedStringWithCanonicalMapping
              }),
              Set(manifest.files.map(\.relativePath)).count == manifest.files.count,
              manifest.files == manifest.files.sorted(by: {
                  portablePathPrecedes($0.relativePath, $1.relativePath)
              })
        else {
            return false
        }
        try requireDirectory(payload, errorPath: payload.path)

        var files: [(relativePath: String, data: Data)] = []
        for entry in manifest.files {
            guard isSafeRelativePath(entry.relativePath),
                  !isProhibited(relativePath: entry.relativePath),
                  isSHA256(entry.contentDigest),
                  entry.byteCount >= 0
            else {
                return false
            }
            let fileURL = payload.appendingPathComponent(entry.relativePath)
            let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true
            else {
                return false
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count == entry.byteCount,
                  sha256(data) == entry.contentDigest,
                  !TatwoSkilletSnapshotSecurityPolicy.containsProhibitedContent(data)
            else {
                return false
            }
            files.append((entry.relativePath, data))
        }

        let actualPaths = try enumerateRegularFiles(in: payload)
        guard actualPaths == Set(manifest.files.map(\.relativePath)) else {
            return false
        }
        return snapshotDigest(files) == expectedDigest
    }

    static func loadRepositoryIfPresent(
        id: String,
        from store: TatwoSkilletRepositoryStore
    ) throws -> TatwoCapabilityRepositoryV1? {
        let metadataURL = store.rootURL.standardizedFileURL
            .appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("repository.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        do {
            return try store.loadRepository(id: id)
        } catch let error as TatwoSkilletRepositoryStoreError {
            if case .repositoryNotFound(let missingID) = error, missingID == id {
                return nil
            }
            throw error
        }
    }

    static func validateImportCompatibility(
        _ existing: TatwoCapabilityRepositoryV1?,
        manifest: TatwoSkilletBundleManifestV1
    ) throws {
        guard let existing else { return }
        let importedByID = Dictionary(
            manifest.revisions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByID = Dictionary(
            existing.revisions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard manifest.revisions.allSatisfy({ incomingRevision in
            existingByID[incomingRevision.id].map {
                $0 == incomingRevision
            } ?? true
        }) else {
            throw TatwoSkilletBundleError.repositoryConflict(manifest.repositoryID)
        }
        let protectedExistingPointers = [
            existing.canonicalRevision,
            existing.stableRevision,
            existing.canaryRevision,
            existing.rollbackRevision,
        ].compactMap { $0 }
        guard protectedExistingPointers.allSatisfy({
            importedByID[$0] != nil
        }) else {
            throw TatwoSkilletBundleError.repositoryConflict(manifest.repositoryID)
        }
        if manifest.stableRevision == nil, existing.stableRevision != nil {
            throw TatwoSkilletBundleError.repositoryConflict(manifest.repositoryID)
        }
        if manifest.canaryRevision == nil, existing.canaryRevision != nil {
            throw TatwoSkilletBundleError.repositoryConflict(manifest.repositoryID)
        }
        if manifest.rollbackRevision == nil, existing.rollbackRevision != nil {
            throw TatwoSkilletBundleError.repositoryConflict(manifest.repositoryID)
        }
        if manifest.rollbackRevision == nil,
           let existingStable = existing.stableRevision,
           existingStable != manifest.stableRevision
        {
            throw TatwoSkilletBundleError.repositoryConflict(manifest.repositoryID)
        }
    }

    static func prepareRuntimeRoot(_ runtimeRoot: URL) throws {
        let fileManager = FileManager.default
        try requireNoSymbolicLinkComponents(
            runtimeRoot,
            errorPath: runtimeRoot.path
        )
        if fileManager.fileExists(atPath: runtimeRoot.path) {
            do {
                try requireDirectory(runtimeRoot, errorPath: runtimeRoot.path)
            } catch {
                throw TatwoSkilletBundleError.unsafeRuntimePath(runtimeRoot.path)
            }
        } else {
            try fileManager.createDirectory(
                at: runtimeRoot,
                withIntermediateDirectories: true
            )
        }
        for name in [".staging", ".rollback", ".failed", ".failed-archive"] {
            let directory = runtimeRoot.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: directory.path) {
                do {
                    try requireDirectory(directory, errorPath: directory.path)
                } catch {
                    throw TatwoSkilletBundleError.unsafeRuntimePath(directory.path)
                }
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
        }
    }

    static func requireNoSymbolicLinkComponents(
        _ url: URL,
        errorPath: String
    ) throws {
        let standardized = url.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard FileManager.default.fileExists(atPath: current.path) else {
                continue
            }
            let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true
                || isTrustedSystemPathAlias(current)
            else {
                throw TatwoSkilletBundleError.unsafeRuntimePath(errorPath)
            }
        }
    }

    static func isTrustedSystemPathAlias(_ url: URL) -> Bool {
        let expectedDestinations = [
            "/var": "/private/var",
            "/tmp": "/private/tmp",
            "/etc": "/private/etc",
        ]
        guard let expected = expectedDestinations[url.path],
              let destination = try? FileManager.default.destinationOfSymbolicLink(
                  atPath: url.path
              )
        else {
            return false
        }
        let resolvedDestination: URL
        if destination.hasPrefix("/") {
            resolvedDestination = URL(fileURLWithPath: destination)
        } else {
            resolvedDestination = url.deletingLastPathComponent()
                .appendingPathComponent(destination)
        }
        return resolvedDestination.path == expected
    }

    static func requireExistingRuntimeItemIsDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try requireDirectory(url, errorPath: url.path)
        } catch {
            throw TatwoSkilletBundleError.unsafeRuntimePath(url.path)
        }
    }

    static func prepareFailedDestination(
        runtimeRoot: URL,
        repositoryID: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let failed = runtimeRoot
            .appendingPathComponent(".failed", isDirectory: true)
            .appendingPathComponent(repositoryID, isDirectory: true)
        if fileManager.fileExists(atPath: failed.path) {
            try requireDirectory(failed, errorPath: failed.path)
            let archive = runtimeRoot
                .appendingPathComponent(".failed-archive", isDirectory: true)
                .appendingPathComponent(repositoryID, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(
                at: archive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try atomicRename(failed, archive)
        }
        return failed
    }

    static func atomicExchange(
        _ first: URL,
        _ second: URL,
        testHooks: SetTransactionTestHooks? = nil
    ) throws {
        #if canImport(Darwin)
        if testHooks?.forceCompensatingExchange != true {
            let result = renameatx_np(
                AT_FDCWD,
                first.path,
                AT_FDCWD,
                second.path,
                UInt32(RENAME_SWAP)
            )
            if result == 0 {
                return
            }
            let swapErrno = errno
            guard swapErrno == EOPNOTSUPP || swapErrno == ENOTSUP else {
                throw TatwoSkilletBundleError.atomicSwapFailed(second.path)
            }
        }
        #endif

        try compensatingDirectoryExchange(
            first,
            second,
            beforeStep: testHooks?.beforeCompensatingExchangeStep,
            beforeRollbackStep: testHooks?.beforeCompensatingRollbackStep
        )
    }

    static func compensatingDirectoryExchange(
        _ first: URL,
        _ second: URL,
        beforeStep: ((Int, URL, URL) throws -> Void)?,
        beforeRollbackStep: ((Int, URL, URL) throws -> Void)?
    ) throws {
        var firstStatus = stat()
        var secondStatus = stat()
        guard lstat(first.path, &firstStatus) == 0,
              lstat(second.path, &secondStatus) == 0,
              firstStatus.st_dev == secondStatus.st_dev
        else {
            throw TatwoSkilletBundleError.atomicSwapFailed(second.path)
        }

        let temporary = first.deletingLastPathComponent()
            .appendingPathComponent(".exchange-\(UUID().uuidString)")

        try beforeStep?(1, first, temporary)
        do {
            try atomicRename(first, temporary)
        } catch {
            throw TatwoSkilletBundleError.atomicSwapFailed(second.path)
        }

        do {
            try beforeStep?(2, second, first)
            try atomicRename(second, first)
        } catch {
            let transactionError = error
            do {
                try beforeRollbackStep?(1, temporary, first)
                try atomicRename(temporary, first)
            } catch {
                throw TatwoSkilletBundleError.rollbackFailed(first.path)
            }
            throw transactionError
        }

        do {
            try beforeStep?(3, temporary, second)
            try atomicRename(temporary, second)
        } catch {
            let transactionError = error
            do {
                try beforeRollbackStep?(1, first, second)
                try atomicRename(first, second)
            } catch {
                throw TatwoSkilletBundleError.rollbackFailed(second.path)
            }
            do {
                try beforeRollbackStep?(2, temporary, first)
                try atomicRename(temporary, first)
            } catch {
                throw TatwoSkilletBundleError.rollbackFailed(first.path)
            }
            throw transactionError
        }
    }

    static func atomicRename(_ source: URL, _ destination: URL) throws {
        let result = rename(source.path, destination.path)
        guard result == 0 else {
            throw TatwoSkilletBundleError.atomicSwapFailed(destination.path)
        }
    }

    static func requireDirectory(_ url: URL, errorPath: String) throws {
        let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw TatwoSkilletBundleError.invalidBundle(errorPath)
        }
    }

    static func requireRegularFile(_ url: URL, errorPath: String) throws {
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw TatwoSkilletBundleError.invalidBundle(errorPath)
        }
    }

    static func requireExactChildren(
        at directory: URL,
        expected: Set<String>,
        objectDigest: String?
    ) throws {
        let actual = Set(try directoryChildren(at: directory).map(\.lastPathComponent))
        guard actual == expected else {
            if let objectDigest {
                throw TatwoSkilletBundleError.corruptedObject(objectDigest)
            }
            throw TatwoSkilletBundleError.invalidBundle("unexpected bundle entries")
        }
    }

    static func directoryChildren(at directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: []
        )
    }

    static func enumerateRegularFiles(in root: URL) throws -> Set<String> {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw TatwoSkilletBundleError.invalidBundle(root.path)
        }
        var paths = Set<String>()
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw TatwoSkilletBundleError.invalidBundle(item.path)
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw TatwoSkilletBundleError.invalidBundle(item.path)
            }
            let relativePath = try relativePath(of: item, under: root)
            guard paths.insert(relativePath).inserted else {
                throw TatwoSkilletBundleError.invalidBundle(
                    "duplicate canonical snapshot path"
                )
            }
        }
        return paths
    }

    static func relativePath(of url: URL, under root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else {
            throw TatwoSkilletBundleError.invalidBundle(itemPath)
        }
        let relativePath = String(itemPath.dropFirst(prefix.count))
            .precomposedStringWithCanonicalMapping
        guard isSafeRelativePath(relativePath) else {
            throw TatwoSkilletBundleError.invalidBundle(relativePath)
        }
        return relativePath
    }

    static func isValidIdentifier(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == id,
              trimmed != ".",
              trimmed != "..",
              !trimmed.hasPrefix(".")
        else {
            return false
        }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    static func isRevisionID(_ value: String) -> Bool {
        value.hasPrefix("rev-") && isSHA256(String(value.dropFirst(4)))
    }

    static func isSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                true
            default:
                false
            }
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { component in
            component.isEmpty || component == "." || component == ".."
        }
    }

    static func isProhibited(relativePath: String) -> Bool {
        let components = relativePath
            .split(separator: "/")
            .map { String($0).lowercased() }
        guard let fileName = components.last else { return true }
        if components.contains(".git") { return true }
        if fileName == ".env" || fileName.hasPrefix(".env.") { return true }
        if ["id_rsa", "id_ed25519", "credentials.json"].contains(fileName) {
            return true
        }
        let deniedFragments = [
            "token",
            "secret",
            "credential",
            "cookie",
            "session",
            "keychain",
            "private-key",
            "private_key",
        ]
        if components.contains(where: { component in
            deniedFragments.contains(where: component.contains)
        }) {
            return true
        }
        let ext = (fileName as NSString).pathExtension
        return ["key", "pem", "p12", "pfx"].contains(ext)
    }

    static func snapshotDigest(
        _ files: [(relativePath: String, data: Data)]
    ) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: {
            portablePathPrecedes($0.relativePath, $1.relativePath)
        }) {
            let path = Data(file.relativePath.utf8)
            var pathLength = UInt64(path.count).bigEndian
            var dataLength = UInt64(file.data.count).bigEndian
            withUnsafeBytes(of: &pathLength) { hasher.update(data: Data($0)) }
            hasher.update(data: path)
            withUnsafeBytes(of: &dataLength) { hasher.update(data: Data($0)) }
            hasher.update(data: file.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func portablePathPrecedes(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bundleDigest(
        for manifest: TatwoSkilletBundleManifestV1
    ) throws -> String {
        sha256(try makeEncoder().encode(manifest))
    }

    static func archivePreviousStore(
        at previousStore: URL,
        storeRoot: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: previousStore.path) else { return }
        let archive = storeRoot.deletingLastPathComponent()
            .appendingPathComponent(".skillet-import-archive", isDirectory: true)
            .appendingPathComponent(storeRoot.lastPathComponent, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: archive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: previousStore, to: archive)
        } catch {
            // The new store is already atomically active. Preserve the old store
            // at its staging path for later cleanup review rather than deleting it.
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeEncoder().encode(value).write(to: url, options: [.atomic])
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func debugMergeFailure(
        _ repositoryID: String,
        stage: String,
        error: Error
    ) {
        guard ProcessInfo.processInfo.environment[
            "TATWO_SKILLET_DEBUG_MERGE"
        ] == "1" else {
            return
        }
        let line =
            "tatwo_skillet_merge_debug repository=\(repositoryID) "
            + "stage=\(stage) error=\(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func iso8601Normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }
}
