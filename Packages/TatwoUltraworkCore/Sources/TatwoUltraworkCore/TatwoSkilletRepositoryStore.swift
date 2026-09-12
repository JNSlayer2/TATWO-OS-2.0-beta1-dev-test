import CryptoKit
import Foundation

enum TatwoSkilletSnapshotSecurityPolicy {
    static func containsProhibitedContent(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let privateKeyMarkers = [
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN PGP PRIVATE KEY BLOCK-----",
        ]
        if privateKeyMarkers.contains(where: text.contains) {
            return true
        }

        let credentialPrefixes: [(prefix: String, minimumPayloadLength: Int)] = [
            ("sk-proj-", 20),
            ("sk-ant-", 20),
            ("sk-", 32),
            ("AIza", 30),
            ("ghp_", 20),
            ("github_pat_", 20),
            ("xoxb-", 20),
            ("xoxp-", 20),
            ("AKIA", 16),
        ]
        if credentialPrefixes.contains(where: { candidate in
            containsCredential(
                in: text,
                prefix: candidate.prefix,
                minimumPayloadLength: candidate.minimumPayloadLength
            )
        }) {
            return true
        }
        return text.range(
            of: #"(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*["']?[A-Za-z0-9/+=]{40}"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsCredential(
        in text: String,
        prefix: String,
        minimumPayloadLength: Int
    ) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: prefix, range: searchRange) {
            var cursor = range.upperBound
            var payloadLength = 0
            while cursor < text.endIndex {
                let character = text[cursor]
                guard character.isASCII,
                      character.isLetter || character.isNumber
                        || character == "_" || character == "-"
                else {
                    break
                }
                payloadLength += 1
                cursor = text.index(after: cursor)
            }
            if payloadLength >= minimumPayloadLength {
                return true
            }
            guard range.upperBound < text.endIndex else { break }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }
}

public struct TatwoSkillSnapshotFileV1: Codable, Hashable, Sendable {
    public let relativePath: String
    public let contentDigest: String
    public let byteCount: Int

    public init(relativePath: String, contentDigest: String, byteCount: Int) {
        self.relativePath = relativePath
        self.contentDigest = contentDigest
        self.byteCount = byteCount
    }
}

public struct TatwoSkillSnapshotManifestV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let contentDigest: String
    public let files: [TatwoSkillSnapshotFileV1]

    public init(
        schemaVersion: Int = 1,
        contentDigest: String,
        files: [TatwoSkillSnapshotFileV1]
    ) {
        self.schemaVersion = schemaVersion
        self.contentDigest = contentDigest
        self.files = files
    }
}

public enum TatwoSkilletRepositoryStoreError: Error, Equatable, LocalizedError {
    case invalidIdentifier(String)
    case sourceDirectoryUnavailable(String)
    case missingSkillManifest
    case unsupportedSnapshotEntry(String)
    case prohibitedSnapshotEntry(String)
    case prohibitedSnapshotContent(String)
    case repositoryNotFound(String)
    case revisionNotFound(String)
    case unsupportedPromotionChannel(TatwoSkillChannelV1)
    case rollbackUnavailable(String)
    case corruptedRevision(String)
    case corruptedRepositoryMetadata(String)
    case corruptedDeviceHead(String)
    case staleDeviceHead(String)
    case corruptedReceipt(String)
    case mergeProposalNotFound(String)
    case staleMergeProposal(String)
    case unresolvedMergeConflicts(String)
    case corruptedMergeProposal(String)
    case destinationAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id):
            return "Invalid Skillet identifier: \(id)"
        case .sourceDirectoryUnavailable(let path):
            return "Canonical skill directory is unavailable: \(path)"
        case .missingSkillManifest:
            return "Canonical skill directory must contain SKILL.md"
        case .unsupportedSnapshotEntry(let path):
            return "Skill snapshot contains a symbolic link or unsupported file: \(path)"
        case .prohibitedSnapshotEntry(let path):
            return "Skill snapshot contains a prohibited secret-bearing path: \(path)"
        case .prohibitedSnapshotContent(let path):
            return "Skill snapshot contains prohibited secret-bearing content: \(path)"
        case .repositoryNotFound(let id):
            return "Skillet repository was not found: \(id)"
        case .revisionNotFound(let id):
            return "Skillet revision was not found: \(id)"
        case .unsupportedPromotionChannel(let channel):
            return "Skillet revisions cannot be promoted to \(channel.rawValue)"
        case .rollbackUnavailable(let id):
            return "Skillet repository has no stable rollback target: \(id)"
        case .corruptedRevision(let id):
            return "Skillet revision failed digest verification: \(id)"
        case .corruptedRepositoryMetadata(let id):
            return "Skillet repository metadata is inconsistent or unsafe: \(id)"
        case .corruptedDeviceHead(let id):
            return "Skillet device head is inconsistent or unsafe: \(id)"
        case .staleDeviceHead(let id):
            return "Skillet device head would regress authority or ledger order: \(id)"
        case .corruptedReceipt(let id):
            return "Skillet receipt is inconsistent or unsafe: \(id)"
        case .mergeProposalNotFound(let id):
            return "Skillet merge proposal was not found: \(id)"
        case .staleMergeProposal(let id):
            return "Skillet merge proposal no longer matches the canonical head: \(id)"
        case .unresolvedMergeConflicts(let id):
            return "Skillet merge proposal still has unresolved conflicts: \(id)"
        case .corruptedMergeProposal(let id):
            return "Skillet merge proposal is inconsistent or unsafe: \(id)"
        case .destinationAlreadyExists(let path):
            return "Skillet materialization destination already exists: \(path)"
        }
    }
}

/// Immutable file-backed store for private Skillet capability repositories.
///
/// Layout:
/// - `objects/<content digest>/payload/**` immutable canonical skill snapshots
/// - `objects/<content digest>/manifest.json` per-file digest manifest
/// - `repositories/<id>/repository.json` canonical/stable/canary/rollback heads
/// - `repositories/<id>/revisions/<revision>.json` immutable revisions
/// - `repositories/<id>/device-heads/<device>.json` replaceable device receipts
/// - `repositories/<id>/merge-proposals/<proposal>/` pending human merge gates
/// - `repositories/<id>/rejected-merge-proposals/<proposal>/` terminal reject archives
///
/// Absolute source paths, credentials, Keychain state, sessions and other
/// machine-local details are never persisted in repository metadata.
public struct TatwoSkilletRepositoryStore {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func snapshotCanonicalSkillDirectory(
        repositoryID: String,
        displayName: String,
        summary: String,
        sourceDirectory: URL,
        channel: TatwoSkillChannelV1,
        parentRevisionID: String? = nil,
        createdAt: Date = Date()
    ) throws -> TatwoSkillRevisionV1 {
        try snapshotSkillDirectory(
            repositoryID: repositoryID,
            displayName: displayName,
            summary: summary,
            sourceDirectory: sourceDirectory,
            channel: channel,
            parentRevisionID: parentRevisionID,
            createdAt: createdAt,
            advanceCanonical: true,
            inheritCanonicalParent: true,
            updateRepositoryIdentity: true
        )
    }

    /// Persists an immutable branch revision without moving canonical/stable or
    /// any runtime-facing pointer.
    @discardableResult
    public func snapshotDetachedSkillDirectory(
        repositoryID: String,
        displayName: String,
        summary: String,
        sourceDirectory: URL,
        channel: TatwoSkillChannelV1,
        parentRevisionID: String?,
        createdAt: Date = Date()
    ) throws -> TatwoSkillRevisionV1 {
        try snapshotSkillDirectory(
            repositoryID: repositoryID,
            displayName: displayName,
            summary: summary,
            sourceDirectory: sourceDirectory,
            channel: channel,
            parentRevisionID: parentRevisionID,
            createdAt: createdAt,
            advanceCanonical: false,
            inheritCanonicalParent: false,
            updateRepositoryIdentity: false
        )
    }

    private func snapshotSkillDirectory(
        repositoryID: String,
        displayName: String,
        summary: String,
        sourceDirectory: URL,
        channel: TatwoSkillChannelV1,
        parentRevisionID: String?,
        createdAt: Date,
        advanceCanonical: Bool,
        inheritCanonicalParent: Bool,
        updateRepositoryIdentity: Bool
    ) throws -> TatwoSkillRevisionV1 {
        try Self.validateIdentifier(repositoryID)
        let repositoryURL = repositoryDirectory(repositoryID)

        return try withExclusiveMutationLock {
            try TatwoFileLock.withExclusiveLock(
                for: repositoryURL.appendingPathComponent("repository.json")
            ) {
                var metadata = try loadOrCreateMetadata(
                    id: repositoryID,
                    displayName: displayName,
                    summary: summary
                )
                let snapshot = try inspectSnapshot(sourceDirectory)
                let revisionID = "rev-\(snapshot.manifest.contentDigest)"

                if metadata.revisionIDs.contains(revisionID) {
                    let existing = try loadRevision(
                        repositoryID: repositoryID,
                        revisionID: revisionID
                    )
                    guard try verifyRevisionUnlocked(
                        repositoryID: repositoryID,
                        revisionID: revisionID
                    ) else {
                        throw TatwoSkilletRepositoryStoreError.corruptedRevision(revisionID)
                    }
                    if updateRepositoryIdentity {
                        metadata.displayName = displayName
                        metadata.summary = summary
                    }
                    if advanceCanonical {
                        metadata.canonicalRevision = revisionID
                    }
                    try writeMetadata(metadata)
                    try ensureSnapshotReceipt(existing)
                    return existing
                }

                let resolvedParent = parentRevisionID
                    ?? (inheritCanonicalParent ? metadata.canonicalRevision : nil)
                if let resolvedParent, !metadata.revisionIDs.contains(resolvedParent) {
                    throw TatwoSkilletRepositoryStoreError.revisionNotFound(resolvedParent)
                }

                try persistObject(snapshot)
                let revision = TatwoSkillRevisionV1(
                    id: revisionID,
                    repositoryID: repositoryID,
                    parentRevisionID: resolvedParent,
                    contentDigest: snapshot.manifest.contentDigest,
                    channel: channel,
                    createdAt: createdAt
                )
                try writeJSON(
                    revision,
                    to: revisionsDirectory(repositoryID)
                        .appendingPathComponent("\(revisionID).json")
                )
                if updateRepositoryIdentity {
                    metadata.displayName = displayName
                    metadata.summary = summary
                }
                if advanceCanonical {
                    metadata.canonicalRevision = revisionID
                }
                metadata.revisionIDs.append(revisionID)
                try writeMetadata(metadata)
                try ensureSnapshotReceipt(revision)
                return revision
            }
        }
    }

