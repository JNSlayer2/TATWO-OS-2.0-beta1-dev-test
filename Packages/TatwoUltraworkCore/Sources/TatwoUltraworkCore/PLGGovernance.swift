import Foundation

public enum TatwoPLGGovernanceError:
  Error,
  Sendable,
  Equatable,
  Hashable
{
  case replayedEvent
  case revisionGap
  case illegalTransition(
    phase: TatwoPLGPhase,
    kind: TatwoPLGEventKind)
  case untrustedActor
  case contractMismatch
  case expired
  case badScope
  case missingReceipt
  case missingContract
  case missingGoal
  case goalMismatch
  case objectiveMismatch
  case receiptNotPersisted
}

public enum TatwoPLGGovernance {
  public static func executionTruth(
    run: TatwoPLGRun,
    dispatchRecords: [TatwoDispatchRecord] = []
  ) -> TatwoPLGExecutionTruthSummary {
    let ledger = TatwoDispatchRuntimeReducer.reduce(
      records: dispatchRecords,
      contractID: run.contractID)
    let queuedCount =
      ledger.queuedCount + ledger.deliveredCount + ledger.startedCount
    let runningCount = ledger.runningCount
    let failedCount = ledger.failedCount + ledger.cancelledCount
    let completedCount = ledger.completedCount
    let verifiedDispatchCount = ledger.verifiedCount
    let runtimeReceiptCount = ledger.runtimeReceiptCount
    let verifiedBranchCount = run.branchGoals.filter {
      TatwoPLGOrchestrator.branchPresentation(for: $0, in: run).isVerifiedPass
    }.count
    let plannedBranchCount = run.branchGoals.filter { $0.status == .planned }.count

    let state: TatwoPLGExecutionTruthState
    let headline: String
    let dispatchLabel: String
    let runtimeReceiptLabel: String
    let nextAction: String
    let countsAsRuntimeProgress: Bool

    if failedCount > 0 || (
      run.phase == .rollbackRequired && ledger.hasRuntimeEvidence
    ) {
      state = .blocked
      headline = "PLG 執行受阻"
      dispatchLabel = ledger.progressLabel
      runtimeReceiptLabel =
        runtimeReceiptCount == 0
        ? "無可放行的 runtime receipt"
        : "\(runtimeReceiptCount) 份 runtime receipt；失敗仍未解除"
      nextAction = "先處理失敗／rollback 原因，再以新 attempt 重派。"
      countsAsRuntimeProgress = true
    } else if runningCount > 0 {
      state = .running
      headline = "PLG 執行中"
      dispatchLabel = ledger.progressLabel
      runtimeReceiptLabel =
        runtimeReceiptCount == 0
        ? "無 runtime receipt；執行尚未 terminal"
        : "\(runtimeReceiptCount) 份 runtime receipt"
      nextAction = "等待 terminal output 與 verifier receipt；planned branches 不計入完成。"
      countsAsRuntimeProgress = true
    } else if queuedCount > 0 {
      state = .dispatched
      headline = "PLG \(ledger.headline)"
      dispatchLabel = ledger.progressLabel
      runtimeReceiptLabel =
        runtimeReceiptCount == 0
        ? "無 runtime receipt"
        : "\(runtimeReceiptCount) 份 runtime receipt"
      nextAction = "等待 runner 接受／開始；排隊、送達、啟動都不等於執行中。"
      countsAsRuntimeProgress = true
    } else if completedCount > 0 || verifiedDispatchCount > 0 {
      state = .receiptGated
      headline =
        completedCount > 0
        ? "PLG 已完成，等待驗收"
        : "PLG 已驗收"
      dispatchLabel = ledger.progressLabel
      runtimeReceiptLabel =
        runtimeReceiptCount == 0
        ? "無 runtime receipt；不可宣稱完成"
        : "\(runtimeReceiptCount) 份 runtime receipt，已驗證 branch \(verifiedBranchCount)"
      nextAction =
        verifiedDispatchCount > 0 && run.phase == .passed && runtimeReceiptCount > 0
        ? "保持 Goal Judge 證據鏈；App 只能呈現，不得自行 promotion。"
        : "補齊 branch receipt、mainline judge 與 Goal close 證據。"
      countsAsRuntimeProgress = true
    } else {
      state = run.phase == .planning ? .planningPreview : .notDispatched
      headline = "PLG 規劃預覽"
      dispatchLabel = "尚未派發；\(plannedBranchCount) 個 planned branches 不算 runtime 進度"
      runtimeReceiptLabel = "無 runtime receipt"
      nextAction =
        "先建立 contract-bound dispatch record；僅改 phase、branch row 或預估 receipt 數不算執行。"
      countsAsRuntimeProgress = false
    }

    return TatwoPLGExecutionTruthSummary(
      state: state,
      headline: headline,
      dispatchLabel: dispatchLabel,
      runtimeReceiptLabel: runtimeReceiptLabel,
      nextAction: nextAction,
      plannedBranchCount: plannedBranchCount,
      queuedDispatchCount: queuedCount,
      runningDispatchCount: runningCount,
      terminalDispatchCount: completedCount,
      verifiedDispatchCount: verifiedDispatchCount,
      failedDispatchCount: failedCount,
      verifiedBranchCount: verifiedBranchCount,
      runtimeReceiptCount: runtimeReceiptCount,
      countsAsRuntimeProgress: countsAsRuntimeProgress)
  }

