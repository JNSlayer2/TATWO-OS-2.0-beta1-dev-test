import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TatwoTargetConsumerReadbackV1: Codable, Equatable, Sendable {
    public let schema: String
    public let requestID: String
    public let targetDeviceID: String
    public let authorityPrimary: String
    public let authorityEpoch: UInt64
    public let ledgerSequence: UInt64
    public let catalogRevision: String
    public let consumerID: String
    public let consumerKind: String
    public let sourceItemID: String
    public let expectedDigest: String
    public let loadedDigest: String
    public let loadedRevision: String
    public let loadedPath: String
    public let runtimeRef: String
    public let observedAt: Date
    public let status: String

    public init(
        requestID: String,
        targetDeviceID: String,
        authorityPrimary: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        consumerID: String,
        consumerKind: String,
        sourceItemID: String,
        expectedDigest: String,
        loadedDigest: String,
        loadedRevision: String,
        loadedPath: String,
        runtimeRef: String,
        observedAt: Date,
        status: String = "loaded"
    ) {
        self.schema = "TatwoTargetConsumerReadbackV1"
        self.requestID = requestID
        self.targetDeviceID = targetDeviceID
        self.authorityPrimary = authorityPrimary
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.catalogRevision = catalogRevision
        self.consumerID = consumerID
        self.consumerKind = consumerKind
        self.sourceItemID = sourceItemID
        self.expectedDigest = expectedDigest
        self.loadedDigest = loadedDigest
        self.loadedRevision = loadedRevision
        self.loadedPath = loadedPath
        self.runtimeRef = runtimeRef
        self.observedAt = observedAt
        self.status = status
    }
}

public struct TatwoTargetConsumerReadbackSetV1: Codable, Equatable, Sendable {
    public let schema: String
    public let requestID: String
    public let target: String
    public let targetDeviceID: String
    public let sourceDeviceID: String
    public let authorityPrimary: String
    public let authorityEpoch: UInt64
    public let ledgerSequence: UInt64
    public let catalogRevision: String
    public let manifestDigest: String
    public let requiredConsumerIDs: [String]
    public let readbackCount: Int
    public let readbacks: [TatwoTargetConsumerReadbackV1]
    public let observedAt: Date
    public let status: String

    public init(
        requestID: String,
        target: String,
        targetDeviceID: String,
        sourceDeviceID: String,
        authorityPrimary: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        manifestDigest: String,
        requiredConsumerIDs: [String],
        readbacks: [TatwoTargetConsumerReadbackV1],
        observedAt: Date,
        status: String = "passed"
    ) {
        self.schema = "TatwoTargetConsumerReadbackSetV1"
        self.requestID = requestID
        self.target = target
        self.targetDeviceID = targetDeviceID
        self.sourceDeviceID = sourceDeviceID
        self.authorityPrimary = authorityPrimary
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.catalogRevision = catalogRevision
        self.manifestDigest = manifestDigest
        self.requiredConsumerIDs = requiredConsumerIDs
        self.readbackCount = readbacks.count
        self.readbacks = readbacks
        self.observedAt = observedAt
        self.status = status
    }
}

public enum TatwoTargetConsumerReadbackError: Error, Equatable, LocalizedError {
    case invalidBinding(String)
    case unsafePath(String)
    case manifestMismatch(String)
    case loadedDigestMismatch(String)
    case consumerCoverageMismatch(String)
    case consumerLoadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBinding(let field):
            return "Consumer readback binding is invalid: \(field)"
        case .unsafePath(let path):
            return "Consumer readback path is unsafe: \(path)"
        case .manifestMismatch(let item):
            return "Consumer readback manifest is inconsistent: \(item)"
        case .loadedDigestMismatch(let item):
            return "Consumer did not load the expected digest: \(item)"
        case .consumerCoverageMismatch(let consumer):
            return "Required consumer did not produce complete readback: \(consumer)"
        case .consumerLoadFailed(let consumer):
            return "Runtime consumer could not load synchronized content: \(consumer)"
        }
    }
}

public struct TatwoTargetConsumerDocumentLoadV1: Equatable, Sendable {
    public let consumerID: String
    public let consumerKind: String
    public let sourceItemID: String
    public let loadedData: Data
    public let loadedPath: String
    public let runtimeRef: String

    public init(
        consumerID: String,
        consumerKind: String,
        sourceItemID: String,
        loadedData: Data,
        loadedPath: String,
        runtimeRef: String
    ) {
        self.consumerID = consumerID
        self.consumerKind = consumerKind
        self.sourceItemID = sourceItemID
        self.loadedData = loadedData
        self.loadedPath = loadedPath
        self.runtimeRef = runtimeRef
    }
}

