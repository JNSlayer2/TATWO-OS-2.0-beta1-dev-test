import Foundation
import TatwoUltraworkCore

struct TatwoSkilletExportCLIOutputV1: Codable {
  let schema: String
  let repositoryID: String
  let revisionID: String
  let contentDigest: String
  let bundleDigest: String
  let requestID: String
  let authorityEpoch: UInt64
  let ledgerSequence: UInt64
  let bundlePath: String
  let bindingPath: String
}

struct TatwoSkilletActivationCLIOutputV1: Codable {
  let schema: String
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

struct TatwoSkilletVerificationCLIOutputV1: Codable {
  let schema: String
  let repositoryID: String
  let revisionID: String
  let bundleDigest: String
  let requestID: String
  let sourceDeviceID: String
  let targetDeviceID: String
  let authorityEpoch: UInt64
  let ledgerSequence: UInt64
  let catalogRevision: String
}

struct TatwoSkilletSnapshotCLIOutputV1: Codable {
  let schema: String
  let repositoryID: String
  let revisionID: String
  let contentDigest: String
  let channel: String
  let storePath: String
}

struct TatwoSkilletSetRepositoryActivationCLIOutputV1: Codable {
  let repositoryID: String
  let revisionID: String
  let contentDigest: String
  let bundleDigest: String
  let requestID: String
  let sourceDeviceID: String
  let targetDeviceID: String
  let authorityEpoch: UInt64
  let ledgerSequence: UInt64
  let catalogRevision: String
  let activationState: String
}

struct TatwoSkilletTargetPreservedRepositoryCLIOutputV1: Codable {
  let repositoryID: String
  let revisionID: String
  let contentDigest: String
  let state: String
}

struct TatwoSkilletSetActivationCLIOutputV1: Codable {
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
  let repositories: [TatwoSkilletSetRepositoryActivationCLIOutputV1]
  let targetPreservedCount: Int
  let targetPreservedRepositories: [
    TatwoSkilletTargetPreservedRepositoryCLIOutputV1
  ]
}

struct TatwoSkilletMergePendingRepositoryCLIOutputV1: Codable {
  let repositoryID: String
  let proposalID: String
  let sourceDeviceID: String
  let baseRevisionID: String?
  let canonicalRevisionID: String
  let proposedRevisionID: String
  let mergedRevisionID: String?
  let contentDigest: String
  let bundleDigest: String
  let conflictCount: Int
  let conflictArtifactIDs: [String]
  let status: String
}

struct TatwoSkilletBranchPreservedRepositoryCLIOutputV1: Codable {
  let repositoryID: String
  let revisionID: String
  let contentDigest: String
  let bundleDigest: String
  let state: String
}

struct TatwoSkilletSetMergePendingCLIOutputV1: Codable {
  let schema: String
  let requestID: String
  let sourceDeviceID: String
  let targetDeviceID: String
  let authorityEpoch: UInt64
  let ledgerSequence: UInt64
  let catalogRevision: String
  let activationState: String
  let repositoryCount: Int
  let proposalCount: Int
  let branchPreservedCount: Int
  let proposalIDs: [String]
  let repositories: [TatwoSkilletMergePendingRepositoryCLIOutputV1]
  let branchPreservedRepositories: [
    TatwoSkilletBranchPreservedRepositoryCLIOutputV1
  ]
  let targetPreservedCount: Int
  let targetPreservedRepositories: [
    TatwoSkilletTargetPreservedRepositoryCLIOutputV1
  ]
}

struct TatwoSkilletMergeListCLIOutputV1: Codable {
  let schema: String
  let repositoryCount: Int
  let proposalCount: Int
  let proposals: [TatwoMergeProposalV1]
}

struct TatwoSkilletMergeResolutionCLIOutputV1: Codable {
  let schema: String
  let repositoryID: String
  let proposalID: String
  let canonicalRevisionID: String
  let proposedRevisionID: String
  let resolvedRevisionID: String
  let contentDigest: String
  let conflictCount: Int
  let channel: String
  let canonicalActivationState: String
}

struct TatwoSkilletMergeDecisionCLIOutputV1: Codable {
  let schema: String
  let repositoryID: String
  let proposalID: String
  let status: String
  let resolvedRevisionID: String?
  let runtimeActivationState: String
  let runtimeBefore: TatwoSkilletRuntimeReadbackV1
  let runtimeAfter: TatwoSkilletRuntimeReadbackV1
  let decision: TatwoMergeDecisionReceiptV1
}

enum TatwoSkilletCLI {
  private static let usage =
    "Use: tatwo-ultrawork skillet snapshot|list|export-bound|verify-bound|import-activate|import-activate-set|verify-active-set|consumer-readback|merge-list|merge-resolve|merge-approve|merge-reject --json"