  public static func validateStartContext(
    contractID: String?,
    goalID: String?,
    issuedGoalID: String,
    objective: String,
    issuedObjective: String
  ) -> Result<Void, TatwoPLGGovernanceError> {
    guard let contractID = normalized(contractID), !contractID.isEmpty else {
      return .failure(.missingContract)
    }
    guard
      let goalID = normalized(goalID),
      !goalID.isEmpty,
      let issuedGoalID = normalized(issuedGoalID),
      !issuedGoalID.isEmpty
    else {
      return .failure(.missingGoal)
    }
    guard goalID == issuedGoalID else {
      return .failure(.goalMismatch)
    }
    guard
      normalized(objective) == normalized(issuedObjective),
      normalized(objective)?.isEmpty == false
    else {
      return .failure(.objectiveMismatch)
    }
    return .success(())
  }

  public static func validateEvent(
    _ event: TatwoPLGEvent,
    appliedEventIDs: Set<UUID>,
    run: TatwoPLGRun
  ) -> Result<Void, TatwoPLGGovernanceError> {
    guard !appliedEventIDs.contains(event.eventID) else {
      return .failure(.replayedEvent)
    }
    guard event.atRevision == run.revision + 1 else {
      return .failure(.revisionGap)
    }
    guard isLegal(kind: event.kind, from: run.phase) else {
      return .failure(
        .illegalTransition(
          phase: run.phase,
          kind: event.kind))
    }
    return .success(())
  }

  public static func validateAuthReceipt(
    _ receipt: TatwoPLGHumanAuthReceipt,
    nowISO: String,
    contractID: String,
    allowedActors: Set<String>
  ) -> Result<Void, TatwoPLGGovernanceError> {
    guard !receipt.receiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(.missingReceipt)
    }
    guard allowedActors.contains(receipt.actor) else {
      return .failure(.untrustedActor)
    }
    guard receipt.contractID == contractID else {
      return .failure(.contractMismatch)
    }
    guard !receipt.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(.badScope)
    }
    guard
      let issued = parseISO8601(receipt.issuedISO),
      let now = parseISO8601(nowISO),
      let expires = parseISO8601(receipt.expiresISO),
      issued <= now,
      now < expires
    else {
      return .failure(.expired)
    }
    return .success(())
  }

  public static func validatePersistedAuthReceipt(
    _ receipt: TatwoPLGHumanAuthReceipt,
    persistedReceiptIDs: Set<String>,
    nowISO: String,
    contractID: String,
    allowedActors: Set<String>
  ) -> Result<Void, TatwoPLGGovernanceError> {
    let receiptID = receipt.receiptID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !receiptID.isEmpty, persistedReceiptIDs.contains(receiptID) else {
      return .failure(.receiptNotPersisted)
    }
    return validateAuthReceipt(
      receipt,
      nowISO: nowISO,
      contractID: contractID,
      allowedActors: allowedActors)
  }

  public static func canReuseIssuedContract(
    issuedObjective: String,
    requestedObjective: String,
    requireObjectiveMatch: Bool
  ) -> Bool {
    guard requireObjectiveMatch else { return true }
    guard
      let issued = normalized(issuedObjective),
      !issued.isEmpty,
      let requested = normalized(requestedObjective),
      !requested.isEmpty
    else {
      return false
    }
    return issued == requested
  }

  private static func isLegal(
    kind: TatwoPLGEventKind,
    from phase: TatwoPLGPhase
  ) -> Bool {
    if kind == .rollbackRequested {
      return true
    }

    switch phase {
    case .planning:
      return kind == .planningAdvanced
        || kind == .planningProjectionMigrated
    case .leadAdversarial:
      return kind == .adversarialConclusionSet
    case .awaitingHumanAuth:
      return kind == .humanAuthorized
    case .executingLoops:
      return kind == .branchReported
        || kind == .branchReplanned
        || kind == .branchEscalated
        || kind == .reportingAdvanced
    case .branchesReporting:
      return kind == .mainlineCheckAdvanced
    case .mainlineGoalCheck:
      return kind == .mainlineGoalEvaluated
    case .passed, .rollbackRequired:
      return false
    }
  }

  private static func parseISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func normalized(_ value: String?) -> String? {
    value.map(TatwoObjectiveIdentity.normalize)
  }
}