public enum TatwoTargetConsumerLoadedRevision {
    public static func contentAddressed(sha256Digest: String) -> String {
        "sha256-\(sha256Digest)"
    }
}

/// Production Work OS bootstrap adapter. It opens the synchronized Markdown
/// through the same UTF-8 text contract required by the Work OS bootstrap,
/// rather than accepting a digest generated by the sync writer itself.
public enum TatwoWorkOSBootstrapConsumer {
    public static func loadDocument(
        sourceItemID: String,
        relativePath: String,
        mirrorRootURL: URL
    ) throws -> TatwoTargetConsumerDocumentLoadV1 {
        let expectedPath = try expectedOSPath(
            sourceItemID: sourceItemID,
            relativePath: relativePath,
            consumerID: "work-os.bootstrap"
        )
        let url = mirrorRootURL.appendingPathComponent(expectedPath)
        try requireRegularFile(url, consumerID: "work-os.bootstrap", itemID: sourceItemID)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                "work-os.bootstrap:\(sourceItemID)"
            )
        }
        return TatwoTargetConsumerDocumentLoadV1(
            consumerID: "work-os.bootstrap",
            consumerKind: "work-os-bootstrap",
            sourceItemID: sourceItemID,
            loadedData: Data(text.utf8),
            loadedPath: expectedPath,
            runtimeRef: "TatwoWorkOSBootstrapConsumer.loadDocument"
        )
    }
}

/// Production shared-runtime adapter used by the Tatwo App/Core path. This is a
/// second filesystem open with mapped-byte semantics, independent from the
/// Work OS text bootstrap and from the sync writer's staging readback.
public enum TatwoAppSharedRuntimeConsumer {
    public static func loadDocument(
        sourceItemID: String,
        relativePath: String,
        mirrorRootURL: URL
    ) throws -> TatwoTargetConsumerDocumentLoadV1 {
        let expectedPath = try expectedOSPath(
            sourceItemID: sourceItemID,
            relativePath: relativePath,
            consumerID: "tatwo-app.shared-runtime"
        )
        let url = mirrorRootURL.appendingPathComponent(expectedPath)
        try requireRegularFile(
            url,
            consumerID: "tatwo-app.shared-runtime",
            itemID: sourceItemID
        )
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty
        else {
            throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                "tatwo-app.shared-runtime:\(sourceItemID)"
            )
        }
        return TatwoTargetConsumerDocumentLoadV1(
            consumerID: "tatwo-app.shared-runtime",
            consumerKind: "tatwo-app-shared-loader",
            sourceItemID: sourceItemID,
            loadedData: data,
            loadedPath: expectedPath,
            runtimeRef: "TatwoAppSharedRuntimeConsumer.loadDocument"
        )
    }
}

private func expectedOSPath(
    sourceItemID: String,
    relativePath: String,
    consumerID: String
) throws -> String {
    let expectedPath: String
    switch sourceItemID {
    case "os.constitution":
        expectedPath = "os/os.md"
    case "os.issue":
        expectedPath = "os/issue.md"
    case "os.todo":
        // Canonical basename matches the OS source file TODO.md (case-sensitive FS).
        expectedPath = "os/TODO.md"
    default:
        throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
            "\(consumerID):\(sourceItemID)"
        )
    }
    guard relativePath == expectedPath,
          !relativePath.hasPrefix("/"),
          !relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else {
        throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
            "\(consumerID):\(sourceItemID)"
        )
    }
    return expectedPath
}

private func requireRegularFile(
    _ url: URL,
    consumerID: String,
    itemID: String
) throws {
    let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values?.isRegularFile == true,
          values?.isSymbolicLink != true
    else {
        throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
            "\(consumerID):\(itemID)"
        )
    }
}

public enum TatwoTargetConsumerReadbackProbe {
    public static let requiredConsumerIDs = [
        "work-os.bootstrap",
        "tatwo-app.shared-runtime",
        "skillet.runtime-loader",
        "codex.native-skills",
        "claude.native-skills",
    ]

    struct NativeRepositoryExpectation: Equatable, Sendable {
        let repositoryID: String
        let revisionID: String
        let contentDigest: String

        init(
            repositoryID: String,
            revisionID: String,
            contentDigest: String
        ) {
            self.repositoryID = repositoryID
            self.revisionID = revisionID
            self.contentDigest = contentDigest
        }
    }

