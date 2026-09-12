import Darwin
import Foundation
@_spi(TatwoBootstrapRecoveryHost) import TatwoUltraworkCore

struct TatwoGoalRevisionRecoveryPlanCLIOutputV1: Encodable {
  let schema = "TatwoGoalRevisionRecoveryPlanCLIOutputV1"
  let mutationPerformed = false
  let candidateOnly = true
  let callerSuppliedEvidenceTrusted = false
  let trustedHumanConfirmationPresent = false
  let readyForFreshAdminEnrollment = false
  let requiresFreshRootAdminInteractiveReview = true
  let adminMustRereadSourceFiles = true
  let challengeID: String
  let receiptID: String
  let authorizationID: String
  let grantID: String
  let shortCode: String
  let targetPath: String
  let grantBodyDigest: String
  let grantFileDigest: String
  let grantByteCount: Int
  let canonicalGrantBase64: String
  let humanMessageSourcePath: String
  let humanMessageByteCount: Int
  let humanMessageDigest: String
  let legacyUnavailableEvidenceSourcePath: String
  let legacyUnavailableEvidenceByteCount: Int
  let legacyUnavailableEvidenceDigest: String
  let canonicalCurrentSession: TatwoSessionPointer
  let canonicalPredecessorGoal: TatwoStoredGoalRun
  let canonicalSuccessorGoal: TatwoStoredGoalRun
  let sessionID: String
  let oldPointerRevisionDigest: String
  let oldPointerGeneration: UInt64
  let oldContractID: String
  let oldGoalID: String
  let oldGoalRevision: UInt64
  let oldReceiptsDigest: String
  let newContractID: String
  let newGoalID: String
  let newGoalRevision: UInt64
  let topologyDigest: String
  let capabilityDigest: String
  let requestedHostScopeDigest: String
  let issuedAt: Date
  let expiresAt: Date
  let allowedOperations: [String]
  let deniedOperations: [String]
  let nextHumanGate: String
}

enum TatwoGoalRevisionRecoveryCLI {
  static func enroll(_ args: [String]) throws {
    if args.contains("--help") || args.contains("-h") {
      print(
        "Usage: tatwo-ultrawork os session revision-recovery-enroll "
          + "--successor <planned-contract-id> --thread-id <thread> "
          + "--turn-id <turn> --event-id <user-event> "
          + "--human-message-file <absolute-path> "
          + "--legacy-unavailable-evidence-file <absolute-path> "
          + "--legacy-app-version <version> --legacy-app-build <build> "
          + "--device-id <device> [--ttl-seconds 600] --json")
      return
    }
    let successorContractID =
      try TatwoUltraworkCLI.requiredAnyOption(
        ["--successor", "--successor-contract"],
        in: args)
    let threadID =
      try TatwoUltraworkCLI.requiredOption("--thread-id", in: args)
    let turnID =
      try TatwoUltraworkCLI.requiredOption("--turn-id", in: args)
    let eventID =
      try TatwoUltraworkCLI.requiredOption("--event-id", in: args)
    let humanMessageFile =
      try TatwoUltraworkCLI.requiredOption(
        "--human-message-file", in: args)
    let legacyEvidenceFile =
      try TatwoUltraworkCLI.requiredOption(
        "--legacy-unavailable-evidence-file", in: args)
    let legacyAppVersion =
      try TatwoUltraworkCLI.requiredOption(
        "--legacy-app-version", in: args)
    let legacyAppBuild =
      try TatwoUltraworkCLI.requiredOption(
        "--legacy-app-build", in: args)
    let deviceID =
      try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let ttlRaw =
      TatwoUltraworkCLI.option("--ttl-seconds", in: args) ?? "600"
    guard let ttl = UInt64(ttlRaw), ttl > 0, ttl <= 30 * 60 else {
      throw CLIError.usage(
        "--ttl-seconds must be an integer between 1 and 1800")
    }
    let result =
      try TatwoGoalRevisionRootAdminEnrollment.enrollProduction(
        request: TatwoGoalRevisionRootAdminEnrollmentRequestV1(
          successorContractID: successorContractID,
          threadID: threadID,
          turnID: turnID,
          eventID: eventID,
          humanMessageSourcePath: humanMessageFile,
          legacyUnavailableEvidenceSourcePath: legacyEvidenceFile,
          legacyAppVersion: legacyAppVersion,
          legacyAppBuild: legacyAppBuild,
          deviceID: deviceID,
          ttlSeconds: ttl))
    TatwoUltraworkCLI.output(
      result,
      command: "os session revision-recovery-enroll")
  }