  static func run(_ args: [String]) throws {
    guard let operation = args.dropFirst().first else {
      throw CLIError.usage(usage)
    }
    switch operation {
    case "snapshot":
      try snapshot(args)
    case "list":
      let store = TatwoSkilletRepositoryStore(
        rootURL: URL(
          fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--store", in: args),
          isDirectory: true))
      TatwoUltraworkCLI.output(
        try store.listRepositoryIDs(),
        command: "skillet list")
    case "export-bound":
      try exportBound(args)
    case "verify-bound":
      try verifyBound(args)
    case "import-activate":
      try importAndActivate(args)
    case "import-activate-set":
      try importAndActivateSet(args)
    case "verify-active-set":
      try verifyActiveSet(args)
    case "consumer-readback":
      try consumerReadback(args)
    case "merge-list":
      try mergeList(args)
    case "merge-resolve":
      try mergeResolve(args)
    case "merge-approve":
      try mergeApprove(args)
    case "merge-reject":
      try mergeReject(args)
    default:
      throw CLIError.usage(usage)
    }
  }

  private static func snapshot(_ args: [String]) throws {
    let storeURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--store", in: args),
      isDirectory: true)
    let repositoryID = try TatwoUltraworkCLI.requiredOption("--repository", in: args)
    let displayName =
      TatwoUltraworkCLI.option("--display-name", in: args)
      ?? repositoryID
    let summary =
      TatwoUltraworkCLI.option("--summary", in: args)
      ?? "Private Skillet repository"
    let sourceURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--source", in: args),
      isDirectory: true)
    let channelRaw = TatwoUltraworkCLI.option("--channel", in: args) ?? "staging"
    guard let channel = TatwoSkillChannelV1(rawValue: channelRaw) else {
      throw CLIError.usage(
        "--channel must be draft|staging|canary|stable|rollback")
    }
    let revision = try TatwoSkilletRepositoryStore(rootURL: storeURL)
      .snapshotCanonicalSkillDirectory(
        repositoryID: repositoryID,
        displayName: displayName,
        summary: summary,
        sourceDirectory: sourceURL,
        channel: channel)
    let output = TatwoSkilletSnapshotCLIOutputV1(
      schema: "TatwoSkilletSnapshotCLIOutputV1",
      repositoryID: repositoryID,
      revisionID: revision.id,
      contentDigest: revision.contentDigest,
      channel: revision.channel.rawValue,
      storePath: storeURL.path)
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(output, command: "skillet snapshot")
  }

  private static func exportBound(_ args: [String]) throws {
    let storeURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--store", in: args),
      isDirectory: true)
    let repositoryID = try TatwoUltraworkCLI.requiredOption("--repository", in: args)
    let bundleURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--bundle", in: args),
      isDirectory: true)
    let bindingURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--binding", in: args))
    let requestID = try TatwoUltraworkCLI.requiredOption("--request", in: args)
    let sourceDeviceID = try TatwoUltraworkCLI.requiredOption(
      "--source-device",
      in: args)
    let targetDeviceID = try TatwoUltraworkCLI.requiredOption(
      "--target-device",
      in: args)
    let authorityEpoch = try requiredUInt64("--authority-epoch", args: args)
    let ledgerSequence = try requiredUInt64("--ledger-sequence", args: args)
    let catalogRevision = try TatwoUltraworkCLI.requiredOption(
      "--catalog-revision",
      in: args)

    let store = TatwoSkilletRepositoryStore(rootURL: storeURL)
    let repository = try store.loadRepository(id: repositoryID)
    guard let revisionID =
      TatwoUltraworkCLI.option("--revision", in: args)
      ?? repository.canonicalRevision
    else {
      throw CLIError.usage(
        "Skillet repository does not have a canonical revision: \(repositoryID)")
    }
    guard let revision = repository.revisions.first(where: { $0.id == revisionID }) else {
      throw CLIError.usage(
        "Skillet repository does not contain revision \(revisionID): \(repositoryID)")
    }
    _ = try TatwoSkilletBundleTransport.exportBundle(
      from: store,
      repositoryID: repositoryID,
      revisionID: revisionID,
      to: bundleURL)
    let binding = try TatwoSkilletBundleTransport.makeAuthorityBinding(
      at: bundleURL,
      requestID: requestID,
      sourceDeviceID: sourceDeviceID,
      targetDeviceID: targetDeviceID,
      authorityEpoch: authorityEpoch,
      ledgerSequence: ledgerSequence,
      catalogRevision: catalogRevision)
    try writeJSON(binding, to: bindingURL)

    let output = TatwoSkilletExportCLIOutputV1(
      schema: "TatwoSkilletExportCLIOutputV1",
      repositoryID: repositoryID,
      revisionID: revisionID,
      contentDigest: revision.contentDigest,
      bundleDigest: binding.bundleDigest,
      requestID: requestID,
      authorityEpoch: authorityEpoch,
      ledgerSequence: ledgerSequence,
      bundlePath: bundleURL.path,
      bindingPath: bindingURL.path)
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(output, command: "skillet export-bound")
  }

  private static func verifyBound(_ args: [String]) throws {
    let operation = try boundOperationInput(args)
    let manifest = try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
      at: operation.bundleURL,
      binding: operation.binding,
      expectedRequestID: operation.requestID,
      expectedSourceDeviceID: operation.sourceDeviceID,
      expectedTargetDeviceID: operation.targetDeviceID,
      expectedAuthorityEpoch: operation.authorityEpoch,
      expectedLedgerSequence: operation.ledgerSequence,
      expectedCatalogRevision: operation.catalogRevision)
    let output = TatwoSkilletVerificationCLIOutputV1(
      schema: "TatwoSkilletVerificationCLIOutputV1",
      repositoryID: manifest.repositoryID,
      revisionID: manifest.exportedRevisionID,
      bundleDigest: operation.binding.bundleDigest,
      requestID: operation.requestID,
      sourceDeviceID: operation.sourceDeviceID,
      targetDeviceID: operation.targetDeviceID,
      authorityEpoch: operation.authorityEpoch,
      ledgerSequence: operation.ledgerSequence,
      catalogRevision: operation.catalogRevision)
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(output, command: "skillet verify-bound")
  }

  private static func importAndActivate(_ args: [String]) throws {
    let operation = try boundOperationInput(args)
    let bundleURL = operation.bundleURL
    let storeURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--store", in: args),
      isDirectory: true)
    let runtimeRoot = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--runtime-root", in: args),
      isDirectory: true)
    let manifest = try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
      at: bundleURL,
      binding: operation.binding,
      expectedRequestID: operation.requestID,
      expectedSourceDeviceID: operation.sourceDeviceID,
      expectedTargetDeviceID: operation.targetDeviceID,
      expectedAuthorityEpoch: operation.authorityEpoch,
      expectedLedgerSequence: operation.ledgerSequence,
      expectedCatalogRevision: operation.catalogRevision)
    let store = TatwoSkilletRepositoryStore(rootURL: storeURL)
    let repository = try TatwoSkilletBundleTransport.importBundle(
      at: bundleURL,
      into: store)
    guard repository.id == manifest.repositoryID,
          repository.revisions.contains(where: {
            $0.id == manifest.exportedRevisionID
          })
    else {
      throw CLIError.usage(
        "Imported Skillet repository does not contain the authority-bound revision")
    }
    let head = try TatwoSkilletBundleTransport.activateRevisionAtomically(
      in: store,
      repositoryID: manifest.repositoryID,
      revisionID: manifest.exportedRevisionID,
      runtimeRoot: runtimeRoot,
      deviceID: operation.targetDeviceID,
      requestID: operation.requestID,
      authorityEpoch: operation.authorityEpoch,
      ledgerSequence: operation.ledgerSequence,
      verifiedAt: Date())
    let output = TatwoSkilletActivationCLIOutputV1(
      schema: "TatwoSkilletActivationCLIOutputV1",
      repositoryID: head.repositoryID,
      revisionID: head.revisionID,
      contentDigest: head.contentDigest,
      requestID: head.requestID,
      sourceDeviceID: operation.sourceDeviceID,
      targetDeviceID: head.deviceID,
      authorityEpoch: head.authorityEpoch,
      ledgerSequence: head.ledgerSequence ?? operation.ledgerSequence,
      catalogRevision: operation.catalogRevision,
      activationState: head.activationState.rawValue)
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(output, command: "skillet import-activate")
  }

  private static func importAndActivateSet(_ args: [String]) throws {
    let operation = try setOperationInput(args)
    let storeURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--store", in: args),
      isDirectory: true)
    let runtimeRoot = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--runtime-root", in: args),
      isDirectory: true)
    let store = TatwoSkilletRepositoryStore(rootURL: storeURL)
    let outcome = try TatwoSkilletBundleTransport.receiveAndActivateAuthorityBoundSet(
      operation.inputs,
      into: store,
      runtimeRoot: runtimeRoot,
      deviceID: operation.targetDeviceID,
      requestID: operation.requestID,
      sourceDeviceID: operation.sourceDeviceID,
      authorityEpoch: operation.authorityEpoch,
      ledgerSequence: operation.ledgerSequence,
      catalogRevision: operation.catalogRevision,
      activateTargetPreservedRuntime:
        args.contains("--activate-target-preserved"),
      ownerInitiatedApply: args.contains("--owner-initiated"),
      verifiedAt: Date())

    switch outcome {
    case .activated(let activation):
      let heads = activation.heads
      let targetPreservedRepositories = activation.targetPreservedRepositories
        .map {
          TatwoSkilletTargetPreservedRepositoryCLIOutputV1(
            repositoryID: $0.repositoryID,
            revisionID: $0.revisionID,
            contentDigest: $0.contentDigest,
            state: $0.state.rawValue)
        }
      let inputByRepository = Dictionary(
        uniqueKeysWithValues: operation.inputs.map { ($0.repositoryID, $0) })
      let repositories = try heads.sorted { $0.repositoryID < $1.repositoryID }.map {
        head -> TatwoSkilletSetRepositoryActivationCLIOutputV1 in
        guard let input = inputByRepository[head.repositoryID] else {
          throw CLIError.usage(
            "Skillet set activation returned an unexpected repository")
        }
        return TatwoSkilletSetRepositoryActivationCLIOutputV1(
          repositoryID: head.repositoryID,
          revisionID: head.revisionID,
          contentDigest: head.contentDigest,
          bundleDigest: input.bundleDigest,
          requestID: operation.requestID,
          sourceDeviceID: operation.sourceDeviceID,
          targetDeviceID: head.deviceID,
          authorityEpoch: head.authorityEpoch,
          ledgerSequence: head.ledgerSequence ?? operation.ledgerSequence,
          catalogRevision: operation.catalogRevision,
          activationState: head.activationState.rawValue)
      }
      let output = TatwoSkilletSetActivationCLIOutputV1(
        schema: "TatwoSkilletSetActivationCLIOutputV1",
        requestID: operation.requestID,
        sourceDeviceID: operation.sourceDeviceID,
        targetDeviceID: operation.targetDeviceID,
        authorityEpoch: operation.authorityEpoch,
        ledgerSequence: operation.ledgerSequence,
        catalogRevision: operation.catalogRevision,
        activationState: try aggregateActivationState(repositories),
        targetPreservedRuntimeClosureCapability:
          "target-preserved-runtime-closure-v1",
        targetPreservedRuntimeClosed: targetPreservedRepositories.allSatisfy {
          $0.state == TatwoSkilletTargetPreservedStateV1.runtimePreserved.rawValue
        },
        repositoryCount: repositories.count,
        repositories: repositories,
        targetPreservedCount: targetPreservedRepositories.count,
        targetPreservedRepositories: targetPreservedRepositories)
      if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
        try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
      }
      TatwoUltraworkCLI.output(output, command: "skillet import-activate-set")

    case .mergeProposed(let pending):
      let targetPreservedRepositories = pending.targetPreservedRepositories.map {
        TatwoSkilletTargetPreservedRepositoryCLIOutputV1(
          repositoryID: $0.repositoryID,
          revisionID: $0.revisionID,
          contentDigest: $0.contentDigest,
          state: $0.state.rawValue)
      }
      let inputByRepository = Dictionary(
        uniqueKeysWithValues: operation.inputs.map { ($0.repositoryID, $0) })
      let repositories = try pending.proposals.sorted {
        if $0.repositoryID == $1.repositoryID { return $0.id < $1.id }
        return $0.repositoryID < $1.repositoryID
      }.map { proposal -> TatwoSkilletMergePendingRepositoryCLIOutputV1 in
        guard let input = inputByRepository[proposal.repositoryID] else {
          throw CLIError.usage(
            "Skillet merge proposal returned an unexpected repository")
        }
        return TatwoSkilletMergePendingRepositoryCLIOutputV1(
          repositoryID: proposal.repositoryID,
          proposalID: proposal.id,
          sourceDeviceID: proposal.sourceDeviceID,
          baseRevisionID: proposal.baseRevisionID,
          canonicalRevisionID: proposal.canonicalRevisionID,
          proposedRevisionID: proposal.proposedRevisionID,
          mergedRevisionID: proposal.mergedRevisionID,
          contentDigest: input.contentDigest,
          bundleDigest: input.bundleDigest,
          conflictCount: proposal.conflictArtifactIDs.count,
          conflictArtifactIDs: proposal.conflictArtifactIDs,
          status: proposal.status.rawValue)
      }
      let branchPreservedRepositories = try pending.branchPreservedRevisions
        .sorted { $0.repositoryID < $1.repositoryID }
        .map {
          preserved -> TatwoSkilletBranchPreservedRepositoryCLIOutputV1 in
          guard let input = inputByRepository[preserved.repositoryID],
            input.revisionID == preserved.revisionID,
            input.contentDigest == preserved.contentDigest
          else {
            throw CLIError.usage(
              "Skillet branch-preserved result does not match the bound set")
          }
          return TatwoSkilletBranchPreservedRepositoryCLIOutputV1(
            repositoryID: preserved.repositoryID,
            revisionID: preserved.revisionID,
            contentDigest: preserved.contentDigest,
            bundleDigest: input.bundleDigest,
            state: "branch-preserved")
        }
      let output = TatwoSkilletSetMergePendingCLIOutputV1(
        schema: "TatwoSkilletSetMergePendingCLIOutputV1",
        requestID: operation.requestID,
        sourceDeviceID: operation.sourceDeviceID,
        targetDeviceID: operation.targetDeviceID,
        authorityEpoch: operation.authorityEpoch,
        ledgerSequence: operation.ledgerSequence,
        catalogRevision: operation.catalogRevision,
        activationState: "merge-pending",
        repositoryCount: pending.repositoryCount,
        proposalCount: repositories.count,
        branchPreservedCount: branchPreservedRepositories.count,
        proposalIDs: repositories.map(\.proposalID),
        repositories: repositories,
        branchPreservedRepositories: branchPreservedRepositories,
        targetPreservedCount: targetPreservedRepositories.count,
        targetPreservedRepositories: targetPreservedRepositories)
      guard let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) else {
        throw CLIError.usage(
          "Skillet merge-pending outcome requires --receipt so proposals remain machine-readable")
      }
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
      throw CLIError.mergePending(
        "Skillet set requires human merge approval; receipt=\(receiptPath) proposals=\(output.proposalIDs.joined(separator: ","))")
    }
  }

  private static func verifyActiveSet(_ args: [String]) throws {
    let operation = try setOperationInput(args)
    let storeURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--store", in: args),
      isDirectory: true)
    let runtimeRoot = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--runtime-root", in: args),
      isDirectory: true)
    let store = TatwoSkilletRepositoryStore(rootURL: storeURL)
    let activation = try TatwoSkilletBundleTransport.verifyAuthorityBoundSetActiveState(
      operation.inputs,
      in: store,
      runtimeRoot: runtimeRoot,
      deviceID: operation.targetDeviceID,
      requestID: operation.requestID,
      sourceDeviceID: operation.sourceDeviceID,
      authorityEpoch: operation.authorityEpoch,
      ledgerSequence: operation.ledgerSequence,
      catalogRevision: operation.catalogRevision)
    let heads = activation.heads
    let targetPreservedRepositories = activation.targetPreservedRepositories.map {
        TatwoSkilletTargetPreservedRepositoryCLIOutputV1(
          repositoryID: $0.repositoryID,
          revisionID: $0.revisionID,
          contentDigest: $0.contentDigest,
          state: $0.state.rawValue)
      }
    let inputByRepository = Dictionary(
      uniqueKeysWithValues: operation.inputs.map { ($0.repositoryID, $0) })
    let repositories = try heads.sorted { $0.repositoryID < $1.repositoryID }.map {
      head -> TatwoSkilletSetRepositoryActivationCLIOutputV1 in
      guard let input = inputByRepository[head.repositoryID] else {
        throw CLIError.usage(
          "Skillet active-set verification returned an unexpected repository")
      }
      return TatwoSkilletSetRepositoryActivationCLIOutputV1(
        repositoryID: head.repositoryID,
        revisionID: head.revisionID,
        contentDigest: head.contentDigest,
        bundleDigest: input.bundleDigest,
        requestID: operation.requestID,
        sourceDeviceID: operation.sourceDeviceID,
        targetDeviceID: head.deviceID,
        authorityEpoch: head.authorityEpoch,
        ledgerSequence: head.ledgerSequence ?? operation.ledgerSequence,
        catalogRevision: operation.catalogRevision,
        activationState: head.activationState.rawValue)
    }
    let output = TatwoSkilletSetActivationCLIOutputV1(
      schema: "TatwoSkilletSetActiveVerificationCLIOutputV1",
      requestID: operation.requestID,
      sourceDeviceID: operation.sourceDeviceID,
      targetDeviceID: operation.targetDeviceID,
      authorityEpoch: operation.authorityEpoch,
      ledgerSequence: operation.ledgerSequence,
      catalogRevision: operation.catalogRevision,
      activationState: try aggregateActivationState(repositories),
      targetPreservedRuntimeClosureCapability:
        "target-preserved-runtime-closure-v1",
      targetPreservedRuntimeClosed: targetPreservedRepositories.allSatisfy {
        $0.state == TatwoSkilletTargetPreservedStateV1.runtimePreserved.rawValue
      },
      repositoryCount: repositories.count,
      repositories: repositories,
      targetPreservedCount: targetPreservedRepositories.count,
      targetPreservedRepositories: targetPreservedRepositories)
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(output, command: "skillet verify-active-set")
  }

  private static func consumerReadback(_ args: [String]) throws {
    let output = try TatwoTargetConsumerReadbackProbe.probe(
      manifestURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--manifest",
          in: args)),
      mirrorRootURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--mirror-root",
          in: args),
        isDirectory: true),
      skilletSetManifestURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--set-manifest",
          in: args)),
      skilletActivationReceiptURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--activation-receipt",
          in: args)),
      storeURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--store",
          in: args),
        isDirectory: true),
      runtimeRootURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--runtime-root",
          in: args),
        isDirectory: true),
      consumerRootURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--consumer-root",
          in: args),
        isDirectory: true),
      codexSkillsLinkURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--codex-skills-link",
          in: args),
        isDirectory: true),
      claudeSkillsLinkURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--claude-skills-link",
          in: args),
        isDirectory: true),
      requestID: try TatwoUltraworkCLI.requiredOption("--request", in: args),
      target: try TatwoUltraworkCLI.requiredOption("--target", in: args),
      sourceDeviceID: try TatwoUltraworkCLI.requiredOption(
        "--source-device",
        in: args),
      targetDeviceID: try TatwoUltraworkCLI.requiredOption(
        "--target-device",
        in: args),
      authorityPrimary: try TatwoUltraworkCLI.requiredOption(
        "--authority-primary",
        in: args),
      authorityEpoch: try requiredUInt64("--authority-epoch", args: args),
      ledgerSequence: try requiredUInt64("--ledger-sequence", args: args),
      catalogRevision: try TatwoUltraworkCLI.requiredOption(
        "--catalog-revision",
        in: args))
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(output, command: "skillet consumer-readback")
  }

  private static func mergeList(_ args: [String]) throws {
    let store = TatwoSkilletRepositoryStore(
      rootURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--store",
          in: args),
        isDirectory: true))
    let repositoryIDs: [String]
    if let repositoryID = TatwoUltraworkCLI.option("--repository", in: args) {
      guard isSafeSkilletIdentifier(repositoryID) else {
        throw CLIError.usage("--repository is not a safe Skillet identifier")
      }
      repositoryIDs = [repositoryID]
    } else {
      repositoryIDs = try store.listRepositoryIDs()
    }
    let proposals = try repositoryIDs.sorted().flatMap {
      try store.loadMergeProposals(repositoryID: $0)
    }.sorted {
      if $0.repositoryID == $1.repositoryID {
        if $0.createdAt == $1.createdAt { return $0.id < $1.id }
        return $0.createdAt < $1.createdAt
      }
      return $0.repositoryID < $1.repositoryID
    }
    let output = TatwoSkilletMergeListCLIOutputV1(
      schema: "TatwoSkilletMergeListCLIOutputV1",
      repositoryCount: repositoryIDs.count,
      proposalCount: proposals.count,
      proposals: proposals)
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(output, command: "skillet merge-list")
  }

  private static func mergeApprove(_ args: [String]) throws {
    try mergeDecision(args, approve: true)
  }

  private static func mergeResolve(_ args: [String]) throws {
    let store = TatwoSkilletRepositoryStore(
      rootURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--store",
          in: args),
        isDirectory: true))
    let repositoryID = try TatwoUltraworkCLI.requiredOption(
      "--repository",
      in: args)
    let proposalID = try TatwoUltraworkCLI.requiredOption(
      "--proposal",
      in: args)
    let sourceURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
        "--source",
        in: args),
      isDirectory: true)
    let channelRaw = TatwoUltraworkCLI.option("--channel", in: args) ?? "staging"
    guard isSafeSkilletIdentifier(repositoryID),
          isSafeSkilletIdentifier(proposalID)
    else {
      throw CLIError.usage(
        "--repository and --proposal must be safe Skillet identifiers")
    }
    guard ["draft", "staging"].contains(channelRaw),
          let channel = TatwoSkillChannelV1(rawValue: channelRaw)
    else {
      throw CLIError.usage(
        "--channel for merge-resolve must be draft|staging")
    }

    let repository = try store.loadRepository(id: repositoryID)
    guard let proposal = try store.loadMergeProposals(repositoryID: repositoryID)
      .first(where: { $0.id == proposalID })
    else {
      throw CLIError.usage(
        "Skillet merge proposal was not found: \(proposalID)")
    }
    guard proposal.status == .pending,
          proposal.requiresHumanApproval,
          repository.canonicalRevision == proposal.canonicalRevisionID
    else {
      throw CLIError.staleMergeProposal(
        "Skillet merge proposal is stale or already decided: \(proposalID)")
    }
    guard proposal.mergedRevisionID == nil,
          !proposal.conflictArtifactIDs.isEmpty
    else {
      throw CLIError.mergeConflictUnresolved(
        "Skillet merge proposal already has a clean deterministic merge and does not accept a manual resolution: \(proposalID)")
    }

    let revision = try store.snapshotDetachedSkillDirectory(
      repositoryID: repositoryID,
      displayName: repository.displayName,
      summary: repository.summary,
      sourceDirectory: sourceURL,
      channel: channel,
      parentRevisionID: proposal.canonicalRevisionID)
    guard revision.id != proposal.canonicalRevisionID,
          revision.id != proposal.proposedRevisionID,
          revision.parentRevisionID == proposal.canonicalRevisionID
    else {
      throw CLIError.mergeConflictUnresolved(
        "Resolved source must create a new revision parented to the current canonical")
    }
    let canonicalAfter = try store.loadRepository(id: repositoryID).canonicalRevision
    guard canonicalAfter == proposal.canonicalRevisionID else {
      throw CLIError.staleMergeProposal(
        "Skillet canonical changed while preparing merge resolution: \(proposalID)")
    }

    let output = TatwoSkilletMergeResolutionCLIOutputV1(
      schema: "TatwoSkilletMergeResolutionCLIOutputV1",
      repositoryID: repositoryID,
      proposalID: proposalID,
      canonicalRevisionID: proposal.canonicalRevisionID,
      proposedRevisionID: proposal.proposedRevisionID,
      resolvedRevisionID: revision.id,
      contentDigest: revision.contentDigest,
      conflictCount: proposal.conflictArtifactIDs.count,
      channel: revision.channel.rawValue,
      canonicalActivationState: "unchanged")
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(output, command: "skillet merge-resolve")
  }

  private static func mergeReject(_ args: [String]) throws {
    try mergeDecision(args, approve: false)
  }

  private static func mergeDecision(
    _ args: [String],
    approve: Bool
  ) throws {
    let store = TatwoSkilletRepositoryStore(
      rootURL: URL(
        fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
          "--store",
          in: args),
        isDirectory: true))
    let repositoryID = try TatwoUltraworkCLI.requiredOption(
      "--repository",
      in: args)
    let proposalID = try TatwoUltraworkCLI.requiredOption(
      "--proposal",
      in: args)
    let decidedBy = try TatwoUltraworkCLI.requiredOption(
      "--decided-by",
      in: args)
    let runtimeRoot = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
        "--runtime-root",
        in: args),
      isDirectory: true)
    guard isSafeSkilletIdentifier(repositoryID),
          isSafeSkilletIdentifier(proposalID),
          isSafeSkilletIdentifier(decidedBy)
    else {
      throw CLIError.usage(
        "--repository, --proposal and --decided-by must be safe Skillet identifiers")
    }
    let invariant: (
      result: TatwoMergeDecisionReceiptV1,
      before: TatwoSkilletRuntimeReadbackV1,
      after: TatwoSkilletRuntimeReadbackV1
    )
    do {
      invariant = try TatwoSkilletBundleTransport.preservingRuntimeRepository(
        runtimeRoot: runtimeRoot,
        repositoryID: repositoryID
      ) {
        if approve {
          return try store.approveMergeProposal(
            repositoryID: repositoryID,
            proposalID: proposalID,
            resolvedRevisionID: TatwoUltraworkCLI.option(
              "--resolved-revision",
              in: args),
            decidedBy: decidedBy)
        } else {
          guard TatwoUltraworkCLI.option("--resolved-revision", in: args) == nil else {
            throw CLIError.usage(
              "--resolved-revision is only valid with merge-approve")
          }
          return try store.rejectMergeProposal(
            repositoryID: repositoryID,
            proposalID: proposalID,
            decidedBy: decidedBy)
        }
      }
    } catch let error as TatwoSkilletRepositoryStoreError {
      switch error {
      case .unresolvedMergeConflicts:
        throw CLIError.mergeConflictUnresolved(error.localizedDescription)
      case .staleMergeProposal:
        throw CLIError.staleMergeProposal(error.localizedDescription)
      default:
        throw error
      }
    }
    let decision = invariant.result
    let output = TatwoSkilletMergeDecisionCLIOutputV1(
      schema: "TatwoSkilletMergeDecisionCLIOutputV1",
      repositoryID: repositoryID,
      proposalID: proposalID,
      status: decision.status.rawValue,
      resolvedRevisionID: decision.resolvedRevisionID,
      runtimeActivationState: invariant.before == invariant.after
        ? "unchanged"
        : "changed",
      runtimeBefore: invariant.before,
      runtimeAfter: invariant.after,
      decision: decision)
    if let receiptPath = TatwoUltraworkCLI.option("--receipt", in: args) {
      try writeJSON(output, to: URL(fileURLWithPath: receiptPath))
    }
    TatwoUltraworkCLI.output(
      output,
      command: approve ? "skillet merge-approve" : "skillet merge-reject")
  }

  private struct SetManifest: Decodable {
    let schemaVersion: Int
    let requestID: String
    let catalogRevision: String
    let authorityEpoch: UInt64
    let ledgerSequence: UInt64
    let sourceDeviceID: String
    let targetDeviceID: String
    let repositories: [SetRepository]
  }

  private struct SetRepository: Decodable {
    let repositoryID: String
    let revisionID: String
    let contentDigest: String
    let bundleDigest: String
    let bundleRelativePath: String
    let bindingRelativePath: String
  }

  private struct SetOperationInput {
    let requestID: String
    let sourceDeviceID: String
    let targetDeviceID: String
    let authorityEpoch: UInt64
    let ledgerSequence: UInt64
    let catalogRevision: String
    let inputs: [TatwoSkilletBoundBundleInputV1]
  }

  private static func setOperationInput(_ args: [String]) throws -> SetOperationInput {
    let setManifestURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption(
        "--set-manifest",
        in: args))
    let manifest = try makeDecoder().decode(
      SetManifest.self,
      from: Data(contentsOf: setManifestURL))
    let requestID = try TatwoUltraworkCLI.requiredOption("--request", in: args)
    let sourceDeviceID = try TatwoUltraworkCLI.requiredOption(
      "--source-device",
      in: args)
    let targetDeviceID = try TatwoUltraworkCLI.requiredOption(
      "--target-device",
      in: args)
    let authorityEpoch = try requiredUInt64("--authority-epoch", args: args)
    let ledgerSequence = try requiredUInt64("--ledger-sequence", args: args)
    let catalogRevision = try TatwoUltraworkCLI.requiredOption(
      "--catalog-revision",
      in: args)
    guard manifest.schemaVersion == 1,
          manifest.requestID == requestID,
          manifest.sourceDeviceID == sourceDeviceID,
          manifest.targetDeviceID == targetDeviceID,
          manifest.authorityEpoch == authorityEpoch,
          manifest.ledgerSequence == ledgerSequence,
          manifest.catalogRevision == catalogRevision
    else {
      throw CLIError.usage(
        "Skillet set manifest does not match the requested authority binding")
    }
    let repositoryIDs = manifest.repositories.map(\.repositoryID)
    guard repositoryIDs.allSatisfy(isSafeSkilletIdentifier),
          Set(repositoryIDs).count == repositoryIDs.count
    else {
      throw CLIError.usage(
        "Skillet set contains an unsafe or duplicate repository identifier")
    }
    let baseURL = setManifestURL.deletingLastPathComponent()
    let inputs = try manifest.repositories.map { repository in
      let expectedBundle = "repositories/\(repository.repositoryID)/bundle"
      let expectedBinding =
        "repositories/\(repository.repositoryID)/authority-binding.json"
      guard repository.bundleRelativePath == expectedBundle,
            repository.bindingRelativePath == expectedBinding
      else {
        throw CLIError.usage(
          "Skillet set contains an unsafe repository path: \(repository.repositoryID)")
      }
      let bundleURL = baseURL.appendingPathComponent(
        repository.bundleRelativePath,
        isDirectory: true)
      let bindingURL = baseURL.appendingPathComponent(
        repository.bindingRelativePath)
      let binding = try makeDecoder().decode(
        TatwoSkilletBundleAuthorityBindingV1.self,
        from: Data(contentsOf: bindingURL))
      return TatwoSkilletBoundBundleInputV1(
        repositoryID: repository.repositoryID,
        revisionID: repository.revisionID,
        contentDigest: repository.contentDigest,
        bundleDigest: repository.bundleDigest,
        bundleURL: bundleURL,
        binding: binding)
    }
    return SetOperationInput(
      requestID: requestID,
      sourceDeviceID: sourceDeviceID,
      targetDeviceID: targetDeviceID,
      authorityEpoch: authorityEpoch,
      ledgerSequence: ledgerSequence,
      catalogRevision: catalogRevision,
      inputs: inputs)
  }

  private struct BoundOperationInput {
    let bundleURL: URL
    let binding: TatwoSkilletBundleAuthorityBindingV1
    let requestID: String
    let sourceDeviceID: String
    let targetDeviceID: String
    let authorityEpoch: UInt64
    let ledgerSequence: UInt64
    let catalogRevision: String
  }

  private static func boundOperationInput(_ args: [String]) throws -> BoundOperationInput {
    let bundleURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--bundle", in: args),
      isDirectory: true)
    let bindingURL = URL(
      fileURLWithPath: try TatwoUltraworkCLI.requiredOption("--binding", in: args))
    return BoundOperationInput(
      bundleURL: bundleURL,
      binding: try makeDecoder().decode(
        TatwoSkilletBundleAuthorityBindingV1.self,
        from: Data(contentsOf: bindingURL)),
      requestID: try TatwoUltraworkCLI.requiredOption("--request", in: args),
      sourceDeviceID: try TatwoUltraworkCLI.requiredOption(
        "--source-device",
        in: args),
      targetDeviceID: try TatwoUltraworkCLI.requiredOption(
        "--target-device",
        in: args),
      authorityEpoch: try requiredUInt64("--authority-epoch", args: args),
      ledgerSequence: try requiredUInt64("--ledger-sequence", args: args),
      catalogRevision: try TatwoUltraworkCLI.requiredOption(
        "--catalog-revision",
        in: args))
  }

  private static func requiredUInt64(
    _ option: String,
    args: [String]
  ) throws -> UInt64 {
    let raw = try TatwoUltraworkCLI.requiredOption(option, in: args)
    guard let value = UInt64(raw), value > 0 else {
      throw CLIError.usage("\(option) must be a positive integer")
    }
    return value
  }

  private static func isSafeSkilletIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty,
          value != ".",
          value != "..",
          !value.hasPrefix("."),
          value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return false
    }
    return value.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 45, 46, 48...57, 65...90, 95, 97...122:
        true
      default:
        false
      }
    }
  }

  private static func aggregateActivationState(
    _ repositories: [TatwoSkilletSetRepositoryActivationCLIOutputV1]
  ) throws -> String {
    let active = TatwoSkillActivationStateV1.active.rawValue
    guard repositories.allSatisfy({ $0.activationState == active }) else {
      throw CLIError.usage(
        "Skillet set contains a repository that is not active after readback")
    }
    return active
  }

  private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try makeEncoder().encode(value).write(to: url, options: [.atomic])
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