    public static func probe(
        manifestURL: URL,
        mirrorRootURL: URL,
        skilletSetManifestURL: URL,
        skilletActivationReceiptURL: URL,
        storeURL: URL,
        runtimeRootURL: URL,
        consumerRootURL: URL,
        codexSkillsLinkURL: URL,
        claudeSkillsLinkURL: URL,
        requestID: String,
        target: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        authorityPrimary: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        observedAt: Date = Date()
    ) throws -> TatwoTargetConsumerReadbackSetV1 {
        try requireIdentifier(requestID, field: "requestID")
        try requireIdentifier(target, field: "target")
        try requireIdentifier(sourceDeviceID, field: "sourceDeviceID")
        try requireIdentifier(targetDeviceID, field: "targetDeviceID")
        try requireIdentifier(authorityPrimary, field: "authorityPrimary")
        try requireIdentifier(catalogRevision, field: "catalogRevision")
        guard ledgerSequence > 0 else {
            throw TatwoTargetConsumerReadbackError.invalidBinding("ledgerSequence")
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try decoder.decode(SystemManifest.self, from: manifestData)
        let manifestDigest = sha256(manifestData)
        guard manifest.schemaVersion == 1,
              manifest.requestID == requestID,
              manifest.targetDeviceID == targetDeviceID,
              manifest.sourceDeviceID == sourceDeviceID,
              manifest.authorityPrimary == authorityPrimary,
              manifest.authorityEpoch == authorityEpoch,
              manifest.ledgerSequence == ledgerSequence,
              manifest.catalogRevision == catalogRevision
        else {
            throw TatwoTargetConsumerReadbackError.manifestMismatch("binding")
        }

        let expectedItemIDs = [
            "os.constitution",
            "os.issue",
            "os.todo",
            "skills.skillet",
        ]
        guard manifest.items.map(\.id) == expectedItemIDs else {
            throw TatwoTargetConsumerReadbackError.manifestMismatch("item-set")
        }

        var readbacks: [TatwoTargetConsumerReadbackV1] = []
        for item in manifest.items where item.id != "skills.skillet" {
            guard ["os.constitution", "os.issue", "os.todo"].contains(item.id),
                  isSafeRelativePath(item.mirrorRelativePath),
                  isSHA256(item.sourceDigest),
                  item.byteCount >= 0
            else {
                throw TatwoTargetConsumerReadbackError.manifestMismatch(item.id)
            }
            let consumerLoads = try [
                TatwoWorkOSBootstrapConsumer.loadDocument(
                    sourceItemID: item.id,
                    relativePath: item.mirrorRelativePath,
                    mirrorRootURL: mirrorRootURL
                ),
                TatwoAppSharedRuntimeConsumer.loadDocument(
                    sourceItemID: item.id,
                    relativePath: item.mirrorRelativePath,
                    mirrorRootURL: mirrorRootURL
                ),
            ]
            for consumerLoad in consumerLoads {
                let loadedDigest = sha256(consumerLoad.loadedData)
                guard consumerLoad.loadedData.count == item.byteCount,
                      loadedDigest == item.sourceDigest
                else {
                    throw TatwoTargetConsumerReadbackError.loadedDigestMismatch(
                        "\(consumerLoad.consumerID):\(item.id)"
                    )
                }
                readbacks.append(
                    TatwoTargetConsumerReadbackV1(
                        requestID: requestID,
                        targetDeviceID: targetDeviceID,
                        authorityPrimary: authorityPrimary,
                        authorityEpoch: authorityEpoch,
                        ledgerSequence: ledgerSequence,
                        catalogRevision: catalogRevision,
                        consumerID: consumerLoad.consumerID,
                        consumerKind: consumerLoad.consumerKind,
                        sourceItemID: item.id,
                        expectedDigest: item.sourceDigest,
                        loadedDigest: loadedDigest,
                        loadedRevision: TatwoTargetConsumerLoadedRevision.contentAddressed(
                            sha256Digest: loadedDigest
                        ),
                        loadedPath: consumerLoad.loadedPath,
                        runtimeRef: consumerLoad.runtimeRef,
                        observedAt: observedAt
                    )
                )
            }
        }

        guard let skilletItem = manifest.items.first(where: { $0.id == "skills.skillet" }),
              skilletItem.mirrorRelativePath == "skillet/repositories",
              isSHA256(skilletItem.sourceDigest),
              skilletItem.repositoryCount != nil
        else {
            throw TatwoTargetConsumerReadbackError.manifestMismatch("skills.skillet")
        }
        guard let repositoryCount = skilletItem.repositoryCount,
              repositoryCount > 0
        else {
            throw TatwoTargetConsumerReadbackError.consumerCoverageMismatch(
                "skillet.runtime-loader"
            )
        }
        let setData = try Data(contentsOf: skilletSetManifestURL)
        guard setData.count == skilletItem.byteCount,
              sha256(setData) == skilletItem.sourceDigest
        else {
            throw TatwoTargetConsumerReadbackError.manifestMismatch("skills.skillet")
        }
        let setManifest = try decoder.decode(SkilletSetManifest.self, from: setData)
        guard setManifest.schemaVersion == 1,
              setManifest.requestID == requestID,
              setManifest.sourceDeviceID == sourceDeviceID,
              setManifest.targetDeviceID == targetDeviceID,
              setManifest.authorityEpoch == authorityEpoch,
              setManifest.ledgerSequence == ledgerSequence,
              setManifest.catalogRevision == catalogRevision,
              !setManifest.repositories.isEmpty,
              setManifest.repositories.count == repositoryCount,
              setManifest.repositories == setManifest.repositories.sorted(by: {
                  $0.repositoryID < $1.repositoryID
              }),
              Set(setManifest.repositories.map(\.repositoryID)).count
                == setManifest.repositories.count
        else {
            throw TatwoTargetConsumerReadbackError.manifestMismatch("skillet-set")
        }
        let activationTargetPreserved = try loadActivationTargetPreserved(
            at: skilletActivationReceiptURL,
            setManifest: setManifest,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision
        )

        let setRoot = skilletSetManifestURL.deletingLastPathComponent()
        let inputs = try setManifest.repositories.map { repository in
            try requireIdentifier(repository.repositoryID, field: "repositoryID")
            try requireIdentifier(repository.revisionID, field: "revisionID")
            guard repository.revisionID == "rev-\(repository.contentDigest)",
                  isSHA256(repository.contentDigest),
                  isSHA256(repository.bundleDigest),
                  repository.bundleRelativePath
                    == "repositories/\(repository.repositoryID)/bundle",
                  repository.bindingRelativePath
                    == "repositories/\(repository.repositoryID)/authority-binding.json"
            else {
                throw TatwoTargetConsumerReadbackError.manifestMismatch(
                    repository.repositoryID
                )
            }
            let bindingURL = setRoot.appendingPathComponent(repository.bindingRelativePath)
            let binding = try decoder.decode(
                TatwoSkilletBundleAuthorityBindingV1.self,
                from: Data(contentsOf: bindingURL)
            )
            return TatwoSkilletBoundBundleInputV1(
                repositoryID: repository.repositoryID,
                revisionID: repository.revisionID,
                contentDigest: repository.contentDigest,
                bundleDigest: repository.bundleDigest,
                bundleURL: setRoot.appendingPathComponent(repository.bundleRelativePath),
                binding: binding
            )
        }

        let activation = try TatwoSkilletBundleTransport
            .verifyAuthorityBoundSetActiveState(
            inputs,
            in: TatwoSkilletRepositoryStore(rootURL: storeURL),
            runtimeRoot: runtimeRootURL,
            deviceID: targetDeviceID,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision
        )
        guard activation.targetPreservedRepositories
                == activationTargetPreserved
        else {
            throw TatwoTargetConsumerReadbackError.manifestMismatch(
                "target-preserved"
            )
        }
        let headsByRepository = Dictionary(
            uniqueKeysWithValues: activation.heads.map {
                ($0.repositoryID, $0)
            }
        )
        for repository in setManifest.repositories {
            guard let head = headsByRepository[repository.repositoryID],
                  head.revisionID == repository.revisionID,
                  head.contentDigest == repository.contentDigest,
                  head.activationState == .active
            else {
                throw TatwoTargetConsumerReadbackError.loadedDigestMismatch(
                    repository.repositoryID
                )
            }
            readbacks.append(
                TatwoTargetConsumerReadbackV1(
                    requestID: requestID,
                    targetDeviceID: targetDeviceID,
                    authorityPrimary: authorityPrimary,
                    authorityEpoch: authorityEpoch,
                    ledgerSequence: ledgerSequence,
                    catalogRevision: catalogRevision,
                    consumerID: "skillet.runtime-loader",
                    consumerKind: "active-skill-runtime-loader",
                    sourceItemID: "skills.skillet",
                    expectedDigest: repository.contentDigest,
                    loadedDigest: head.contentDigest,
                    loadedRevision: head.revisionID,
                    loadedPath: "skillet/\(repository.repositoryID)",
                    runtimeRef:
                        "TatwoSkilletBundleTransport.verifyAuthorityBoundSetActiveState",
                    observedAt: observedAt
                )
            )
        }
        let runtimePreserved = activation.targetPreservedRepositories.filter {
            $0.state == .runtimePreserved
        }
        for repository in runtimePreserved {
            readbacks.append(
                TatwoTargetConsumerReadbackV1(
                    requestID: requestID,
                    targetDeviceID: targetDeviceID,
                    authorityPrimary: authorityPrimary,
                    authorityEpoch: authorityEpoch,
                    ledgerSequence: ledgerSequence,
                    catalogRevision: catalogRevision,
                    consumerID: "skillet.runtime-loader",
                    consumerKind: "active-skill-runtime-loader",
                    sourceItemID: "skills.skillet",
                    expectedDigest: repository.contentDigest,
                    loadedDigest: repository.contentDigest,
                    loadedRevision: repository.revisionID,
                    loadedPath: "skillet/\(repository.repositoryID)",
                    runtimeRef:
                        "TatwoSkilletBundleTransport.verifyAuthorityBoundSetActiveState",
                    observedAt: observedAt
                )
            )
        }
        let nativeRepositories = (
            setManifest.repositories.map {
                NativeRepositoryExpectation(
                    repositoryID: $0.repositoryID,
                    revisionID: $0.revisionID,
                    contentDigest: $0.contentDigest
                )
            }
            + runtimePreserved.map {
                NativeRepositoryExpectation(
                    repositoryID: $0.repositoryID,
                    revisionID: $0.revisionID,
                    contentDigest: $0.contentDigest
                )
            }
        ).sorted {
            portablePathPrecedes($0.repositoryID, $1.repositoryID)
        }
        readbacks.append(contentsOf: try probeNativeSkillsConsumers(
            runtimeRootURL: runtimeRootURL,
            consumerRootURL: consumerRootURL,
            codexSkillsLinkURL: codexSkillsLinkURL,
            claudeSkillsLinkURL: claudeSkillsLinkURL,
            repositories: nativeRepositories,
            requestID: requestID,
            targetDeviceID: targetDeviceID,
            authorityPrimary: authorityPrimary,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision,
            observedAt: observedAt
        ))
        let expectedOSItems = Set(["os.constitution", "os.issue", "os.todo"])
        for consumerID in ["work-os.bootstrap", "tatwo-app.shared-runtime"] {
            let sourceItems = Set(
                readbacks.filter { $0.consumerID == consumerID }
                    .map(\.sourceItemID)
            )
            guard sourceItems == expectedOSItems else {
                throw TatwoTargetConsumerReadbackError
                    .consumerCoverageMismatch(consumerID)
            }
        }
        let expectedRuntimeRepositoryIDs = Set(
            nativeRepositories.map(\.repositoryID)
        )
        let expectedSkillPaths: [String: Set<String>] = [
            "skillet.runtime-loader": Set(
                expectedRuntimeRepositoryIDs.map { "skillet/\($0)" }
            ),
            "codex.native-skills": Set(
                expectedRuntimeRepositoryIDs.map { ".codex/skills/\($0)" }
            ),
            "claude.native-skills": Set(
                expectedRuntimeRepositoryIDs.map { ".claude/skills/\($0)" }
            ),
        ]
        for (consumerID, expectedPaths) in expectedSkillPaths {
            let loadedPaths = Set(
                readbacks.filter { $0.consumerID == consumerID }
                    .map(\.loadedPath)
            )
            guard loadedPaths == expectedPaths else {
                throw TatwoTargetConsumerReadbackError
                    .consumerCoverageMismatch(consumerID)
            }
        }
        for requiredConsumerID in requiredConsumerIDs {
            let records = readbacks.filter { $0.consumerID == requiredConsumerID }
            guard !records.isEmpty,
                  records.allSatisfy({
                      $0.status == "loaded"
                        && $0.loadedDigest == $0.expectedDigest
                        && (
                            $0.sourceItemID == "skills.skillet"
                                ? $0.loadedRevision == "rev-\($0.loadedDigest)"
                                : $0.loadedRevision
                                    == TatwoTargetConsumerLoadedRevision.contentAddressed(
                                        sha256Digest: $0.loadedDigest
                                    )
                        )
                  })
            else {
                throw TatwoTargetConsumerReadbackError.consumerCoverageMismatch(
                    requiredConsumerID
                )
            }
        }

        return TatwoTargetConsumerReadbackSetV1(
            requestID: requestID,
            target: target,
            targetDeviceID: targetDeviceID,
            sourceDeviceID: sourceDeviceID,
            authorityPrimary: authorityPrimary,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision,
            manifestDigest: manifestDigest,
            requiredConsumerIDs: requiredConsumerIDs,
            readbacks: readbacks,
            observedAt: observedAt
        )
    }

    static func probeNativeSkillsConsumers(
        runtimeRootURL: URL,
        consumerRootURL: URL,
        codexSkillsLinkURL: URL,
        claudeSkillsLinkURL: URL,
        repositories: [NativeRepositoryExpectation],
        requestID: String,
        targetDeviceID: String,
        authorityPrimary: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String,
        observedAt: Date
    ) throws -> [TatwoTargetConsumerReadbackV1] {
        let runtimeRoot = runtimeRootURL.standardizedFileURL
        let consumerRoot = consumerRootURL.standardizedFileURL
        let managedCurrent = consumerRoot.appendingPathComponent(
            "current",
            isDirectory: false
        )
        try requirePlainDirectory(
            runtimeRoot,
            consumerID: "native-skills",
            itemID: "runtime-root"
        )
        try requirePlainDirectory(
            consumerRoot,
            consumerID: "native-skills",
            itemID: "consumer-root"
        )
        try requireExactSymbolicLink(
            managedCurrent,
            expectedTarget: runtimeRoot,
            consumerID: "native-skills"
        )
        let consumers = [
            (
                id: "codex.native-skills",
                kind: "codex-native-skills-loader",
                link: codexSkillsLinkURL.standardizedFileURL,
                logicalRoot: ".codex/skills"
            ),
            (
                id: "claude.native-skills",
                kind: "claude-native-skills-loader",
                link: claudeSkillsLinkURL.standardizedFileURL,
                logicalRoot: ".claude/skills"
            ),
        ]
        for consumer in consumers {
            try requireExactSymbolicLink(
                consumer.link,
                expectedTarget: managedCurrent,
                consumerID: consumer.id
            )
        }
        guard !repositories.isEmpty,
              repositories == repositories.sorted(by: {
                  portablePathPrecedes($0.repositoryID, $1.repositoryID)
              }),
              Set(repositories.map(\.repositoryID)).count == repositories.count
        else {
            throw TatwoTargetConsumerReadbackError.consumerCoverageMismatch(
                "native-skills:repository-set"
            )
        }

        let runtimeSetLock = runtimeRoot.appendingPathComponent(
            ".set-activation",
            isDirectory: false
        )
        return try TatwoFileLock.withExclusiveLock(for: runtimeSetLock) {
            var readbacks: [TatwoTargetConsumerReadbackV1] = []
            for consumer in consumers {
                for repository in repositories {
                    try requireIdentifier(
                        repository.repositoryID,
                        field: "repositoryID"
                    )
                    guard repository.revisionID
                            == "rev-\(repository.contentDigest)",
                          isSHA256(repository.contentDigest)
                    else {
                        throw TatwoTargetConsumerReadbackError.manifestMismatch(
                            repository.repositoryID
                        )
                    }
                    let readback = try readRepositoryThroughNativeLink(
                        consumerLinkURL: consumer.link,
                        runtimeRootURL: runtimeRoot,
                        repositoryID: repository.repositoryID,
                        consumerID: consumer.id
                    )
                    guard readback.digest == repository.contentDigest else {
                        throw TatwoTargetConsumerReadbackError.loadedDigestMismatch(
                            "\(consumer.id):\(repository.repositoryID)"
                        )
                    }
                    readbacks.append(
                        TatwoTargetConsumerReadbackV1(
                            requestID: requestID,
                            targetDeviceID: targetDeviceID,
                            authorityPrimary: authorityPrimary,
                            authorityEpoch: authorityEpoch,
                            ledgerSequence: ledgerSequence,
                            catalogRevision: catalogRevision,
                            consumerID: consumer.id,
                            consumerKind: consumer.kind,
                            sourceItemID: "skills.skillet",
                            expectedDigest: repository.contentDigest,
                            loadedDigest: readback.digest,
                            loadedRevision: repository.revisionID,
                            loadedPath:
                                "\(consumer.logicalRoot)/\(repository.repositoryID)",
                            runtimeRef:
                                "TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers",
                            observedAt: observedAt
                        )
                    )
                }
            }
            return readbacks
        }
    }

    private struct NativeRepositoryReadback {
        let digest: String
        let fileCount: Int
        let byteCount: Int
    }

    private static func readRepositoryThroughNativeLink(
        consumerLinkURL: URL,
        runtimeRootURL: URL,
        repositoryID: String,
        consumerID: String
    ) throws -> NativeRepositoryReadback {
        let repositoryRoot = consumerLinkURL.appendingPathComponent(
            repositoryID,
            isDirectory: true
        )
        let expectedRoot = runtimeRootURL.appendingPathComponent(
            repositoryID,
            isDirectory: true
        )
        guard repositoryRoot.resolvingSymlinksInPath().standardizedFileURL.path
                == expectedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        else {
            throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                "\(consumerID):managed-link"
            )
        }
        try requirePlainDirectory(
            repositoryRoot,
            consumerID: consumerID,
            itemID: repositoryID
        )

        var files: [(relativePath: String, data: Data)] = []
        try collectNativeRepositoryFiles(
            directoryURL: repositoryRoot,
            relativePrefix: "",
            consumerID: consumerID,
            files: &files
        )
        guard !files.isEmpty,
              files.contains(where: { $0.relativePath == "SKILL.md" }),
              Set(files.map(\.relativePath)).count == files.count
        else {
            throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                "\(consumerID):\(repositoryID)"
            )
        }
        files.sort {
            portablePathPrecedes($0.relativePath, $1.relativePath)
        }
        return NativeRepositoryReadback(
            digest: snapshotDigest(files),
            fileCount: files.count,
            byteCount: files.reduce(0) { $0 + $1.data.count }
        )
    }

    private static func collectNativeRepositoryFiles(
        directoryURL: URL,
        relativePrefix: String,
        consumerID: String,
        files: inout [(relativePath: String, data: Data)]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ).sorted {
            portablePathPrecedes(
                $0.lastPathComponent.precomposedStringWithCanonicalMapping,
                $1.lastPathComponent.precomposedStringWithCanonicalMapping
            )
        }
        for child in children {
            let name = child.lastPathComponent
                .precomposedStringWithCanonicalMapping
            let relativePath = relativePrefix.isEmpty
                ? name
                : "\(relativePrefix)/\(name)"
            guard isSafeRelativePath(relativePath),
                  relativePath == relativePath.precomposedStringWithCanonicalMapping
            else {
                throw TatwoTargetConsumerReadbackError.unsafePath(relativePath)
            }
            let values = try child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isSymbolicLink != true else {
                throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                    "\(consumerID):\(relativePath)"
                )
            }
            if values.isDirectory == true {
                try collectNativeRepositoryFiles(
                    directoryURL: child,
                    relativePrefix: relativePath,
                    consumerID: consumerID,
                    files: &files
                )
                continue
            }
            guard values.isRegularFile == true,
                  !isProhibitedSkillPath(relativePath)
            else {
                throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                    "\(consumerID):\(relativePath)"
                )
            }
            let data = try Data(contentsOf: child, options: [.mappedIfSafe])
            guard !TatwoSkilletSnapshotSecurityPolicy
                .containsProhibitedContent(data)
            else {
                throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                    "\(consumerID):\(relativePath)"
                )
            }
            files.append((relativePath, data))
        }
    }

    private static func requireExactSymbolicLink(
        _ linkURL: URL,
        expectedTarget: URL,
        consumerID: String
    ) throws {
        var status = stat()
        guard lstat(linkURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFLNK
        else {
            throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                "\(consumerID):managed-link"
            )
        }
        let destination: String
        do {
            destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: linkURL.path
            )
        } catch {
            throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                "\(consumerID):managed-link"
            )
        }
        let destinationURL = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : linkURL.deletingLastPathComponent().appendingPathComponent(destination)
        guard destinationURL.standardizedFileURL.path
                == expectedTarget.standardizedFileURL.path
        else {
            throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                "\(consumerID):managed-link"
            )
        }
    }

    private static func requirePlainDirectory(
        _ url: URL,
        consumerID: String,
        itemID: String
    ) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR
        else {
            throw TatwoTargetConsumerReadbackError.consumerLoadFailed(
                "\(consumerID):\(itemID)"
            )
        }
    }

    private static func portablePathPrecedes(
        _ left: String,
        _ right: String
    ) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
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

    private static func isProhibitedSkillPath(_ relativePath: String) -> Bool {
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

    private struct SystemManifest: Decodable {
        let schemaVersion: Int
        let requestID: String
        let catalogRevision: String
        let authorityEpoch: UInt64
        let ledgerSequence: UInt64
        let authorityPrimary: String
        let sourceDeviceID: String
        let targetDeviceID: String
        let items: [SystemManifestItem]
    }

    private struct SystemManifestItem: Decodable {
        let id: String
        let mirrorRelativePath: String
        let sourceDigest: String
        let byteCount: Int
        let repositoryCount: Int?
    }

    private struct SkilletSetManifest: Decodable {
        let schemaVersion: Int
        let requestID: String
        let catalogRevision: String
        let authorityEpoch: UInt64
        let ledgerSequence: UInt64
        let sourceDeviceID: String
        let targetDeviceID: String
        let repositories: [SkilletSetRepository]
    }

    private struct SkilletSetRepository: Decodable, Equatable {
        let repositoryID: String
        let revisionID: String
        let contentDigest: String
        let bundleDigest: String
        let bundleRelativePath: String
        let bindingRelativePath: String
    }

    private struct SkilletActivationReceipt: Decodable {
        let schema: String
        let requestID: String
        let sourceDeviceID: String
        let targetDeviceID: String
        let authorityEpoch: UInt64
        let ledgerSequence: UInt64
        let catalogRevision: String
        let activationState: String
        let targetPreservedRuntimeClosureCapability: String
        let targetPreservedRuntimeClosed: Bool
        let repositoryCount: Int
        let repositories: [SkilletActivationRepository]
        let targetPreservedCount: Int
        let targetPreservedRepositories: [
            TatwoSkilletTargetPreservedRepositoryV1
        ]
    }

    private struct SkilletActivationRepository: Decodable {
        let repositoryID: String
        let revisionID: String
        let contentDigest: String
        let requestID: String
        let sourceDeviceID: String
        let targetDeviceID: String
        let authorityEpoch: UInt64
        let ledgerSequence: UInt64
        let catalogRevision: String
        let activationState: String
    }

    private static func loadActivationTargetPreserved(
        at receiptURL: URL,
        setManifest: SkilletSetManifest,
        requestID: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String
    ) throws -> [TatwoSkilletTargetPreservedRepositoryV1] {
        try requireRegularFile(receiptURL)
        let receipt = try decoder.decode(
            SkilletActivationReceipt.self,
            from: Data(contentsOf: receiptURL)
        )
        guard [
            "TatwoSkilletSetActivationCLIOutputV1",
            "TatwoSkilletSetActiveVerificationCLIOutputV1",
        ].contains(receipt.schema),
              receipt.requestID == requestID,
              receipt.sourceDeviceID == sourceDeviceID,
              receipt.targetDeviceID == targetDeviceID,
              receipt.authorityEpoch == authorityEpoch,
              receipt.ledgerSequence == ledgerSequence,
              receipt.catalogRevision == catalogRevision,
              receipt.activationState == "active",
              receipt.targetPreservedRuntimeClosureCapability
                == "target-preserved-runtime-closure-v1",
              receipt.targetPreservedRuntimeClosed,
              receipt.repositoryCount == setManifest.repositories.count,
              receipt.repositories.count == setManifest.repositories.count,
              receipt.targetPreservedCount
                == receipt.targetPreservedRepositories.count
        else {
            throw TatwoTargetConsumerReadbackError.manifestMismatch(
                "skillet-activation-receipt"
            )
        }
        for (expected, actual) in zip(
            setManifest.repositories,
            receipt.repositories
        ) {
            guard actual.repositoryID == expected.repositoryID,
                  actual.revisionID == expected.revisionID,
                  actual.contentDigest == expected.contentDigest,
                  actual.requestID == requestID,
                  actual.sourceDeviceID == sourceDeviceID,
                  actual.targetDeviceID == targetDeviceID,
                  actual.authorityEpoch == authorityEpoch,
                  actual.ledgerSequence == ledgerSequence,
                  actual.catalogRevision == catalogRevision,
                  actual.activationState == "active"
            else {
                throw TatwoTargetConsumerReadbackError.manifestMismatch(
                    "skillet-activation-repository"
                )
            }
        }
        let incomingIDs = Set(setManifest.repositories.map(\.repositoryID))
        let preserved = receipt.targetPreservedRepositories
        guard preserved == preserved.sorted(by: {
                  portablePathPrecedes($0.repositoryID, $1.repositoryID)
              }),
              Set(preserved.map(\.repositoryID)).count == preserved.count
        else {
            throw TatwoTargetConsumerReadbackError.manifestMismatch(
                "target-preserved-set"
            )
        }
        for repository in preserved {
            try requireIdentifier(
                repository.repositoryID,
                field: "targetPreservedRepositoryID"
            )
            guard !incomingIDs.contains(repository.repositoryID),
                  repository.revisionID == "rev-\(repository.contentDigest)",
                  isSHA256(repository.contentDigest),
                  repository.state == .runtimePreserved
            else {
                throw TatwoTargetConsumerReadbackError.manifestMismatch(
                    "target-preserved-repository"
                )
            }
        }
        return preserved
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func requireIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.hasPrefix("."),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 48...57, 58, 65...90, 95, 97...122:
                      true
                  default:
                      false
                  }
              })
        else {
            throw TatwoTargetConsumerReadbackError.invalidBinding(field)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TatwoTargetConsumerReadbackError.unsafePath(url.path)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                true
            default:
                false
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