    public func loadRepository(id: String) throws -> TatwoCapabilityRepositoryV1 {
        try Self.validateIdentifier(id)
        let metadataURL = repositoryDirectory(id).appendingPathComponent("repository.json")
        return try TatwoFileLock.withExclusiveLock(for: metadataURL) {
            let metadata = try loadMetadata(id: id)
            let revisions = try metadata.revisionIDs.map { revisionID in
                guard try verifyRevisionUnlocked(
                    repositoryID: id,
                    revisionID: revisionID
                ) else {
                    throw TatwoSkilletRepositoryStoreError.corruptedRevision(revisionID)
                }
                return try loadRevision(repositoryID: id, revisionID: revisionID)
            }
            try validateRevisionGraph(revisions, metadata: metadata)
            let sortedRevisions = revisions.sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
            let heads = try loadDeviceHeads(repositoryID: id, metadata: metadata).sorted {
                if $0.deviceID == $1.deviceID { return $0.revisionID < $1.revisionID }
                return $0.deviceID < $1.deviceID
            }
            return TatwoCapabilityRepositoryV1(
                id: metadata.id,
                displayName: metadata.displayName,
                summary: metadata.summary,
                canonicalRevision: metadata.canonicalRevision,
                stableRevision: metadata.stableRevision,
                canaryRevision: metadata.canaryRevision,
                rollbackRevision: metadata.rollbackRevision,
                revisions: sortedRevisions,
                deviceHeads: heads
            )
        }
    }

    public func listRepositoryIDs() throws -> [String] {
        let directory = rootURL.appendingPathComponent("repositories", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let directoryValues = try? directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues?.isDirectory == true,
              directoryValues?.isSymbolicLink != true
        else {
            throw TatwoSkilletRepositoryStoreError.corruptedRepositoryMetadata(
                "repositories"
            )
        }
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var result: [String] = []
        for candidate in candidates {
            let values = try candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw TatwoSkilletRepositoryStoreError.corruptedRepositoryMetadata(
                    candidate.lastPathComponent
                )
            }
            try Self.validateIdentifier(candidate.lastPathComponent)
            _ = try loadRepository(id: candidate.lastPathComponent)
            result.append(candidate.lastPathComponent)
        }
        return result.sorted()
    }

    public func promoteRevision(
        repositoryID: String,
        revisionID: String,
        to channel: TatwoSkillChannelV1
    ) throws {
        try Self.validateIdentifier(repositoryID)
        try Self.validateIdentifier(revisionID)
        guard [.canary, .stable, .rollback].contains(channel) else {
            throw TatwoSkilletRepositoryStoreError.unsupportedPromotionChannel(channel)
        }
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")

        try withExclusiveMutationLock {
            try TatwoFileLock.withExclusiveLock(for: metadataURL) {
                var metadata = try loadMetadata(id: repositoryID)
                guard metadata.revisionIDs.contains(revisionID) else {
                    throw TatwoSkilletRepositoryStoreError.revisionNotFound(revisionID)
                }
                guard try verifyRevisionUnlocked(
                    repositoryID: repositoryID,
                    revisionID: revisionID
                ) else {
                    throw TatwoSkilletRepositoryStoreError.corruptedRevision(revisionID)
                }

                switch channel {
                case .canary:
                    metadata.canaryRevision = revisionID
                case .stable:
                    if metadata.stableRevision != revisionID {
                        metadata.rollbackRevision = metadata.stableRevision
                    }
                    metadata.stableRevision = revisionID
                    if metadata.canaryRevision == revisionID {
                        metadata.canaryRevision = nil
                    }
                case .rollback:
                    metadata.rollbackRevision = revisionID
                case .draft, .staging:
                    throw TatwoSkilletRepositoryStoreError.unsupportedPromotionChannel(channel)
                }
                try writeMetadata(metadata)
                let revision = try loadRevision(
                    repositoryID: repositoryID,
                    revisionID: revisionID
                )
                try writeReceipt(
                    .init(
                        id: "promotion-\(UUID().uuidString)",
                        repositoryID: repositoryID,
                        revisionID: revisionID,
                        kind: .promotion,
                        contentDigest: revision.contentDigest,
                        recordedAt: Date(),
                        message: "Promoted revision to \(channel.rawValue)"
                    )
                )
            }
        }
    }

    public func rollbackStable(repositoryID: String) throws {
        try Self.validateIdentifier(repositoryID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")

        try withExclusiveMutationLock {
            try TatwoFileLock.withExclusiveLock(for: metadataURL) {
                var metadata = try loadMetadata(id: repositoryID)
                guard let rollback = metadata.rollbackRevision else {
                    throw TatwoSkilletRepositoryStoreError.rollbackUnavailable(repositoryID)
                }
                guard metadata.revisionIDs.contains(rollback),
                      try verifyRevisionUnlocked(
                          repositoryID: repositoryID,
                          revisionID: rollback
                      )
                else {
                    throw TatwoSkilletRepositoryStoreError.corruptedRevision(rollback)
                }
                let previousStable = metadata.stableRevision
                metadata.stableRevision = rollback
                metadata.rollbackRevision = previousStable
                metadata.canaryRevision = nil
                try writeMetadata(metadata)
                let revision = try loadRevision(
                    repositoryID: repositoryID,
                    revisionID: rollback
                )
                try writeReceipt(
                    .init(
                        id: "rollback-\(UUID().uuidString)",
                        repositoryID: repositoryID,
                        revisionID: rollback,
                        kind: .rollback,
                        contentDigest: revision.contentDigest,
                        recordedAt: Date(),
                        message: "Rolled stable head back to verified revision"
                    )
                )
            }
        }
    }

    public func upsertDeviceHead(_ head: TatwoDeviceHeadV1) throws {
        try Self.validateIdentifier(head.repositoryID)
        try Self.validateIdentifier(head.deviceID)
        try Self.validateIdentifier(head.revisionID)
        let metadataURL = repositoryDirectory(head.repositoryID)
            .appendingPathComponent("repository.json")

        try withExclusiveMutationLock {
            try TatwoFileLock.withExclusiveLock(for: metadataURL) {
                let metadata = try loadMetadata(id: head.repositoryID)
                guard metadata.revisionIDs.contains(head.revisionID) else {
                    throw TatwoSkilletRepositoryStoreError.revisionNotFound(head.revisionID)
                }
                guard try verifyRevisionUnlocked(
                    repositoryID: head.repositoryID,
                    revisionID: head.revisionID
                ) else {
                    throw TatwoSkilletRepositoryStoreError.corruptedRevision(head.revisionID)
                }
                let revision = try loadRevision(
                    repositoryID: head.repositoryID,
                    revisionID: head.revisionID
                )
                guard head.lastVerifiedAt != nil,
                      let ledgerSequence = head.ledgerSequence,
                      ledgerSequence > 0,
                      Self.isSHA256(head.contentDigest),
                      head.contentDigest == revision.contentDigest,
                      Self.isValidIdentifier(head.requestID)
                else {
                    throw TatwoSkilletRepositoryStoreError.corruptedDeviceHead(head.deviceID)
                }
                let destination = deviceHeadsDirectory(head.repositoryID)
                    .appendingPathComponent("\(head.deviceID).json")
                if fileManager.fileExists(atPath: destination.path) {
                    let existing = try readJSON(TatwoDeviceHeadV1.self, from: destination)
                    guard existing.repositoryID == head.repositoryID,
                          existing.deviceID == head.deviceID,
                          let existingSequence = existing.ledgerSequence,
                          existingSequence > 0
                    else {
                        throw TatwoSkilletRepositoryStoreError.corruptedDeviceHead(head.deviceID)
                    }
                    if existing.authorityEpoch > head.authorityEpoch
                        || (existing.authorityEpoch == head.authorityEpoch
                            && existingSequence > ledgerSequence)
                    {
                        throw TatwoSkilletRepositoryStoreError.staleDeviceHead(head.deviceID)
                    }
                    if existing.authorityEpoch == head.authorityEpoch,
                       existingSequence == ledgerSequence
                    {
                        guard existing == head else {
                            throw TatwoSkilletRepositoryStoreError.staleDeviceHead(head.deviceID)
                        }
                        try ensureDeviceHeadReceipt(head, revision: revision)
                        return
                    }
                }
                try writeJSON(
                    head,
                    to: destination
                )
                try ensureDeviceHeadReceipt(head, revision: revision)
            }
        }
    }

    func withExclusiveMutationLock<T>(
        _ body: () throws -> T
    ) throws -> T {
        try TatwoFileLock.withExclusiveLock(for: mutationLockTargetURL, body)
    }

    var mutationLockTargetURL: URL {
        let standardizedRoot = rootURL.standardizedFileURL
        return standardizedRoot.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(standardizedRoot.lastPathComponent).store-mutation"
            )
    }