public enum TatwoPLGExecutionTruthState:
  String,
  Codable,
  Sendable,
  Equatable
{
  case planningPreview = "planning_preview"
  case notDispatched = "not_dispatched"
  case dispatched
  case running
  case receiptGated = "receipt_gated"
  case blocked
}

public struct TatwoPLGExecutionTruthSummary:
  Codable,
  Sendable,
  Equatable
{
  public let state: TatwoPLGExecutionTruthState
  public let headline: String
  public let dispatchLabel: String
  public let runtimeReceiptLabel: String
  public let nextAction: String
  public let plannedBranchCount: Int
  public let queuedDispatchCount: Int
  public let runningDispatchCount: Int
  public let terminalDispatchCount: Int
  public let verifiedDispatchCount: Int
  public let failedDispatchCount: Int
  public let verifiedBranchCount: Int
  public let runtimeReceiptCount: Int
  public let countsAsRuntimeProgress: Bool

  public init(
    state: TatwoPLGExecutionTruthState,
    headline: String,
    dispatchLabel: String,
    runtimeReceiptLabel: String,
    nextAction: String,
    plannedBranchCount: Int,
    queuedDispatchCount: Int,
    runningDispatchCount: Int,
    terminalDispatchCount: Int,
    verifiedDispatchCount: Int,
    failedDispatchCount: Int,
    verifiedBranchCount: Int,
    runtimeReceiptCount: Int,
    countsAsRuntimeProgress: Bool
  ) {
    self.state = state
    self.headline = headline
    self.dispatchLabel = dispatchLabel
    self.runtimeReceiptLabel = runtimeReceiptLabel
    self.nextAction = nextAction
    self.plannedBranchCount = plannedBranchCount
    self.queuedDispatchCount = queuedDispatchCount
    self.runningDispatchCount = runningDispatchCount
    self.terminalDispatchCount = terminalDispatchCount
    self.verifiedDispatchCount = verifiedDispatchCount
    self.failedDispatchCount = failedDispatchCount
    self.verifiedBranchCount = verifiedBranchCount
    self.runtimeReceiptCount = runtimeReceiptCount
    self.countsAsRuntimeProgress = countsAsRuntimeProgress
  }
}

public enum TatwoPLGExecutionFence {
  public static func permitsCompletion(
    capturedGeneration: UUID,
    currentGeneration: UUID,
    paused: Bool,
    capturedRunID: UUID,
    currentRun: TatwoPLGRun?,
    expectedPhase: TatwoPLGPhase
  ) -> Bool {
    capturedGeneration == currentGeneration
      && !paused
      && currentRun?.id == capturedRunID
      && currentRun?.phase == expectedPhase
  }
}

public struct TatwoPLGGatewayCompletionAttestation:
  Sendable,
  Equatable
{
  public let schema: String
  public let receiptID: String
  public let modelID: String
  public let dispatchID: String
  public let responseID: String
  public let terminalStatus: String
  public let outputSHA256: String
  public let signature: String

  public init(
    schema: String = "TatwoPLGGatewayCompletionAttestationV1",
    receiptID: String,
    modelID: String,
    dispatchID: String,
    responseID: String,
    terminalStatus: String,
    outputSHA256: String,
    signature: String
  ) {
    self.schema = schema
    self.receiptID = receiptID
    self.modelID = modelID
    self.dispatchID = dispatchID
    self.responseID = responseID
    self.terminalStatus = terminalStatus
    self.outputSHA256 = outputSHA256
    self.signature = signature
  }

  public static func signingMaterial(
    receiptID: String,
    modelID: String,
    dispatchID: String,
    responseID: String,
    terminalStatus: String,
    outputSHA256: String
  ) -> String {
    [
      "TatwoPLGGatewayCompletionAttestationV1",
      receiptID.trimmingCharacters(in: .whitespacesAndNewlines),
      modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      dispatchID.trimmingCharacters(in: .whitespacesAndNewlines),
      responseID.trimmingCharacters(in: .whitespacesAndNewlines),
      terminalStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      outputSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
    ].joined(separator: "\n")
  }

  public var signingMaterial: String {
    Self.signingMaterial(
      receiptID: receiptID,
      modelID: modelID,
      dispatchID: dispatchID,
      responseID: responseID,
      terminalStatus: terminalStatus,
      outputSHA256: outputSHA256)
  }
}