  static func preparePlan(_ args: [String]) throws {
    if args.contains("--help") || args.contains("-h") {
      print(
        "Usage: tatwo-ultrawork os session revision-recovery-plan "
          + "--successor <planned-contract-id> --thread-id <thread> "
          + "--turn-id <turn> --event-id <user-event> "
          + "--human-message-file <absolute-path> "
          + "--legacy-unavailable-evidence-file <absolute-path> "
          + "--legacy-app-version <version> --legacy-app-build <build> "
          + "--device-id <device> [--ttl-seconds 600] --json")
      return
    }
    let successorContractID =
      try TatwoUltraworkCLI.requiredAnyOption(
        ["--successor", "--successor-contract"],
        in: args)
    let threadID =
      try TatwoUltraworkCLI.requiredOption("--thread-id", in: args)
    let turnID =
      try TatwoUltraworkCLI.requiredOption("--turn-id", in: args)
    let eventID =
      try TatwoUltraworkCLI.requiredOption("--event-id", in: args)
    let humanMessageFile =
      try TatwoUltraworkCLI.requiredOption(
        "--human-message-file", in: args)
    let legacyEvidenceFile =
      try TatwoUltraworkCLI.requiredOption(
        "--legacy-unavailable-evidence-file", in: args)
    let legacyAppVersion =
      try TatwoUltraworkCLI.requiredOption(
        "--legacy-app-version", in: args)
    let legacyAppBuild =
      try TatwoUltraworkCLI.requiredOption(
        "--legacy-app-build", in: args)
    let deviceID =
      try TatwoUltraworkCLI.requiredOption("--device-id", in: args)
    let ttlRaw =
      TatwoUltraworkCLI.option("--ttl-seconds", in: args) ?? "600"
    guard let ttl = TimeInterval(ttlRaw),
      ttl > 0,
      ttl <= 30 * 60
    else {
      throw CLIError.usage(
        "--ttl-seconds must be between 1 and 1800")
    }
    let issuedAt = Date()
    let humanMessageURL = URL(fileURLWithPath: humanMessageFile)
      .standardizedFileURL
    let legacyEvidenceURL = URL(fileURLWithPath: legacyEvidenceFile)
      .standardizedFileURL
    let humanMessage = try Data(contentsOf: humanMessageURL)
    let legacyUnavailableEvidence = try Data(
      contentsOf: legacyEvidenceURL)
    let goalStore = TatwoGoalRunStore.default()
    let sessionStore = TatwoSessionStore(
      directoryURL: goalStore.directoryURL)
    let plan =
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input:
          TatwoGoalRevisionBootstrapRecoveryChallengeInputV1(
            successorContractID: successorContractID,
            threadID: threadID,
            turnID: turnID,
            eventID: eventID,
            humanMessage: humanMessage,
            legacyAppVersion: legacyAppVersion,
            legacyAppBuild: legacyAppBuild,
            legacyUnavailableEvidence: legacyUnavailableEvidence,
            deviceID: deviceID,
            localUserUID: UInt32(getuid()),
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(ttl)),
        goalStore: goalStore,
        sessionStore: sessionStore,
        dispatchRegistry: TatwoDispatchRegistry(
          directoryURL: goalStore.directoryURL))
    let evidence = plan.evidence
    guard let currentSession = try sessionStore.snapshotCurrent(),
      currentSession.revision.digest
        == evidence.oldPointerRevisionDigest,
      currentSession.pointer.contractID == evidence.oldContractID,
      currentSession.pointer.goalID == evidence.oldGoalID
    else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .stateChangedDuringPreparation
    }
    let predecessor = try goalStore.requireIssuedContract(
      evidence.oldContractID)
    let successor = try goalStore.requireIssuedContract(
      evidence.newContractID)
    guard predecessor.status == .running,
      predecessor.goalID == evidence.oldGoalID,
      predecessor.resolvedRevision == evidence.oldGoalRevision,
      TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
        predecessor.objective) == evidence.oldObjectiveDigest,
      TatwoGoalRevisionPromotionAuthorizationV1.receiptsDigest(
        predecessor.receipts) == evidence.oldReceiptsDigest,
      successor.status == .planned,
      successor.goalID == evidence.newGoalID,
      TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
        successor.objective) == evidence.newObjectiveDigest
    else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .stateChangedDuringPreparation
    }
    TatwoUltraworkCLI.output(
      TatwoGoalRevisionRecoveryPlanCLIOutputV1(
        challengeID: evidence.challengeID,
        receiptID: evidence.id,
        authorizationID: evidence.authorizationID,
        grantID: evidence.grantID,
        shortCode: evidence.shortCode,
        targetPath: plan.targetPath,
        grantBodyDigest: plan.grant.bodyDigest,
        grantFileDigest: plan.grantFileDigest,
        grantByteCount: plan.canonicalGrantBytes.count,
        canonicalGrantBase64:
          plan.canonicalGrantBytes.base64EncodedString(),
        humanMessageSourcePath: humanMessageURL.path,
        humanMessageByteCount: humanMessage.count,
        humanMessageDigest: evidence.humanMessageDigest,
        legacyUnavailableEvidenceSourcePath:
          legacyEvidenceURL.path,
        legacyUnavailableEvidenceByteCount:
          legacyUnavailableEvidence.count,
        legacyUnavailableEvidenceDigest:
          evidence.legacyUnavailableEvidenceDigest,
        canonicalCurrentSession: currentSession.pointer,
        canonicalPredecessorGoal: predecessor,
        canonicalSuccessorGoal: successor,
        sessionID: evidence.sessionID,
        oldPointerRevisionDigest:
          evidence.oldPointerRevisionDigest,
        oldPointerGeneration: evidence.oldPointerGeneration,
        oldContractID: evidence.oldContractID,
        oldGoalID: evidence.oldGoalID,
        oldGoalRevision: evidence.oldGoalRevision,
        oldReceiptsDigest: evidence.oldReceiptsDigest,
        newContractID: evidence.newContractID,
        newGoalID: evidence.newGoalID,
        newGoalRevision: evidence.newGoalRevision,
        topologyDigest: evidence.topologyDigest,
        capabilityDigest: evidence.capabilityDigest,
        requestedHostScopeDigest:
          evidence.requestedHostScopeDigest,
        issuedAt: evidence.issuedAt,
        expiresAt: evidence.expiresAt,
        allowedOperations: evidence.allowedOperations,
        deniedOperations: evidence.deniedOperations,
        nextHumanGate:
          "DO NOT write this candidate yet. A fresh macOS admin enrollment "
          + "must reopen the two source files without following symlinks, "
          + "recompute both digests, display and review their complete UTF-8 "
          + "contents plus the full canonical old/new Goal diff, verify the "
          + "grant file digest and short code through /dev/tty, then write "
          + "only this exact canonical byte sequence to the fixed root-owned "
          + "target path."
      ),
      command: "os session revision-recovery-plan")
  }
}