    var mutationLockFileURL: URL {
        mutationLockTargetURL.appendingPathExtension("lock")
    }

    public func loadSnapshotManifest(
        repositoryID: String,
        revisionID: String
    ) throws -> TatwoSkillSnapshotManifestV1 {
        try Self.validateIdentifier(repositoryID)
        try Self.validateIdentifier(revisionID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")
        return try TatwoFileLock.withExclusiveLock(for: metadataURL) {
            let metadata = try loadMetadata(id: repositoryID)
            guard metadata.revisionIDs.contains(revisionID) else {
                throw TatwoSkilletRepositoryStoreError.revisionNotFound(revisionID)
            }
            guard try verifyRevisionUnlocked(
                repositoryID: repositoryID,
                revisionID: revisionID
            ) else {
                throw TatwoSkilletRepositoryStoreError.corruptedRevision(revisionID)
            }
            let revision = try loadRevision(
                repositoryID: repositoryID,
                revisionID: revisionID
            )
            return try readJSON(
                TatwoSkillSnapshotManifestV1.self,
                from: objectDirectory(revision.contentDigest)
                    .appendingPathComponent("manifest.json")
            )
        }
    }

    public func loadSnapshotFiles(
        repositoryID: String,
        revisionID: String
    ) throws -> [String: Data] {
        try Self.validateIdentifier(repositoryID)
        try Self.validateIdentifier(revisionID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")
        return try TatwoFileLock.withExclusiveLock(for: metadataURL) {
            let metadata = try loadMetadata(id: repositoryID)
            guard metadata.revisionIDs.contains(revisionID),
                  try verifyRevisionUnlocked(
                      repositoryID: repositoryID,
                      revisionID: revisionID
                  )
            else {
                throw TatwoSkilletRepositoryStoreError.revisionNotFound(revisionID)
            }
            let revision = try loadRevision(
                repositoryID: repositoryID,
                revisionID: revisionID
            )
            let manifest = try readJSON(
                TatwoSkillSnapshotManifestV1.self,
                from: objectDirectory(revision.contentDigest)
                    .appendingPathComponent("manifest.json")
            )
            let payload = objectDirectory(revision.contentDigest)
                .appendingPathComponent("payload", isDirectory: true)
            return try Dictionary(
                uniqueKeysWithValues: manifest.files.map { entry in
                    (
                        entry.relativePath,
                        try Data(
                            contentsOf: payload.appendingPathComponent(
                                entry.relativePath
                            )
                        )
                    )
                }
            )
        }
    }

    @discardableResult
    public func persistMergeProposal(
        _ proposal: TatwoMergeProposalV1,
        conflicts: [TatwoSkilletMergeConflictArtifactV1]
    ) throws -> TatwoMergeProposalV1 {
        try Self.validateIdentifier(proposal.repositoryID)
        let metadataURL = repositoryDirectory(proposal.repositoryID)
            .appendingPathComponent("repository.json")
        return try withExclusiveMutationLock {
            try TatwoFileLock.withExclusiveLock(for: metadataURL) {
                let metadata = try loadMetadata(id: proposal.repositoryID)
                try validateMergeProposal(
                    proposal,
                    conflicts: conflicts,
                    metadata: metadata,
                    requireCurrentCanonical: true
                )
                let destination = mergeProposalDirectory(
                    proposal.repositoryID,
                    proposal.id
                )
                if fileManager.fileExists(atPath: destination.path) {
                    let existing = try readJSON(
                        TatwoMergeProposalV1.self,
                        from: destination.appendingPathComponent("proposal.json")
                    )
                    let existingConflicts = try loadMergeConflictsUnlocked(
                        repositoryID: proposal.repositoryID,
                        proposalID: proposal.id
                    )
                    guard mergeProposalContentMatches(existing, proposal),
                          existingConflicts == conflicts.sorted(by: {
                              $0.id < $1.id
                          })
                    else {
                        throw TatwoSkilletRepositoryStoreError
                            .corruptedMergeProposal(proposal.id)
                    }
                    return existing
                }

                let staging = repositoryDirectory(proposal.repositoryID)
                    .appendingPathComponent(
                        ".merge-proposal-staging-\(UUID().uuidString)",
                        isDirectory: true
                    )
                do {
                    try writeJSON(
                        proposal,
                        to: staging.appendingPathComponent("proposal.json")
                    )
                    for conflict in conflicts.sorted(by: { $0.id < $1.id }) {
                        try writeJSON(
                            conflict,
                            to: staging
                                .appendingPathComponent(
                                    "conflicts",
                                    isDirectory: true
                                )
                                .appendingPathComponent("\(conflict.id).json")
                        )
                    }
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: staging, to: destination)
                    return proposal
                } catch {
                    try? fileManager.removeItem(at: staging)
                    throw error
                }
            }
        }
    }

    private func mergeProposalContentMatches(
        _ existing: TatwoMergeProposalV1,
        _ incoming: TatwoMergeProposalV1
    ) -> Bool {
        existing.id == incoming.id
            && existing.repositoryID == incoming.repositoryID
            && existing.sourceDeviceID == incoming.sourceDeviceID
            && existing.baseRevisionID == incoming.baseRevisionID
            && existing.canonicalRevisionID == incoming.canonicalRevisionID
            && existing.proposedRevisionID == incoming.proposedRevisionID
            && existing.mergedRevisionID == incoming.mergedRevisionID
            && existing.conflictArtifactIDs == incoming.conflictArtifactIDs
            && existing.requiresHumanApproval == incoming.requiresHumanApproval
            && existing.status == incoming.status
    }

    public func loadMergeProposals(
        repositoryID: String
    ) throws -> [TatwoMergeProposalV1] {
        try Self.validateIdentifier(repositoryID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")
        return try TatwoFileLock.withExclusiveLock(for: metadataURL) {
            let metadata = try loadMetadata(id: repositoryID)
            let directory = mergeProposalsDirectory(repositoryID)
            guard fileManager.fileExists(atPath: directory.path) else { return [] }
            let candidates = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            return try candidates.map { candidate in
                let values = try candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true,
                      values.isSymbolicLink != true
                else {
                    throw TatwoSkilletRepositoryStoreError
                        .corruptedMergeProposal(candidate.lastPathComponent)
                }
                let proposal = try readJSON(
                    TatwoMergeProposalV1.self,
                    from: candidate.appendingPathComponent("proposal.json")
                )
                guard proposal.id == candidate.lastPathComponent else {
                    throw TatwoSkilletRepositoryStoreError
                        .corruptedMergeProposal(proposal.id)
                }
                let conflicts: [TatwoSkilletMergeConflictArtifactV1]
                do {
                    conflicts = try loadMergeConflictsUnlocked(
                        repositoryID: repositoryID,
                        proposalID: proposal.id
                    )
                    try validateMergeProposal(
                        proposal,
                        conflicts: conflicts,
                        metadata: metadata,
                        requireCurrentCanonical: false
                    )
                } catch {
                    // Pending records may lag store heads. Listing and
                    // rejection must still reach them; approval stays strict.
                    guard proposal.status == .pending else {
                        throw error
                    }
                }
                return proposal
            }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
        }
    }

    public func loadMergeConflicts(
        repositoryID: String,
        proposalID: String
    ) throws -> [TatwoSkilletMergeConflictArtifactV1] {
        try Self.validateIdentifier(repositoryID)
        try Self.validateIdentifier(proposalID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")
        return try TatwoFileLock.withExclusiveLock(for: metadataURL) {
            _ = try loadMetadata(id: repositoryID)
            let proposalURL = mergeProposalDirectory(repositoryID, proposalID)
                .appendingPathComponent("proposal.json")
            guard fileManager.fileExists(atPath: proposalURL.path) else {
                throw TatwoSkilletRepositoryStoreError
                    .mergeProposalNotFound(proposalID)
            }
            return try loadMergeConflictsUnlocked(
                repositoryID: repositoryID,
                proposalID: proposalID
            )
        }
    }

    @discardableResult
    public func approveMergeProposal(
        repositoryID: String,
        proposalID: String,
        resolvedRevisionID: String? = nil,
        decidedBy: String,
        decidedAt: Date = Date()
    ) throws -> TatwoMergeDecisionReceiptV1 {
        try decideMergeProposal(
            repositoryID: repositoryID,
            proposalID: proposalID,
            status: .approved,
            resolvedRevisionID: resolvedRevisionID,
            decidedBy: decidedBy,
            decidedAt: decidedAt
        )
    }

    @discardableResult
    public func rejectMergeProposal(
        repositoryID: String,
        proposalID: String,
        decidedBy: String,
        decidedAt: Date = Date()
    ) throws -> TatwoMergeDecisionReceiptV1 {
        try decideMergeProposal(
            repositoryID: repositoryID,
            proposalID: proposalID,
            status: .rejected,
            resolvedRevisionID: nil,
            decidedBy: decidedBy,
            decidedAt: decidedAt
        )
    }

    /// Moves canonical to an already-persisted revision and keeps the
    /// displaced head as content-addressed history plus an archive receipt.
    @discardableResult
    public func adoptCanonicalRevision(
        repositoryID: String,
        revisionID: String,
        requestID: String,
        sourceDeviceID: String,
        recordedAt: Date = Date()
    ) throws -> TatwoSkilletRepositoryReceiptV1 {
        try Self.validateIdentifier(repositoryID)
        try Self.validateIdentifier(revisionID)
        try Self.validateIdentifier(requestID)
        try Self.validateIdentifier(sourceDeviceID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")

        return try withExclusiveMutationLock {
            try TatwoFileLock.withExclusiveLock(for: metadataURL) {
                var metadata = try loadMetadata(id: repositoryID)
                guard metadata.revisionIDs.contains(revisionID) else {
                    throw TatwoSkilletRepositoryStoreError.revisionNotFound(
                        revisionID
                    )
                }
                guard try verifyRevisionUnlocked(
                    repositoryID: repositoryID,
                    revisionID: revisionID
                ) else {
                    throw TatwoSkilletRepositoryStoreError.corruptedRevision(
                        revisionID
                    )
                }
                let displacedRevisionID = metadata.canonicalRevision
                let archivedRevisionID = displacedRevisionID ?? revisionID
                let archivedRevision = try loadRevision(
                    repositoryID: repositoryID,
                    revisionID: archivedRevisionID
                )
                if displacedRevisionID != revisionID {
                    if let displacedRevisionID {
                        metadata.rollbackRevision = displacedRevisionID
                    }
                    metadata.canonicalRevision = revisionID
                    try writeMetadata(metadata)
                }
                let receipt = TatwoSkilletRepositoryReceiptV1(
                    id: "archive-\(requestID)-\(repositoryID)",
                    repositoryID: repositoryID,
                    revisionID: archivedRevisionID,
                    kind: .archive,
                    contentDigest: archivedRevision.contentDigest,
                    requestID: requestID,
                    recordedAt: recordedAt,
                    message: displacedRevisionID == nil
                        || displacedRevisionID == revisionID
                        ? "Owner-initiated apply kept canonical \(revisionID) from \(sourceDeviceID)"
                        : "Owner-initiated take-primary archived displaced canonical \(displacedRevisionID ?? "none") in favor of \(revisionID) from \(sourceDeviceID)"
                )
                let destination = receiptsDirectory(repositoryID)
                    .appendingPathComponent("\(receipt.id).json")
                if fileManager.fileExists(atPath: destination.path) {
                    let existing = try readJSON(
                        TatwoSkilletRepositoryReceiptV1.self,
                        from: destination
                    )
                    guard existing == receipt else {
                        throw TatwoSkilletRepositoryStoreError.corruptedReceipt(
                            receipt.id
                        )
                    }
                    return existing
                }
                try writeReceipt(receipt)
                return receipt
            }
        }
    }

    public func loadReceipts(
        repositoryID: String
    ) throws -> [TatwoSkilletRepositoryReceiptV1] {
        try Self.validateIdentifier(repositoryID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")
        return try TatwoFileLock.withExclusiveLock(for: metadataURL) {
            let metadata = try loadMetadata(id: repositoryID)
            let directory = receiptsDirectory(repositoryID)
            guard fileManager.fileExists(atPath: directory.path) else { return [] }
            let receipts = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }.map { url in
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw TatwoSkilletRepositoryStoreError.corruptedReceipt(
                        url.lastPathComponent
                    )
                }
                let receipt = try readJSON(TatwoSkilletRepositoryReceiptV1.self, from: url)
                guard url.deletingPathExtension().lastPathComponent == receipt.id else {
                    throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
                }
                try validateReceipt(receipt, repositoryID: repositoryID, metadata: metadata)
                return receipt
            }
            return receipts.sorted {
                if $0.recordedAt == $1.recordedAt { return $0.id < $1.id }
                return $0.recordedAt < $1.recordedAt
            }
        }
    }

    public func verifyRevision(repositoryID: String, revisionID: String) throws -> Bool {
        try Self.validateIdentifier(repositoryID)
        try Self.validateIdentifier(revisionID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")
        return try TatwoFileLock.withExclusiveLock(for: metadataURL) {
            let metadata = try loadMetadata(id: repositoryID)
            guard metadata.revisionIDs.contains(revisionID) else {
                throw TatwoSkilletRepositoryStoreError.revisionNotFound(revisionID)
            }
            return try verifyRevisionUnlocked(
                repositoryID: repositoryID,
                revisionID: revisionID
            )
        }
    }

    public func materializeRevision(
        repositoryID: String,
        revisionID: String,
        to destination: URL
    ) throws {
        try Self.validateIdentifier(repositoryID)
        try Self.validateIdentifier(revisionID)
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")

        try TatwoFileLock.withExclusiveLock(for: metadataURL) {
            let metadata = try loadMetadata(id: repositoryID)
            guard metadata.revisionIDs.contains(revisionID) else {
                throw TatwoSkilletRepositoryStoreError.revisionNotFound(revisionID)
            }
            guard try verifyRevisionUnlocked(
                repositoryID: repositoryID,
                revisionID: revisionID
            ) else {
                throw TatwoSkilletRepositoryStoreError.corruptedRevision(revisionID)
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw TatwoSkilletRepositoryStoreError.destinationAlreadyExists(
                    destination.path
                )
            }
            let revision = try loadRevision(
                repositoryID: repositoryID,
                revisionID: revisionID
            )
            let payload = objectDirectory(revision.contentDigest)
                .appendingPathComponent("payload", isDirectory: true)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: payload, to: destination)
        }
    }

    // MARK: Snapshot inspection and verification

    private func inspectSnapshot(_ sourceDirectory: URL) throws -> SnapshotCandidate {
        let rootValues = try? sourceDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues?.isSymbolicLink != true else {
            throw TatwoSkilletRepositoryStoreError.unsupportedSnapshotEntry(".")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: sourceDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw TatwoSkilletRepositoryStoreError.sourceDirectoryUnavailable(
                sourceDirectory.path
            )
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]
        var enumerationFailure: URL?
        guard let enumerator = fileManager.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                enumerationFailure = url
                return false
            }
        ) else {
            throw TatwoSkilletRepositoryStoreError.sourceDirectoryUnavailable(
                sourceDirectory.path
            )
        }

        var candidates: [(relativePath: String, data: Data)] = []
        while let value = enumerator.nextObject() as? URL {
            let relativePath = try Self.relativePath(of: value, under: sourceDirectory)
            let values = try value.resourceValues(forKeys: Set(keys))

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw TatwoSkilletRepositoryStoreError.unsupportedSnapshotEntry(relativePath)
            }
            // A canonical skill may itself be a Git checkout or worktree. The
            // repository transport owns immutable content snapshots, never the
            // source checkout's private Git control plane. Regular `.git`
            // files/directories are excluded, but a `.git` symlink is rejected
            // above so metadata exclusion cannot hide an escape from the source
            // tree.
            if Self.isExcludedSnapshotMetadata(relativePath: relativePath) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isDirectory == true {
                if Self.isProhibited(relativePath: relativePath) {
                    enumerator.skipDescendants()
                    throw TatwoSkilletRepositoryStoreError.prohibitedSnapshotEntry(relativePath)
                }
                continue
            }
            guard values.isRegularFile == true else {
                throw TatwoSkilletRepositoryStoreError.unsupportedSnapshotEntry(relativePath)
            }
            if Self.isProhibited(relativePath: relativePath) {
                throw TatwoSkilletRepositoryStoreError.prohibitedSnapshotEntry(relativePath)
            }
            let data = try Data(contentsOf: value)
            if TatwoSkilletSnapshotSecurityPolicy.containsProhibitedContent(data) {
                throw TatwoSkilletRepositoryStoreError.prohibitedSnapshotContent(relativePath)
            }
            candidates.append((relativePath, data))
        }
        if let enumerationFailure {
            throw TatwoSkilletRepositoryStoreError.unsupportedSnapshotEntry(
                try Self.relativePath(of: enumerationFailure, under: sourceDirectory)
            )
        }
        guard Set(candidates.map(\.relativePath)).count == candidates.count else {
            throw TatwoSkilletRepositoryStoreError.unsupportedSnapshotEntry(
                "duplicate canonical snapshot path"
            )
        }
        candidates.sort {
            Self.portablePathPrecedes($0.relativePath, $1.relativePath)
        }
        guard candidates.contains(where: { $0.relativePath == "SKILL.md" }) else {
            throw TatwoSkilletRepositoryStoreError.missingSkillManifest
        }

        let digest = Self.snapshotDigest(candidates)
        let files = candidates.map {
            TatwoSkillSnapshotFileV1(
                relativePath: $0.relativePath,
                contentDigest: Self.sha256($0.data),
                byteCount: $0.data.count
            )
        }
        return SnapshotCandidate(
            manifest: TatwoSkillSnapshotManifestV1(
                contentDigest: digest,
                files: files
            ),
            files: candidates
        )
    }