public enum TatwoPLGDispatchAssessment:
  Sendable,
  Equatable
{
  case passed(outputText: String)
  case blocked(reason: String)

  public static func assess(
    stdout: String,
    exitCode: Int32,
    expectedModelID: String,
    expectedDispatchID: String,
    trustedAttestation: TatwoPLGGatewayCompletionAttestation? = nil,
    gatewayAuthority: (any TatwoPLGAnchorAuthority)? = nil
  ) -> TatwoPLGDispatchAssessment {
    guard exitCode == 0 else {
      return .blocked(reason: "dispatch_exit_\(exitCode)")
    }

    var assistantText: [String] = []
    var sawTurnCompleted = false
    var completedResponseID: String?
    var blockedReason: String?
    let expectedModel = normalizedIdentity(expectedModelID)
    let expectedDispatch = expectedDispatchID
      .trimmingCharacters(in: .whitespacesAndNewlines)

    for rawLine in stdout.split(whereSeparator: \.isNewline) {
      guard
        let data = String(rawLine).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = object["type"] as? String
      else {
        continue
      }

      if type == "response.failed" {
        blockedReason = blockedReason ?? "response_failed"
        continue
      }

      if type == "item.completed",
         let item = object["item"] as? [String: Any],
         let itemType = item["type"] as? String,
         itemType == "agent_message",
         let itemID = item["id"] as? String,
         !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         let text = item["text"] as? String
      {
        let dispatchID = (object["dispatch_id"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard dispatchID == expectedDispatch else {
          blockedReason = blockedReason ?? "dispatch_mismatch"
          continue
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
          assistantText.append(normalized)
        }
        continue
      }

      guard type == "turn.completed" else { continue }
      if sawTurnCompleted {
        blockedReason = blockedReason ?? "multiple_turn_completed"
      }
      sawTurnCompleted = true
      let model = normalizedIdentity(object["model"] as? String ?? "")
      if model != expectedModel {
        blockedReason = blockedReason ?? "model_mismatch"
      }
      let dispatchID = (object["dispatch_id"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if dispatchID != expectedDispatch {
        blockedReason = blockedReason ?? "dispatch_mismatch"
      }
      let responseID = (object["response_id"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if responseID?.isEmpty != false {
        blockedReason = blockedReason ?? "missing_response_id"
      } else {
        completedResponseID = responseID
      }
      let degraded = object["degraded"] as? Bool ?? false
      let errorKind = (object["error_kind"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let errorKind, !errorKind.isEmpty {
        let resetAt = (object["reset_at"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let retryAllowed = object["retry_allowed"] as? Bool
        blockedReason = blockedReason ?? TatwoOperationalBlockerDescriptor(
          blockerClass: errorKind,
          resetAt: resetAt,
          retryAllowed: retryAllowed)
          .serializedReason
      } else if degraded {
        blockedReason = blockedReason ?? "degraded_completion"
      }
    }

    if let blockedReason {
      return .blocked(reason: blockedReason)
    }
    guard sawTurnCompleted else {
      return .blocked(reason: "missing_turn_completed")
    }
    let output = assistantText.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else {
      return .blocked(reason: "empty_model_output")
    }
    guard
      let trustedAttestation,
      let gatewayAuthority
    else {
      return .blocked(reason: "missing_gateway_attestation")
    }
    let attestedModel = normalizedIdentity(trustedAttestation.modelID)
    let attestedDispatch = trustedAttestation.dispatchID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let attestedResponse = trustedAttestation.responseID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let attestedStatus = trustedAttestation.terminalStatus
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let attestedDigest = trustedAttestation.outputSHA256
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard
      trustedAttestation.schema == "TatwoPLGGatewayCompletionAttestationV1",
      !trustedAttestation.receiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      attestedModel == expectedModel,
      attestedDispatch == expectedDispatch,
      attestedResponse == completedResponseID,
      attestedStatus == "completed",
      attestedDigest == TatwoArtifactReviewHasher.sha256(output).lowercased()
    else {
      return .blocked(reason: "gateway_attestation_mismatch")
    }
    guard
      (try? gatewayAuthority.verify(
        trustedAttestation.signature,
        material: trustedAttestation.signingMaterial)) == true
    else {
      return .blocked(reason: "gateway_attestation_signature_invalid")
    }
    return .passed(outputText: output)
  }

  private static func normalizedIdentity(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }
}

public enum TatwoPLGAppAuthority {
  public static let canCoordinateContractBoundDispatch = false
  public static let canWriteUnboundSharedDispatchLedger = false
  public static let canFinalizeGoal = false
}