    private func persistObject(_ snapshot: SnapshotCandidate) throws {
        let destination = objectDirectory(snapshot.manifest.contentDigest)
        if fileManager.fileExists(atPath: destination.path) {
            guard try verifyObject(snapshot.manifest.contentDigest) else {
                throw TatwoSkilletRepositoryStoreError.corruptedRevision(
                    "rev-\(snapshot.manifest.contentDigest)"
                )
            }
            return
        }

        try fileManager.createDirectory(
            at: rootURL.appendingPathComponent(".staging", isDirectory: true),
            withIntermediateDirectories: true
        )
        let staging = rootURL
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)

        do {
            for file in snapshot.files {
                let target = payload.appendingPathComponent(file.relativePath)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.data.write(to: target, options: [.atomic])
            }
            try writeJSON(
                snapshot.manifest,
                to: staging.appendingPathComponent("manifest.json")
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            if fileManager.fileExists(atPath: destination.path),
               (try? verifyObject(snapshot.manifest.contentDigest)) == true
            {
                return
            }
            throw error
        }
    }

    private func verifyRevisionUnlocked(
        repositoryID: String,
        revisionID: String
    ) throws -> Bool {
        guard Self.isRevisionID(revisionID) else { return false }
        let revision = try loadRevision(
            repositoryID: repositoryID,
            revisionID: revisionID
        )
        guard revision.repositoryID == repositoryID,
              revision.id == revisionID,
              revision.id == "rev-\(revision.contentDigest)"
        else {
            return false
        }
        return try verifyObject(revision.contentDigest)
    }

    private func verifyObject(_ digest: String) throws -> Bool {
        guard Self.isSHA256(digest) else { return false }
        let object = objectDirectory(digest)
        let objectValues = try? object.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard objectValues?.isDirectory == true,
              objectValues?.isSymbolicLink != true
        else {
            return false
        }
        let manifest = try readJSON(
            TatwoSkillSnapshotManifestV1.self,
            from: object.appendingPathComponent("manifest.json")
        )
        let manifestPaths = manifest.files.map(\.relativePath)
        guard manifest.schemaVersion == 1,
              manifest.contentDigest == digest,
              Self.isSHA256(manifest.contentDigest),
              !manifest.files.isEmpty,
              manifestPaths.contains("SKILL.md"),
              manifestPaths.allSatisfy({
                  $0 == $0.precomposedStringWithCanonicalMapping
              }),
              Set(manifestPaths).count == manifestPaths.count,
              manifest.files == manifest.files.sorted(by: {
                  Self.portablePathPrecedes($0.relativePath, $1.relativePath)
              })
        else {
            return false
        }

        var files: [(relativePath: String, data: Data)] = []
        for entry in manifest.files {
            guard Self.isSafeRelativePath(entry.relativePath),
                  !Self.isProhibited(relativePath: entry.relativePath),
                  Self.isSHA256(entry.contentDigest),
                  entry.byteCount >= 0
            else {
                return false
            }
            let fileURL = object
                .appendingPathComponent("payload", isDirectory: true)
                .appendingPathComponent(entry.relativePath)
            let data = try Data(contentsOf: fileURL)
            guard data.count == entry.byteCount,
                  Self.sha256(data) == entry.contentDigest,
                  !TatwoSkilletSnapshotSecurityPolicy.containsProhibitedContent(data)
            else {
                return false
            }
            files.append((entry.relativePath, data))
        }
        let payload = object.appendingPathComponent("payload", isDirectory: true)
        let payloadValues = try? payload.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard payloadValues?.isDirectory == true,
              payloadValues?.isSymbolicLink != true
        else {
            return false
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: payload,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            return false
        }
        var actualPaths = Set<String>()
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                return false
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                return false
            }
            actualPaths.insert(try Self.relativePath(of: item, under: payload))
        }
        guard actualPaths == Set(manifest.files.map(\.relativePath)) else {
            return false
        }
        return Self.snapshotDigest(files) == digest
    }

    // MARK: Repository metadata

    private func loadOrCreateMetadata(
        id: String,
        displayName: String,
        summary: String
    ) throws -> RepositoryMetadata {
        let url = repositoryDirectory(id).appendingPathComponent("repository.json")
        if fileManager.fileExists(atPath: url.path) {
            return try loadMetadata(id: id)
        }
        let metadata = RepositoryMetadata(
            schemaVersion: 1,
            id: id,
            displayName: displayName,
            summary: summary,
            canonicalRevision: nil,
            stableRevision: nil,
            canaryRevision: nil,
            rollbackRevision: nil,
            revisionIDs: []
        )
        try writeMetadata(metadata)
        return metadata
    }

    private func loadMetadata(id: String) throws -> RepositoryMetadata {
        let url = repositoryDirectory(id).appendingPathComponent("repository.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw TatwoSkilletRepositoryStoreError.repositoryNotFound(id)
        }
        let metadata = try readJSON(RepositoryMetadata.self, from: url)
        let knownRevisionIDs = Set(metadata.revisionIDs)
        let referencedRevisionIDs = [
            metadata.canonicalRevision,
            metadata.stableRevision,
            metadata.canaryRevision,
            metadata.rollbackRevision,
        ].compactMap { $0 }
        guard metadata.schemaVersion == 1,
              metadata.id == id,
              Self.isValidIdentifier(metadata.id),
              knownRevisionIDs.count == metadata.revisionIDs.count,
              metadata.revisionIDs.allSatisfy(Self.isRevisionID),
              referencedRevisionIDs.allSatisfy({ knownRevisionIDs.contains($0) }),
              metadata.stableRevision == nil
                  || metadata.stableRevision != metadata.canaryRevision,
              metadata.stableRevision == nil
                  || metadata.stableRevision != metadata.rollbackRevision
        else {
            throw TatwoSkilletRepositoryStoreError.corruptedRepositoryMetadata(id)
        }
        return metadata
    }

    private func writeMetadata(_ metadata: RepositoryMetadata) throws {
        try writeJSON(
            metadata,
            to: repositoryDirectory(metadata.id).appendingPathComponent("repository.json")
        )
    }

    private func loadRevision(
        repositoryID: String,
        revisionID: String
    ) throws -> TatwoSkillRevisionV1 {
        guard Self.isValidIdentifier(repositoryID), Self.isRevisionID(revisionID) else {
            throw TatwoSkilletRepositoryStoreError.corruptedRevision(revisionID)
        }
        let url = revisionsDirectory(repositoryID)
            .appendingPathComponent("\(revisionID).json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw TatwoSkilletRepositoryStoreError.revisionNotFound(revisionID)
        }
        let revision = try readJSON(TatwoSkillRevisionV1.self, from: url)
        let parentIsValid = revision.parentRevisionID.map(Self.isRevisionID) ?? true
        guard revision.id == revisionID,
              revision.repositoryID == repositoryID,
              revision.id == "rev-\(revision.contentDigest)",
              Self.isSHA256(revision.contentDigest),
              parentIsValid
        else {
            throw TatwoSkilletRepositoryStoreError.corruptedRevision(revisionID)
        }
        return revision
    }

    private func loadDeviceHeads(
        repositoryID: String,
        metadata: RepositoryMetadata
    ) throws -> [TatwoDeviceHeadV1] {
        let directory = deviceHeadsDirectory(repositoryID)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let heads = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.map { url in
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw TatwoSkilletRepositoryStoreError.corruptedDeviceHead(
                    url.lastPathComponent
                )
            }
            let head = try readJSON(TatwoDeviceHeadV1.self, from: url)
            guard url.deletingPathExtension().lastPathComponent == head.deviceID,
                  head.repositoryID == repositoryID,
                  Self.isValidIdentifier(head.deviceID),
                  Self.isRevisionID(head.revisionID),
                  metadata.revisionIDs.contains(head.revisionID),
                  Self.isSHA256(head.contentDigest),
                  Self.isValidIdentifier(head.requestID),
                  head.ledgerSequence.map({ $0 > 0 }) == true,
                  head.lastVerifiedAt != nil
            else {
                throw TatwoSkilletRepositoryStoreError.corruptedDeviceHead(head.deviceID)
            }
            let revision = try loadRevision(
                repositoryID: repositoryID,
                revisionID: head.revisionID
            )
            guard revision.contentDigest == head.contentDigest,
                  try verifyRevisionUnlocked(
                      repositoryID: repositoryID,
                      revisionID: head.revisionID
                  )
            else {
                throw TatwoSkilletRepositoryStoreError.corruptedDeviceHead(head.deviceID)
            }
            return head
        }
        guard Set(heads.map(\.deviceID)).count == heads.count else {
            throw TatwoSkilletRepositoryStoreError.corruptedRepositoryMetadata(repositoryID)
        }
        return heads
    }

    private func loadMergeConflictsUnlocked(
        repositoryID: String,
        proposalID: String
    ) throws -> [TatwoSkilletMergeConflictArtifactV1] {
        let directory = mergeProposalDirectory(repositoryID, proposalID)
            .appendingPathComponent("conflicts", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let values = try? directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values?.isDirectory == true,
              values?.isSymbolicLink != true
        else {
            throw TatwoSkilletRepositoryStoreError
                .corruptedMergeProposal(proposalID)
        }
        let conflicts = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).map { url in
            let fileValues = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard url.pathExtension == "json",
                  fileValues.isRegularFile == true,
                  fileValues.isSymbolicLink != true
            else {
                throw TatwoSkilletRepositoryStoreError
                    .corruptedMergeProposal(proposalID)
            }
            let conflict = try readJSON(
                TatwoSkilletMergeConflictArtifactV1.self,
                from: url
            )
            guard url.deletingPathExtension().lastPathComponent == conflict.id else {
                throw TatwoSkilletRepositoryStoreError
                    .corruptedMergeProposal(proposalID)
            }
            return conflict
        }
        guard Set(conflicts.map(\.id)).count == conflicts.count else {
            throw TatwoSkilletRepositoryStoreError
                .corruptedMergeProposal(proposalID)
        }
        return conflicts.sorted { $0.id < $1.id }
    }

    private func validateMergeProposal(
        _ proposal: TatwoMergeProposalV1,
        conflicts: [TatwoSkilletMergeConflictArtifactV1],
        metadata: RepositoryMetadata,
        requireCurrentCanonical: Bool
    ) throws {
        let revisionIDs = Set(metadata.revisionIDs)
        let referencedRevisions = [
            proposal.baseRevisionID,
            proposal.mergedRevisionID,
        ].compactMap { $0 }
            + [
                proposal.canonicalRevisionID,
                proposal.proposedRevisionID,
            ]
        let conflictsByID = Dictionary(
            conflicts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard Self.isPrefixedSHA256(proposal.id, prefix: "merge-"),
              proposal.repositoryID == metadata.id,
              Self.isValidIdentifier(proposal.sourceDeviceID),
              Self.isRevisionID(proposal.canonicalRevisionID),
              Self.isRevisionID(proposal.proposedRevisionID),
              proposal.baseRevisionID.map(Self.isRevisionID) ?? true,
              proposal.mergedRevisionID.map(Self.isRevisionID) ?? true,
              referencedRevisions.allSatisfy(revisionIDs.contains),
              Set(proposal.conflictArtifactIDs).count
                  == proposal.conflictArtifactIDs.count,
              proposal.conflictArtifactIDs
                  == proposal.conflictArtifactIDs.sorted(),
              proposal.conflictArtifactIDs
                  == conflicts.map(\.id).sorted(),
              conflictsByID.count == conflicts.count,
              proposal.status == .pending
                  ? proposal.requiresHumanApproval
                  : !proposal.requiresHumanApproval,
              !conflicts.isEmpty || proposal.mergedRevisionID != nil,
              !requireCurrentCanonical
                  || metadata.canonicalRevision == proposal.canonicalRevisionID
        else {
            if requireCurrentCanonical,
               metadata.canonicalRevision != proposal.canonicalRevisionID
            {
                throw TatwoSkilletRepositoryStoreError
                    .staleMergeProposal(proposal.id)
            }
            throw TatwoSkilletRepositoryStoreError
                .corruptedMergeProposal(proposal.id)
        }

        for conflict in conflicts {
            let digests = [
                conflict.baseContentDigest,
                conflict.canonicalContentDigest,
                conflict.proposedContentDigest,
            ].compactMap { $0 }
            guard Self.isPrefixedSHA256(conflict.id, prefix: "conflict-"),
                  conflict.repositoryID == proposal.repositoryID,
                  conflict.sourceDeviceID == proposal.sourceDeviceID,
                  conflict.baseRevisionID == proposal.baseRevisionID,
                  conflict.canonicalRevisionID == proposal.canonicalRevisionID,
                  conflict.proposedRevisionID == proposal.proposedRevisionID,
                  conflict.relativePath == "__repository__"
                      || Self.isSafeRelativePath(conflict.relativePath),
                  digests.allSatisfy(Self.isSHA256)
            else {
                throw TatwoSkilletRepositoryStoreError
                    .corruptedMergeProposal(proposal.id)
            }
        }
    }

    private func mergeProposalStalenessReason(
        _ proposal: TatwoMergeProposalV1,
        conflicts: [TatwoSkilletMergeConflictArtifactV1],
        metadata: RepositoryMetadata
    ) -> String? {
        var reasons: [String] = []
        if metadata.canonicalRevision != proposal.canonicalRevisionID {
            reasons.append(
                "canonical head moved past proposal (proposal=\(proposal.canonicalRevisionID) store=\(metadata.canonicalRevision ?? "none"))"
            )
        }
        let referencedRevisions = [
            proposal.baseRevisionID,
            proposal.mergedRevisionID,
        ].compactMap { $0 }
            + [
                proposal.canonicalRevisionID,
                proposal.proposedRevisionID,
            ]
        let missing = referencedRevisions.filter {
            !metadata.revisionIDs.contains($0)
        }
        if !missing.isEmpty {
            reasons.append(
                "referenced revisions missing from store: \(missing.joined(separator: ","))"
            )
        }
        do {
            try validateMergeProposal(
                proposal,
                conflicts: conflicts,
                metadata: metadata,
                requireCurrentCanonical: true
            )
        } catch {
            let description = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            if !reasons.contains(description) {
                reasons.append(description)
            }
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    private func decideMergeProposal(
        repositoryID: String,
        proposalID: String,
        status: TatwoMergeProposalStatusV1,
        resolvedRevisionID: String?,
        decidedBy: String,
        decidedAt: Date
    ) throws -> TatwoMergeDecisionReceiptV1 {
        try Self.validateIdentifier(repositoryID)
        try Self.validateIdentifier(proposalID)
        try Self.validateIdentifier(decidedBy)
        guard status == .approved || status == .rejected else {
            throw TatwoSkilletRepositoryStoreError
                .corruptedMergeProposal(proposalID)
        }
        if let resolvedRevisionID {
            try Self.validateIdentifier(resolvedRevisionID)
        }
        let metadataURL = repositoryDirectory(repositoryID)
            .appendingPathComponent("repository.json")

        return try withExclusiveMutationLock {
            try TatwoFileLock.withExclusiveLock(for: metadataURL) {
                var metadata = try loadMetadata(id: repositoryID)
                let proposalDirectory = mergeProposalDirectory(
                    repositoryID,
                    proposalID
                )
                let proposalURL = proposalDirectory
                    .appendingPathComponent("proposal.json")
                let decisionURL = proposalDirectory
                    .appendingPathComponent("decision.json")
                let liveDirectoryExists = fileManager.fileExists(
                    atPath: proposalDirectory.path
                )

                if status == .rejected {
                    if let archived = try loadArchivedMergeRejectionReceipt(
                        repositoryID: repositoryID,
                        proposalID: proposalID
                    ) {
                        try relocateLiveMergeProposalRemnants(
                            repositoryID: repositoryID,
                            proposalID: proposalID
                        )
                        return archived
                    }
                }

                if status == .approved {
                    guard fileManager.fileExists(atPath: proposalURL.path) else {
                        throw TatwoSkilletRepositoryStoreError
                            .mergeProposalNotFound(proposalID)
                    }
                } else if !liveDirectoryExists {
                    throw TatwoSkilletRepositoryStoreError
                        .mergeProposalNotFound(proposalID)
                }

                let loadedProposal: TatwoMergeProposalV1?
                let proposalLoadError: Error?
                if fileManager.fileExists(atPath: proposalURL.path) {
                    do {
                        loadedProposal = try readJSON(
                            TatwoMergeProposalV1.self,
                            from: proposalURL
                        )
                        proposalLoadError = nil
                    } catch {
                        loadedProposal = nil
                        proposalLoadError = error
                    }
                } else {
                    loadedProposal = nil
                    proposalLoadError = TatwoSkilletRepositoryStoreError
                        .mergeProposalNotFound(proposalID)
                }

                if status == .approved {
                    if let proposalLoadError {
                        throw proposalLoadError
                    }
                }

                let existingDecision: TatwoMergeDecisionReceiptV1?
                if fileManager.fileExists(atPath: decisionURL.path) {
                    do {
                        existingDecision = try readJSON(
                            TatwoMergeDecisionReceiptV1.self,
                            from: decisionURL
                        )
                    } catch {
                        if status == .approved {
                            throw error
                        }
                        existingDecision = nil
                    }
                } else {
                    existingDecision = nil
                }

                let loadedConflicts: [TatwoSkilletMergeConflictArtifactV1]
                let conflictLoadError: Error?
                do {
                    loadedConflicts = try loadMergeConflictsUnlocked(
                        repositoryID: repositoryID,
                        proposalID: proposalID
                    )
                    conflictLoadError = nil
                } catch {
                    if status == .approved {
                        throw error
                    }
                    loadedConflicts = []
                    conflictLoadError = error
                }

                if status == .rejected {
                    var corruptionReasons: [String] = []
                    if let proposalLoadError {
                        corruptionReasons.append(
                            mergeProposalCorruptionReason(
                                proposalLoadError,
                                proposalID: proposalID
                            )
                        )
                    }
                    if let conflictLoadError {
                        corruptionReasons.append(
                            mergeProposalCorruptionReason(
                                conflictLoadError,
                                proposalID: proposalID
                            )
                        )
                    }
                    if let loadedProposal {
                        if loadedProposal.id != proposalID
                            || loadedProposal.repositoryID != repositoryID
                        {
                            corruptionReasons.append(
                                "proposal identity does not match \(proposalID)"
                            )
                        }
                        if loadedProposal.conflictArtifactIDs
                            != loadedConflicts.map(\.id).sorted()
                        {
                            corruptionReasons.append(
                                "missing or damaged conflict artifacts"
                            )
                        }
                    }
                    if !corruptionReasons.isEmpty {
                        if let existingDecision,
                           isReusableRejectedDecision(
                               existingDecision,
                               repositoryID: repositoryID,
                               proposalID: proposalID
                           )
                        {
                            return existingDecision
                        }
                        return try archiveCorruptedMergeProposal(
                            repositoryID: repositoryID,
                            proposalID: proposalID,
                            decidedBy: decidedBy,
                            decidedAt: decidedAt,
                            corruptionReason: corruptionReasons.joined(
                                separator: "; "
                            )
                        )
                    }
                }

                guard let proposal = loadedProposal else {
                    throw TatwoSkilletRepositoryStoreError
                        .mergeProposalNotFound(proposalID)
                }
                let conflicts = loadedConflicts
                let stalenessReason = mergeProposalStalenessReason(
                    proposal,
                    conflicts: conflicts,
                    metadata: metadata
                )
                if status == .approved {
                    try validateMergeProposal(
                        proposal,
                        conflicts: conflicts,
                        metadata: metadata,
                        requireCurrentCanonical: proposal.status == .pending
                            && existingDecision == nil
                    )
                }
                guard proposal.status == .pending
                        || existingDecision != nil
                else {
                    throw TatwoSkilletRepositoryStoreError
                        .staleMergeProposal(proposalID)
                }

                let chosenRevision: String?
                if let existingDecision {
                    guard existingDecision.id == "decision-\(proposalID)",
                          existingDecision.repositoryID == repositoryID,
                          existingDecision.proposalID == proposalID,
                          existingDecision.status == status,
                          Self.isValidIdentifier(existingDecision.decidedBy),
                          existingDecision.message
                            == (status == .approved
                                ? "Human approved the Skillet merge proposal"
                                : "Human rejected the Skillet merge proposal"),
                          resolvedRevisionID == nil
                            || resolvedRevisionID
                                == existingDecision.resolvedRevisionID
                    else {
                        throw TatwoSkilletRepositoryStoreError
                            .corruptedMergeProposal(proposalID)
                    }
                    chosenRevision = existingDecision.resolvedRevisionID
                } else {
                    switch status {
                    case .approved:
                        if !conflicts.isEmpty, resolvedRevisionID == nil {
                            throw TatwoSkilletRepositoryStoreError
                                .unresolvedMergeConflicts(proposalID)
                        }
                        chosenRevision = resolvedRevisionID
                            ?? proposal.mergedRevisionID
                    case .rejected:
                        guard resolvedRevisionID == nil else {
                            throw TatwoSkilletRepositoryStoreError
                                .corruptedMergeProposal(proposalID)
                        }
                        chosenRevision = nil
                    case .pending:
                        throw TatwoSkilletRepositoryStoreError
                            .corruptedMergeProposal(proposalID)
                    }
                }

                if status == .approved {
                    guard let chosenRevision,
                          metadata.revisionIDs.contains(chosenRevision),
                          try verifyRevisionUnlocked(
                              repositoryID: repositoryID,
                              revisionID: chosenRevision
                          ),
                          try isRevision(
                              chosenRevision,
                              descendantOfOrEqualTo: proposal.canonicalRevisionID,
                              repositoryID: repositoryID,
                              metadata: metadata
                          )
                    else {
                        throw TatwoSkilletRepositoryStoreError
                            .corruptedMergeProposal(proposalID)
                    }
                } else if chosenRevision != nil {
                    throw TatwoSkilletRepositoryStoreError
                        .corruptedMergeProposal(proposalID)
                }

                let receipt: TatwoMergeDecisionReceiptV1
                if let existingDecision {
                    receipt = existingDecision
                } else {
                    receipt = TatwoMergeDecisionReceiptV1(
                        id: "decision-\(proposalID)",
                        repositoryID: repositoryID,
                        proposalID: proposalID,
                        status: status,
                        decidedBy: decidedBy,
                        decidedAt: decidedAt,
                        resolvedRevisionID: chosenRevision,
                        message: status == .approved
                            ? "Human approved the Skillet merge proposal"
                            : "Human rejected the Skillet merge proposal",
                        stalenessReason: status == .rejected
                            ? stalenessReason
                            : nil
                    )
                    try writeJSON(receipt, to: decisionURL)
                }

                if let chosenRevision {
                    if metadata.canonicalRevision == proposal.canonicalRevisionID {
                        metadata.canonicalRevision = chosenRevision
                        try writeMetadata(metadata)
                    } else if metadata.canonicalRevision != chosenRevision {
                        throw TatwoSkilletRepositoryStoreError
                            .staleMergeProposal(proposalID)
                    }
                }
                let decidedProposal = TatwoMergeProposalV1(
                    id: proposal.id,
                    repositoryID: proposal.repositoryID,
                    sourceDeviceID: proposal.sourceDeviceID,
                    baseRevisionID: proposal.baseRevisionID,
                    canonicalRevisionID: proposal.canonicalRevisionID,
                    proposedRevisionID: proposal.proposedRevisionID,
                    mergedRevisionID: chosenRevision
                        ?? proposal.mergedRevisionID,
                    conflictArtifactIDs: proposal.conflictArtifactIDs,
                    requiresHumanApproval: false,
                    status: status,
                    createdAt: proposal.createdAt
                )
                if proposal.status == .pending {
                    try writeJSON(decidedProposal, to: proposalURL)
                } else if proposal != decidedProposal {
                    throw TatwoSkilletRepositoryStoreError
                        .corruptedMergeProposal(proposalID)
                }
                return receipt
            }
        }
    }

    private func mergeProposalCorruptionReason(
        _ error: Error,
        proposalID: String
    ) -> String {
        if let storeError = error as? TatwoSkilletRepositoryStoreError,
           let description = storeError.errorDescription
        {
            return description
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription
        {
            return description
        }
        return "proposal/conflict load failed for \(proposalID)"
    }

    private func isReusableRejectedDecision(
        _ receipt: TatwoMergeDecisionReceiptV1,
        repositoryID: String,
        proposalID: String
    ) -> Bool {
        receipt.id == "decision-\(proposalID)"
            && receipt.repositoryID == repositoryID
            && receipt.proposalID == proposalID
            && receipt.status == .rejected
            && Self.isValidIdentifier(receipt.decidedBy)
            && receipt.resolvedRevisionID == nil
            && receipt.message == "Human rejected the Skillet merge proposal"
    }

    private func loadArchivedMergeRejectionReceipt(
        repositoryID: String,
        proposalID: String
    ) throws -> TatwoMergeDecisionReceiptV1? {
        let receiptURL = rejectedMergeProposalDirectory(
            repositoryID,
            proposalID
        ).appendingPathComponent("decision.json")
        guard fileManager.fileExists(atPath: receiptURL.path) else {
            return nil
        }
        guard let receipt = try? readJSON(
            TatwoMergeDecisionReceiptV1.self,
            from: receiptURL
        ), isReusableRejectedDecision(
            receipt,
            repositoryID: repositoryID,
            proposalID: proposalID
        ) else {
            return nil
        }
        return receipt
    }

    private func archiveCorruptedMergeProposal(
        repositoryID: String,
        proposalID: String,
        decidedBy: String,
        decidedAt: Date,
        corruptionReason: String
    ) throws -> TatwoMergeDecisionReceiptV1 {
        if let existing = try loadArchivedMergeRejectionReceipt(
            repositoryID: repositoryID,
            proposalID: proposalID
        ) {
            try relocateLiveMergeProposalRemnants(
                repositoryID: repositoryID,
                proposalID: proposalID
            )
            return existing
        }
        try relocateLiveMergeProposalRemnants(
            repositoryID: repositoryID,
            proposalID: proposalID
        )
        let receipt = TatwoMergeDecisionReceiptV1(
            id: "decision-\(proposalID)",
            repositoryID: repositoryID,
            proposalID: proposalID,
            status: .rejected,
            decidedBy: decidedBy,
            decidedAt: decidedAt,
            resolvedRevisionID: nil,
            message: "Human rejected the Skillet merge proposal",
            corruptionReason: corruptionReason
        )
        try writeJSON(
            receipt,
            to: rejectedMergeProposalDirectory(repositoryID, proposalID)
                .appendingPathComponent("decision.json")
        )
        return receipt
    }

    private func relocateLiveMergeProposalRemnants(
        repositoryID: String,
        proposalID: String
    ) throws {
        let live = mergeProposalDirectory(repositoryID, proposalID)
        guard fileManager.fileExists(atPath: live.path) else { return }
        let archive = rejectedMergeProposalDirectory(repositoryID, proposalID)
        let original = archive.appendingPathComponent(
            "original",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: archive,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: original.path) {
            let remnant = archive.appendingPathComponent(
                "original-remnant-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: live, to: remnant)
            return
        }
        try fileManager.moveItem(at: live, to: original)
    }

    // MARK: Paths, encoding and hashing

    private func repositoryDirectory(_ id: String) -> URL {
        rootURL
            .appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func revisionsDirectory(_ id: String) -> URL {
        repositoryDirectory(id).appendingPathComponent("revisions", isDirectory: true)
    }

    private func deviceHeadsDirectory(_ id: String) -> URL {
        repositoryDirectory(id).appendingPathComponent("device-heads", isDirectory: true)
    }

    private func receiptsDirectory(_ id: String) -> URL {
        repositoryDirectory(id).appendingPathComponent("receipts", isDirectory: true)
    }

    private func mergeProposalsDirectory(_ id: String) -> URL {
        repositoryDirectory(id)
            .appendingPathComponent("merge-proposals", isDirectory: true)
    }

    private func mergeProposalDirectory(_ id: String, _ proposalID: String) -> URL {
        mergeProposalsDirectory(id)
            .appendingPathComponent(proposalID, isDirectory: true)
    }

    private func rejectedMergeProposalsDirectory(_ id: String) -> URL {
        repositoryDirectory(id)
            .appendingPathComponent("rejected-merge-proposals", isDirectory: true)
    }

    private func rejectedMergeProposalDirectory(
        _ id: String,
        _ proposalID: String
    ) -> URL {
        rejectedMergeProposalsDirectory(id)
            .appendingPathComponent(proposalID, isDirectory: true)
    }

    private func objectDirectory(_ digest: String) -> URL {
        rootURL
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.makeEncoder().encode(value).write(to: url, options: [.atomic])
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw TatwoSkilletRepositoryStoreError.unsupportedSnapshotEntry(
                url.lastPathComponent
            )
        }
        return try Self.makeDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func ensureSnapshotReceipt(_ revision: TatwoSkillRevisionV1) throws {
        let receipt = TatwoSkilletRepositoryReceiptV1(
            id: "snapshot-\(revision.id)",
            repositoryID: revision.repositoryID,
            revisionID: revision.id,
            kind: .snapshot,
            contentDigest: revision.contentDigest,
            recordedAt: revision.createdAt,
            message: "Immutable canonical skill snapshot persisted and verified"
        )
        let destination = receiptsDirectory(revision.repositoryID)
            .appendingPathComponent("\(receipt.id).json")
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try readJSON(
                TatwoSkilletRepositoryReceiptV1.self,
                from: destination
            )
            guard existing == receipt else {
                throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
            }
            return
        }
        try writeJSON(receipt, to: destination)
    }

    private func ensureDeviceHeadReceipt(
        _ head: TatwoDeviceHeadV1,
        revision: TatwoSkillRevisionV1
    ) throws {
        guard let ledgerSequence = head.ledgerSequence,
              let lastVerifiedAt = head.lastVerifiedAt
        else {
            throw TatwoSkilletRepositoryStoreError.corruptedDeviceHead(head.deviceID)
        }
        let receipt = TatwoSkilletRepositoryReceiptV1(
            id: "device-\(head.deviceID)-e\(head.authorityEpoch)-s\(ledgerSequence)-\(head.requestID)",
            repositoryID: head.repositoryID,
            revisionID: head.revisionID,
            kind: .deviceHead,
            contentDigest: revision.contentDigest,
            deviceID: head.deviceID,
            requestID: head.requestID,
            authorityEpoch: head.authorityEpoch,
            ledgerSequence: ledgerSequence,
            activationState: head.activationState,
            recordedAt: lastVerifiedAt,
            message: "Device head verified before persistence"
        )
        let destination = receiptsDirectory(head.repositoryID)
            .appendingPathComponent("\(receipt.id).json")
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try readJSON(
                TatwoSkilletRepositoryReceiptV1.self,
                from: destination
            )
            guard existing == receipt else {
                throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
            }
            return
        }
        try writeReceipt(receipt)
    }

    private func writeReceipt(_ receipt: TatwoSkilletRepositoryReceiptV1) throws {
        guard Self.isValidIdentifier(receipt.id),
              Self.isValidIdentifier(receipt.repositoryID),
              Self.isRevisionID(receipt.revisionID),
              Self.isSHA256(receipt.contentDigest)
        else {
            throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
        }
        try writeJSON(
            receipt,
            to: receiptsDirectory(receipt.repositoryID)
                .appendingPathComponent("\(receipt.id).json")
        )
    }

    private func validateRevisionGraph(
        _ revisions: [TatwoSkillRevisionV1],
        metadata: RepositoryMetadata
    ) throws {
        let byID = Dictionary(
            revisions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard byID.count == revisions.count,
              Set(byID.keys) == Set(metadata.revisionIDs)
        else {
            throw TatwoSkilletRepositoryStoreError.corruptedRepositoryMetadata(metadata.id)
        }
        for revision in revisions {
            if let parent = revision.parentRevisionID {
                guard parent != revision.id, byID[parent] != nil else {
                    throw TatwoSkilletRepositoryStoreError.corruptedRevision(revision.id)
                }
            }
        }

        enum VisitState {
            case visiting
            case visited
        }
        var states: [String: VisitState] = [:]
        func visit(_ revisionID: String) throws {
            switch states[revisionID] {
            case .visiting:
                throw TatwoSkilletRepositoryStoreError.corruptedRevision(revisionID)
            case .visited:
                return
            case nil:
                break
            }
            states[revisionID] = .visiting
            if let parent = byID[revisionID]?.parentRevisionID {
                try visit(parent)
            }
            states[revisionID] = .visited
        }
        for revisionID in metadata.revisionIDs {
            try visit(revisionID)
        }
    }

    private func isRevision(
        _ revisionID: String,
        descendantOfOrEqualTo ancestorRevisionID: String,
        repositoryID: String,
        metadata: RepositoryMetadata
    ) throws -> Bool {
        guard metadata.revisionIDs.contains(revisionID),
              metadata.revisionIDs.contains(ancestorRevisionID)
        else {
            throw TatwoSkilletRepositoryStoreError
                .corruptedRepositoryMetadata(repositoryID)
        }
        var currentRevisionID: String? = revisionID
        var visited: Set<String> = []
        while let current = currentRevisionID {
            if current == ancestorRevisionID {
                return true
            }
            guard visited.insert(current).inserted,
                  metadata.revisionIDs.contains(current)
            else {
                throw TatwoSkilletRepositoryStoreError.corruptedRevision(current)
            }
            let revision = try loadRevision(
                repositoryID: repositoryID,
                revisionID: current
            )
            currentRevisionID = revision.parentRevisionID
        }
        return false
    }

    private func validateReceipt(
        _ receipt: TatwoSkilletRepositoryReceiptV1,
        repositoryID: String,
        metadata: RepositoryMetadata
    ) throws {
        guard Self.isValidIdentifier(receipt.id),
              receipt.repositoryID == repositoryID,
              Self.isRevisionID(receipt.revisionID),
              metadata.revisionIDs.contains(receipt.revisionID),
              Self.isSHA256(receipt.contentDigest)
        else {
            throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
        }
        let revision = try loadRevision(
            repositoryID: repositoryID,
            revisionID: receipt.revisionID
        )
        guard revision.contentDigest == receipt.contentDigest,
              try verifyRevisionUnlocked(
                  repositoryID: repositoryID,
                  revisionID: receipt.revisionID
              )
        else {
            throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
        }

        switch receipt.kind {
        case .snapshot:
            guard receipt.id == "snapshot-\(receipt.revisionID)",
                  receipt.deviceID == nil,
                  receipt.requestID == nil,
                  receipt.authorityEpoch == nil,
                  receipt.ledgerSequence == nil,
                  receipt.activationState == nil
            else {
                throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
            }
        case .promotion:
            guard receipt.id.hasPrefix("promotion-"),
                  receipt.deviceID == nil,
                  receipt.requestID == nil,
                  receipt.authorityEpoch == nil,
                  receipt.ledgerSequence == nil,
                  receipt.activationState == nil
            else {
                throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
            }
        case .rollback:
            guard receipt.id.hasPrefix("rollback-"),
                  receipt.deviceID == nil,
                  receipt.requestID == nil,
                  receipt.authorityEpoch == nil,
                  receipt.ledgerSequence == nil,
                  receipt.activationState == nil
            else {
                throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
            }
        case .archive:
            guard receipt.id.hasPrefix("archive-"),
                  receipt.deviceID == nil,
                  receipt.requestID.map(Self.isValidIdentifier) ?? true,
                  receipt.authorityEpoch == nil,
                  receipt.ledgerSequence == nil,
                  receipt.activationState == nil
            else {
                throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
            }
        case .deviceHead:
            guard let deviceID = receipt.deviceID,
                  let requestID = receipt.requestID,
                  let authorityEpoch = receipt.authorityEpoch,
                  let ledgerSequence = receipt.ledgerSequence,
                  ledgerSequence > 0,
                  receipt.activationState != nil,
                  Self.isValidIdentifier(deviceID),
                  Self.isValidIdentifier(requestID),
                  receipt.id
                      == "device-\(deviceID)-e\(authorityEpoch)-s\(ledgerSequence)-\(requestID)"
            else {
                throw TatwoSkilletRepositoryStoreError.corruptedReceipt(receipt.id)
            }
        }
    }

    private static func validateIdentifier(_ id: String) throws {
        guard isValidIdentifier(id) else {
            throw TatwoSkilletRepositoryStoreError.invalidIdentifier(id)
        }
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
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

    private static func isRevisionID(_ value: String) -> Bool {
        guard value.hasPrefix("rev-") else { return false }
        return isSHA256(String(value.dropFirst(4)))
    }

    private static func isPrefixedSHA256(
        _ value: String,
        prefix: String
    ) -> Bool {
        value.hasPrefix(prefix)
            && isSHA256(String(value.dropFirst(prefix.count)))
    }

    private static func isSHA256(_ value: String) -> Bool {
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

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.contains { component in
            component.isEmpty || component == "." || component == ".."
        }
    }

    private static func relativePath(of url: URL, under root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else {
            throw TatwoSkilletRepositoryStoreError.unsupportedSnapshotEntry(itemPath)
        }
        let path = String(itemPath.dropFirst(prefix.count))
            .precomposedStringWithCanonicalMapping
        guard isSafeRelativePath(path) else {
            throw TatwoSkilletRepositoryStoreError.unsupportedSnapshotEntry(path)
        }
        return path
    }

    private static func portablePathPrecedes(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private static func isExcludedSnapshotMetadata(relativePath: String) -> Bool {
        relativePath
            .split(separator: "/")
            .contains { component in
                component.lowercased() == ".git"
            }
    }

    private static func isProhibited(relativePath: String) -> Bool {
        let components = relativePath
            .split(separator: "/")
            .map { String($0).lowercased() }
        guard let fileName = components.last else { return true }
        if components.contains(".git") { return true }
        if fileName == ".env" || fileName.hasPrefix(".env.") { return true }
        if [
            "id_rsa",
            "id_ed25519",
            "credentials.json",
            "api-keys.json",
            "api_keys.json",
            "apikeys.json",
        ].contains(fileName) {
            return true
        }
        let deniedFragments = [
            "token",
            "secret",
            "credential",
            "cookie",
            "session",
            "keychain",
            "api-key",
            "api_key",
            "apikey",
            "private-key",
            "private_key"
        ]
        if components.contains(where: { component in
            deniedFragments.contains(where: component.contains)
        }) {
            return true
        }
        let ext = (fileName as NSString).pathExtension
        return ["key", "pem", "p12", "pfx"].contains(ext)
    }

    private static func snapshotDigest(
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

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension TatwoSkilletRepositoryStore {
    struct SnapshotCandidate {
        let manifest: TatwoSkillSnapshotManifestV1
        let files: [(relativePath: String, data: Data)]
    }

    struct RepositoryMetadata: Codable {
        let schemaVersion: Int
        let id: String
        var displayName: String
        var summary: String
        var canonicalRevision: String?
        var stableRevision: String?
        var canaryRevision: String?
        var rollbackRevision: String?
        var revisionIDs: [String]
    }
}
