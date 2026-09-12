import Foundation

public enum TatwoPLGPhase:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  case planning
  case leadAdversarial
  case awaitingHumanAuth
  case executingLoops
  case branchesReporting
  case mainlineGoalCheck
  case passed
  case rollbackRequired
}

public struct TatwoPLGHumanAuthReceipt:
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  public var receiptID: String
  public var actor: String
  public var issuedISO: String
  public var expiresISO: String
  public var scope: String
  public var contractID: String

  public init(
    receiptID: String,
    actor: String,
    issuedISO: String,
    expiresISO: String,
    scope: String,
    contractID: String
  ) {
    self.receiptID = receiptID
    self.actor = actor
    self.issuedISO = issuedISO
    self.expiresISO = expiresISO
    self.scope = scope
    self.contractID = contractID
  }
}

public enum TatwoPLGDomain:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable,
  CaseIterable
{
  case ui
  case code
  case debug
  case research
  case modeling
  case ops

  public init?(workOSDomain: WorkOSDomainKind) {
    self.init(rawValue: workOSDomain.rawValue)
  }

  public var workOSDomain: WorkOSDomainKind {
    WorkOSDomainKind(rawValue: rawValue)!
  }

  public var plainName: String {
    workOSDomain.plainName
  }
}

public enum TatwoPLGDomainVerdict:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  case pass
  case blocked
  case fail
}

public enum TatwoPLGReceiptPresentation:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  case pass
  case fail
  case blocked
}

public enum TatwoPLGAuthorityProvenance:
  String,
  Sendable,
  Equatable,
  Hashable
{
  case untrustedSnapshot
  case liveTransition
  case verifiedReplay
}

public struct TatwoPLGBranchPresentation:
  Sendable,
  Equatable,
  Hashable
{
  public let receipt: TatwoPLGReceiptPresentation
  public let visualStatus: TatwoLoopsStatus
  public let isVerifiedPass: Bool

  public init(
    receipt: TatwoPLGReceiptPresentation,
    visualStatus: TatwoLoopsStatus,
    isVerifiedPass: Bool
  ) {
    self.receipt = receipt
    self.visualStatus = visualStatus
    self.isVerifiedPass = isVerifiedPass
  }
}

public struct TatwoPLGDomainReceipt:
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  public var domainLoopID: String
  public var objectiveHash: String
  public var inputsDigest: String
  public var artifactsDigest: String
  public var verdict: TatwoPLGDomainVerdict
  public var testsRun: [String]

  public init(
    domainLoopID: String,
    objectiveHash: String,
    inputsDigest: String,
    artifactsDigest: String,
    verdict: TatwoPLGDomainVerdict,
    testsRun: [String]
  ) {
    self.domainLoopID = domainLoopID
    self.objectiveHash = objectiveHash
    self.inputsDigest = inputsDigest
    self.artifactsDigest = artifactsDigest
    self.verdict = verdict
    self.testsRun = testsRun
  }
}

public struct TatwoPLGBranchGoal:
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  public var id: UUID
  public var objective: String
  public var subLabel: String
  public var subBindingID: String
  public var status: TatwoLoopsStatus
  public var reason: String?
  public var attempt: Int
  public var maxAttempts: Int
  public var deadlineISO: String?
  public var reportedToMainline: Bool
  public var escalated: Bool
  public var domainLoopID: String?
  public var domain: TatwoPLGDomain?
  public var sourceLoopID: String?
  public var ownerIdentity: IdentityKind?
  public var planSlice: String?
  public var domainReceipt: TatwoPLGDomainReceipt?
  public private(set) var authorityRevision: Int?
  public private(set) var authoritySeal: String?

  public init(
    id: UUID = UUID(),
    objective: String,
    subLabel: String,
    subBindingID: String,
    status: TatwoLoopsStatus,
    reason: String?,
    attempt: Int,
    deadlineISO: String?,
    reportedToMainline: Bool,
    maxAttempts: Int = 3,
    escalated: Bool = false,
    domainLoopID: String? = nil,
    domain: TatwoPLGDomain? = nil,
    sourceLoopID: String? = nil,
    ownerIdentity: IdentityKind? = nil,
    planSlice: String? = nil,
    domainReceipt: TatwoPLGDomainReceipt? = nil
  ) {
    self.id = id
    self.objective = objective
    self.subLabel = subLabel
    self.subBindingID = subBindingID
    self.status = status
    self.reason = reason
    self.attempt = attempt
    self.maxAttempts = maxAttempts
    self.deadlineISO = deadlineISO
    self.reportedToMainline = reportedToMainline
    self.escalated = escalated
    self.domainLoopID = domainLoopID
    self.domain = domain
    self.sourceLoopID = sourceLoopID
    self.ownerIdentity = ownerIdentity
    self.planSlice = planSlice
    self.domainReceipt = domainReceipt
    self.authorityRevision = nil
    self.authoritySeal = nil
  }

  private enum CodingKeys: String, CodingKey {
    case id, objective, subLabel, subBindingID, status, reason, attempt
    case maxAttempts, deadlineISO, reportedToMainline, escalated
    case domainLoopID, domain, sourceLoopID, ownerIdentity, planSlice
    case domainReceipt, authorityRevision, authoritySeal
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    self.objective = try c.decode(String.self, forKey: .objective)
    self.subLabel = try c.decode(String.self, forKey: .subLabel)
    self.subBindingID = try c.decode(String.self, forKey: .subBindingID)
    self.status = try c.decode(TatwoLoopsStatus.self, forKey: .status)
    self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
    self.attempt = try c.decode(Int.self, forKey: .attempt)
    self.maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 3
    self.deadlineISO = try c.decodeIfPresent(String.self, forKey: .deadlineISO)
    self.reportedToMainline =
      try c.decodeIfPresent(Bool.self, forKey: .reportedToMainline) ?? false
    self.escalated =
      try c.decodeIfPresent(Bool.self, forKey: .escalated) ?? false
    self.domainLoopID =
      try c.decodeIfPresent(String.self, forKey: .domainLoopID)
    self.domain = try c.decodeIfPresent(TatwoPLGDomain.self, forKey: .domain)
    self.sourceLoopID =
      try c.decodeIfPresent(String.self, forKey: .sourceLoopID)
    self.ownerIdentity =
      try c.decodeIfPresent(IdentityKind.self, forKey: .ownerIdentity)
    self.planSlice = try c.decodeIfPresent(String.self, forKey: .planSlice)
    self.domainReceipt =
      try c.decodeIfPresent(TatwoPLGDomainReceipt.self, forKey: .domainReceipt)
    self.authorityRevision =
      try c.decodeIfPresent(Int.self, forKey: .authorityRevision)
    self.authoritySeal =
      try c.decodeIfPresent(String.self, forKey: .authoritySeal)

    let completePolicyDIdentity =
      nonEmpty(sourceLoopID) != nil
      && ownerIdentity != nil
      && nonEmpty(domainLoopID) != nil
      && nonEmpty(planSlice) != nil
      && (domain != nil || isBlockedUnsupportedDomainProjection)
    let receiptSelfConsistent = domainReceipt.map {
      TatwoPLGOrchestrator.receiptPayloadMatchesBranch($0, branch: self)
    } ?? true
    let receiptAuthorityShapeValid =
      domainReceipt == nil
      || (
        authorityRevision != nil
          && nonEmpty(authoritySeal) != nil)
    let authorityShapeValid =
      (
        !reportedToMainline
          && status != .passed
          && receiptAuthorityShapeValid)
      || (
        reportedToMainline
          && status == .passed
          && domainReceipt?.verdict == .pass
          && receiptSelfConsistent
          && authorityRevision != nil
          && nonEmpty(authoritySeal) != nil)

    let decodedAuthorityBearing =
      domainReceipt != nil
      || authorityRevision != nil
      || nonEmpty(authoritySeal) != nil
      || reportedToMainline
      || status == .passed

    if decodedAuthorityBearing {
      quarantinePolicyD(
        "Policy D migration quarantine：untrusted decoded authority requires anchored replay")
    } else if !completePolicyDIdentity
      || !receiptSelfConsistent
      || !receiptAuthorityShapeValid
      || !authorityShapeValid
    {
      quarantinePolicyD(
        "Policy D migration quarantine：legacy/incomplete/forged branch snapshot")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(objective, forKey: .objective)
    try c.encode(subLabel, forKey: .subLabel)
    try c.encode(subBindingID, forKey: .subBindingID)
    try c.encode(status, forKey: .status)
    try c.encodeIfPresent(reason, forKey: .reason)
    try c.encode(attempt, forKey: .attempt)
    try c.encode(maxAttempts, forKey: .maxAttempts)
    try c.encodeIfPresent(deadlineISO, forKey: .deadlineISO)
    try c.encode(reportedToMainline, forKey: .reportedToMainline)
    try c.encode(escalated, forKey: .escalated)
    try c.encodeIfPresent(domainLoopID, forKey: .domainLoopID)
    try c.encodeIfPresent(domain, forKey: .domain)
    try c.encodeIfPresent(sourceLoopID, forKey: .sourceLoopID)
    try c.encodeIfPresent(ownerIdentity, forKey: .ownerIdentity)
    try c.encodeIfPresent(planSlice, forKey: .planSlice)
    try c.encodeIfPresent(domainReceipt, forKey: .domainReceipt)
    try c.encodeIfPresent(authorityRevision, forKey: .authorityRevision)
    try c.encodeIfPresent(authoritySeal, forKey: .authoritySeal)
  }

  fileprivate mutating func setAuthority(
    revision: Int,
    seal: String
  ) {
    authorityRevision = revision
    authoritySeal = seal
  }

  fileprivate mutating func clearAuthority() {
    authorityRevision = nil
    authoritySeal = nil
  }

  fileprivate mutating func quarantinePolicyD(_ message: String) {
    status = .blocked
    reason = message
    reportedToMainline = false
    escalated = false
    domainReceipt = nil
    clearAuthority()
  }

  fileprivate var isBlockedUnsupportedDomainProjection: Bool {
    domain == nil
      && isBlockedStructuralPolicyDProjection
      && reason?.localizedCaseInsensitiveContains("unsupported domain") == true
  }

  fileprivate var isBlockedStructuralPolicyDProjection: Bool {
    let structuralDiagnostics = [
      "unsupported domain",
      "unassigned ownerIdentity",
      "ambiguous ownerIdentity",
      "duplicate source loop ID",
      "duplicate generated domainLoopID",
    ]
    return status == .blocked
      && !reportedToMainline
      && domainReceipt == nil
      && authorityRevision == nil
      && nonEmpty(authoritySeal) == nil
      && structuralDiagnostics.contains {
        reason?.localizedCaseInsensitiveContains($0) == true
      }
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let normalized = value?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !normalized.isEmpty
    else {
      return nil
    }
    return normalized
  }
}

public struct TatwoPLGRun: Codable, Sendable, Equatable, Hashable {
  public var id: UUID
  public var goalID: String
  public var contractID: String
  public var revision: Int
  public var phase: TatwoPLGPhase
  public var leadBindings: [WorkOSIdentityBinding]
  public var subBindings: [WorkOSIdentityBinding]
  public var planSummary: String
  public var adversarialConclusion: String?
  public var humanAuth: TatwoPLGHumanAuthReceipt?
  public var branchGoals: [TatwoPLGBranchGoal]
  public var mainlineGoalMet: Bool?
  public private(set) var authorityProvenance: TatwoPLGAuthorityProvenance

  public var isMultiLead: Bool {
    leadBindings.filter { $0.identity == .lead }.count > 1
  }

  public var hasTrustedAuthority: Bool {
    authorityProvenance == .liveTransition
      || authorityProvenance == .verifiedReplay
  }

  public init(
    id: UUID = UUID(),
    goalID: String,
    contractID: String,
    revision: Int,
    phase: TatwoPLGPhase,
    leadBindings: [WorkOSIdentityBinding],
    subBindings: [WorkOSIdentityBinding],
    planSummary: String,
    adversarialConclusion: String?,
    humanAuth: TatwoPLGHumanAuthReceipt?,
    branchGoals: [TatwoPLGBranchGoal],
    mainlineGoalMet: Bool?
  ) {
    self.id = id
    self.goalID = goalID
    self.contractID = contractID
    self.revision = revision
    self.phase = phase
    self.leadBindings = leadBindings
    self.subBindings = subBindings
    self.planSummary = planSummary
    self.adversarialConclusion = adversarialConclusion
    self.humanAuth = humanAuth
    self.branchGoals = branchGoals
    self.mainlineGoalMet = mainlineGoalMet
    self.authorityProvenance = .untrustedSnapshot
  }

  private enum CodingKeys: String, CodingKey {
    case id, goalID, contractID, revision, phase, leadBindings, subBindings
    case planSummary, adversarialConclusion, humanAuth, branchGoals
    case mainlineGoalMet
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(UUID.self, forKey: .id),
      goalID: try c.decode(String.self, forKey: .goalID),
      contractID: try c.decode(String.self, forKey: .contractID),
      revision: try c.decode(Int.self, forKey: .revision),
      phase: try c.decode(TatwoPLGPhase.self, forKey: .phase),
      leadBindings: try c.decode(
        [WorkOSIdentityBinding].self,
        forKey: .leadBindings),
      subBindings: try c.decode(
        [WorkOSIdentityBinding].self,
        forKey: .subBindings),
      planSummary: try c.decode(String.self, forKey: .planSummary),
      adversarialConclusion: try c.decodeIfPresent(
        String.self,
        forKey: .adversarialConclusion),
      humanAuth: try c.decodeIfPresent(
        TatwoPLGHumanAuthReceipt.self,
        forKey: .humanAuth),
      branchGoals: try c.decode(
        [TatwoPLGBranchGoal].self,
        forKey: .branchGoals),
      mainlineGoalMet: try c.decodeIfPresent(
        Bool.self,
        forKey: .mainlineGoalMet))
    self = TatwoPLGOrchestrator.quarantinedSnapshot(self)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(goalID, forKey: .goalID)
    try c.encode(contractID, forKey: .contractID)
    try c.encode(revision, forKey: .revision)
    try c.encode(phase, forKey: .phase)
    try c.encode(leadBindings, forKey: .leadBindings)
    try c.encode(subBindings, forKey: .subBindings)
    try c.encode(planSummary, forKey: .planSummary)
    try c.encodeIfPresent(adversarialConclusion, forKey: .adversarialConclusion)
    try c.encodeIfPresent(humanAuth, forKey: .humanAuth)
    try c.encode(branchGoals, forKey: .branchGoals)
    try c.encodeIfPresent(mainlineGoalMet, forKey: .mainlineGoalMet)
  }

  public static func == (
    lhs: TatwoPLGRun,
    rhs: TatwoPLGRun
  ) -> Bool {
    lhs.id == rhs.id
      && lhs.goalID == rhs.goalID
      && lhs.contractID == rhs.contractID
      && lhs.revision == rhs.revision
      && lhs.phase == rhs.phase
      && lhs.leadBindings == rhs.leadBindings
      && lhs.subBindings == rhs.subBindings
      && lhs.planSummary == rhs.planSummary
      && lhs.adversarialConclusion == rhs.adversarialConclusion
      && lhs.humanAuth == rhs.humanAuth
      && lhs.branchGoals == rhs.branchGoals
      && lhs.mainlineGoalMet == rhs.mainlineGoalMet
  }

  mutating func markLiveTransition() {
    authorityProvenance = .liveTransition
  }

  mutating func markVerifiedReplay(headHash: String) {
    guard !headHash.isEmpty else { return }
    authorityProvenance = .verifiedReplay
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(goalID)
    hasher.combine(contractID)
    hasher.combine(revision)
    hasher.combine(phase)
    hash(bindings: leadBindings, into: &hasher)
    hash(bindings: subBindings, into: &hasher)
    hasher.combine(planSummary)
    hasher.combine(adversarialConclusion)
    hasher.combine(humanAuth)
    hasher.combine(branchGoals)
    hasher.combine(mainlineGoalMet)
  }

  private func hash(
    bindings: [WorkOSIdentityBinding],
    into hasher: inout Hasher
  ) {
    hasher.combine(bindings.count)
    for binding in bindings {
      hasher.combine(binding.id)
      hasher.combine(binding.identity.rawValue)
      hasher.combine(binding.label)
      hasher.combine(binding.engineID)
      hasher.combine(binding.modelID)
      hasher.combine(binding.authority.rawValue)
      hasher.combine(binding.canMutateHost)
      hasher.combine(binding.sourceSlotID)
      hasher.combine(binding.bindingRule)
    }
  }
}

public enum TatwoPLGPolicyDProjector {
  public static func project(
    run: TatwoPLGRun,
    contract: TatwoWorkOSContractV1,
    goalRecord: TatwoStoredGoalRun?
  ) -> TatwoPLGRun {
    guard contract.contractID == run.contractID,
          contract.goalID == run.goalID
    else {
      return run
    }

    let sourceCounts = Dictionary(
      grouping: contract.domainLoops,
      by: \.id)
      .mapValues(\.count)
    let generatedIDs = contract.domainLoops.map { loop in
      TatwoPLGOrchestrator.makeDomainLoopID(
        contractID: contract.contractID,
        domainRawValue: loop.domain.rawValue,
        sourceLoopID: loop.id)
    }
    let generatedCounts = Dictionary(
      grouping: generatedIDs,
      by: { $0 })
      .mapValues(\.count)
    let submittedReceiptIDs = goalRecord?.submittedReceiptIDs ?? []

    var projected = run
    projected.leadBindings = contract.identityBindings
      .filter { $0.identity == .lead }
      .sorted { $0.id < $1.id }
    projected.subBindings = contract.identityBindings
      .filter { $0.identity != .lead }
      .sorted { $0.id < $1.id }
    projected.branchGoals = contract.domainLoops.map { loop in
      let domain = TatwoPLGDomain(workOSDomain: loop.domain)
      let domainLoopID = TatwoPLGOrchestrator.makeDomainLoopID(
        contractID: contract.contractID,
        domainRawValue: loop.domain.rawValue,
        sourceLoopID: loop.id)
      let matches = contract.identityBindings
        .filter { $0.identity == loop.ownerIdentity }
      let affinityMatches = loop.ownerSourceSlotID.map { sourceSlotID in
        matches.filter { $0.sourceSlotID == sourceSlotID }
      }
      let binding = affinityMatches.map {
        $0.count == 1 ? $0[0] : nil
      } ?? (matches.count == 1 ? matches[0] : nil)
      let receiptPolicyDigest = TatwoArtifactReviewHasher.sha256(
        loop.requiredReceipts
          .sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.title < rhs.title
          }
          .map {
            [
              $0.id,
              $0.title,
              $0.kind,
              $0.requiredForPass ? "required" : "optional",
              $0.plainPurpose
            ].joined(separator: "|")
          }
          .joined(separator: "\n"))
      let planSlice = [
        "[\(loop.domain.rawValue)] \(loop.title)",
        "cycle: \(loop.cycleIndex)",
        loop.autonomyLevel,
        "merge: \(loop.mergeBackRule)",
        "owner-source-slot: \(loop.ownerSourceSlotID ?? "unassigned")",
        "receipt-policy: \(receiptPolicyDigest)"
      ].joined(separator: "\n")
      let requiredReceiptIDs = loop.requiredReceipts
        .filter(\.requiredForPass)
        .map(\.id)
      let hasMetadataOnlyEvidence =
        !requiredReceiptIDs.isEmpty
        && requiredReceiptIDs.allSatisfy(submittedReceiptIDs.contains)
      var diagnostics: [String] = []
      var structuralBlocker = false
      var duplicateIdentityBlocker = false

      if sourceCounts[loop.id, default: 0] > 1 {
        structuralBlocker = true
        duplicateIdentityBlocker = true
        diagnostics.append(
          "duplicate source loop ID：\(loop.id)；Policy D blocked。")
      }
      if generatedCounts[domainLoopID, default: 0] > 1 {
        structuralBlocker = true
        duplicateIdentityBlocker = true
        diagnostics.append(
          "duplicate generated domainLoopID：\(domainLoopID)；Policy D blocked。")
      }
      if domain == nil {
        structuralBlocker = true
        diagnostics.append(
          "unsupported domain：\(loop.domain.rawValue)；loop 保留顯示但不可回報。")
      }
      if binding == nil {
        structuralBlocker = true
        if let sourceSlotID = loop.ownerSourceSlotID {
          diagnostics.append(
            "owner source slot affinity 無法唯一解析：\(sourceSlotID)；Policy D blocked。")
        } else if matches.isEmpty {
          diagnostics.append(
            "unassigned ownerIdentity：\(loop.ownerIdentity.rawValue)；Policy D blocked。")
        } else if matches.count > 1 {
          diagnostics.append(
            "ambiguous ownerIdentity：\(loop.ownerIdentity.rawValue) 有 \(matches.count) 個 bindings；Policy D blocked。")
        } else {
          diagnostics.append(
            "ownerIdentity：\(loop.ownerIdentity.rawValue) 沒有已簽發且啟用的 loops binding；Policy D blocked。")
        }
      }
      if hasMetadataOnlyEvidence {
        diagnostics.append(
          "metadata-only receipts 不具 PASS 權威；等待 canonical validator-issued payload。")
      }
      if loop.status == .passed || loop.status == .succeeded {
        diagnostics.append(
          "Work OS 狀態缺少 canonical Domain receipt；不可投影成 PASS。")
      }

      let status: TatwoLoopsStatus
      if !diagnostics.isEmpty {
        status = .blocked
      } else {
        switch loop.status {
        case .running, .dispatching:
          status = .running
        case .blocked, .failed, .cancelled, .rollbackRequired, .superseded:
          status = .blocked
        case .planned, .humanGate, .awaitingNextCycle, .passed, .succeeded:
          status = .planned
        }
      }
      let domainName = domain?.plainName ?? loop.domain.plainName
      let matchingExisting = projected.branchGoals.first {
        sameProjectionIdentity(
          $0,
          loop: loop,
          domain: domain,
          bindingID: binding?.id,
          planSlice: planSlice,
          contractID: contract.contractID)
      }
      let failureStatus =
        loop.status == .blocked
        || loop.status == .failed
        || loop.status == .cancelled
        || loop.status == .rollbackRequired
        || loop.status == .superseded
      let verifiedExistingPass = matchingExisting.map {
        TatwoPLGOrchestrator.branchPresentation(
          for: $0,
          in: projected).isVerifiedPass
      } ?? false
      if let matchingExisting,
         !failureStatus,
         !structuralBlocker,
         diagnostics.isEmpty || verifiedExistingPass
      {
        return matchingExisting
      }

      let reusableIdentity = duplicateIdentityBlocker ? nil : matchingExisting
      return TatwoPLGBranchGoal(
        id: reusableIdentity?.id ?? UUID(),
        objective: loop.title,
        subLabel: binding.map { "\($0.label) · \(domainName)" }
          ?? "\(loop.ownerIdentity.chineseName) unassigned · \(domainName)",
        subBindingID: binding?.id
          ?? "unassigned-\(loop.ownerIdentity.rawValue)-\(loop.id)",
        status: status,
        reason: diagnostics.isEmpty ? nil : diagnostics.joined(separator: " "),
        attempt: reusableIdentity?.attempt ?? max(loop.cycleIndex - 1, 0),
        deadlineISO: nil,
        reportedToMainline: false,
        domainLoopID: reusableIdentity?.domainLoopID ?? domainLoopID,
        domain: domain,
        sourceLoopID: reusableIdentity?.sourceLoopID ?? loop.id,
        ownerIdentity: loop.ownerIdentity,
        planSlice: planSlice,
        domainReceipt: nil)
    }
    return projected
  }

  private static func sameProjectionIdentity(
    _ branch: TatwoPLGBranchGoal,
    loop: DomainLoop,
    domain: TatwoPLGDomain?,
    bindingID: String?,
    planSlice: String,
    contractID: String
  ) -> Bool {
    let expectedBindingID = bindingID
      ?? "unassigned-\(loop.ownerIdentity.rawValue)-\(loop.id)"
    guard let sourceLoopID = branch.sourceLoopID,
          sourceLoopID == loop.id
            || sourceLoopID.hasPrefix("\(loop.id)#replan-"),
          branch.domain == domain,
          branch.ownerIdentity == loop.ownerIdentity,
          branch.subBindingID == expectedBindingID,
          branch.objective == loop.title,
          branch.planSlice == planSlice
    else {
      return false
    }
    return branch.domainLoopID
      == TatwoPLGOrchestrator.makeDomainLoopID(
        contractID: contractID,
        domainRawValue: loop.domain.rawValue,
        sourceLoopID: sourceLoopID)
  }

}

public enum TatwoPLGEventKind:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  case planningAdvanced
  case adversarialConclusionSet
  case humanAuthorized
  case planningProjectionMigrated
  case branchesAdded
  case branchReported
  case branchReplanned
  case branchEscalated
  case reportingAdvanced
  case mainlineCheckAdvanced
  case mainlineGoalEvaluated
  case rollbackRequested
}

public enum TatwoPLGEventPayload:
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  case phase(TatwoPLGPhase)
  case adversarialConclusion(String)
  case humanAuthorization(TatwoPLGHumanAuthReceipt)
  case planningProjection([TatwoPLGBranchGoal])
  case branchesAdded([TatwoPLGBranchGoal])
  case branchReport(
    id: UUID,
    status: TatwoLoopsStatus,
    reason: String?,
    nowISO: String)
  case branchReportWithDomainReceipt(
    id: UUID,
    status: TatwoLoopsStatus,
    reason: String?,
    domainReceipt: TatwoPLGDomainReceipt,
    nowISO: String)
  case branchReplan(
    id: UUID,
    reason: String?,
    deadlineISO: String?,
    nowISO: String)
  case branchEscalation(id: UUID, reason: String?, nowISO: String)
  case mainlineGoal(Bool)
  case rollback(reason: String?)
}

public struct TatwoPLGEvent:
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  public var eventID: UUID
  public var kind: TatwoPLGEventKind
  public var atRevision: Int
  public var payload: TatwoPLGEventPayload

  public init(
    eventID: UUID,
    kind: TatwoPLGEventKind,
    atRevision: Int,
    payload: TatwoPLGEventPayload
  ) {
    self.eventID = eventID
    self.kind = kind
    self.atRevision = atRevision
    self.payload = payload
  }
}

public struct TatwoPLGTransition:
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  public var run: TatwoPLGRun
  public var event: TatwoPLGEvent

  public init(run: TatwoPLGRun, event: TatwoPLGEvent) {
    self.run = run
    self.event = event
  }
}

public enum TatwoPLGError:
  Error,
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  case invalidPhase(expected: TatwoPLGPhase, actual: TatwoPLGPhase)
  case staleRevision(expected: Int, actual: Int)
  case leadBindingRequired
  case bindingNotFound(String)
  case bindingIdentityMismatch(
    bindingID: String,
    expected: IdentityKind,
    actual: IdentityKind)
  case authInvalid
  case branchNotFound(UUID)
  case invalidBranchReportStatus(TatwoLoopsStatus)
  case branchNotBlocked(UUID)
  case branchAlreadyEscalated(UUID)
  case branchGoalsRequired
  case branchGoalsNotPassed
  case branchGoalsNotReported
  case branchDomainBindingRequired(UUID)
  case branchDomainLoopIDMismatch(UUID)
  case branchPlanSliceRequired(UUID)
  case branchDomainReceiptRequired(UUID)
  case branchDomainReceiptMismatch(UUID)
  case duplicateSourceLoopID(String)
  case duplicateDomainLoopID(String)
  case eventPayloadMismatch
  case adversarialConclusionRequired
  case workOSCloseRequired

  public func hash(into hasher: inout Hasher) {
    switch self {
    case let .invalidPhase(expected, actual):
      hasher.combine(0)
      hasher.combine(expected)
      hasher.combine(actual)
    case let .staleRevision(expected, actual):
      hasher.combine(1)
      hasher.combine(expected)
      hasher.combine(actual)
    case .leadBindingRequired:
      hasher.combine(2)
    case let .bindingNotFound(id):
      hasher.combine(3)
      hasher.combine(id)
    case let .bindingIdentityMismatch(bindingID, expected, actual):
      hasher.combine(4)
      hasher.combine(bindingID)
      hasher.combine(expected.rawValue)
      hasher.combine(actual.rawValue)
    case .authInvalid:
      hasher.combine(5)
    case let .branchNotFound(id):
      hasher.combine(6)
      hasher.combine(id)
    case let .invalidBranchReportStatus(status):
      hasher.combine(7)
      hasher.combine(status)
    case let .branchNotBlocked(id):
      hasher.combine(8)
      hasher.combine(id)
    case let .branchAlreadyEscalated(id):
      hasher.combine(9)
      hasher.combine(id)
    case .branchGoalsRequired:
      hasher.combine(10)
    case .branchGoalsNotPassed:
      hasher.combine(11)
    case .branchGoalsNotReported:
      hasher.combine(12)
    case let .branchDomainBindingRequired(id):
      hasher.combine(13)
      hasher.combine(id)
    case let .branchDomainLoopIDMismatch(id):
      hasher.combine(14)
      hasher.combine(id)
    case let .branchPlanSliceRequired(id):
      hasher.combine(15)
      hasher.combine(id)
    case let .branchDomainReceiptRequired(id):
      hasher.combine(16)
      hasher.combine(id)
    case let .branchDomainReceiptMismatch(id):
      hasher.combine(17)
      hasher.combine(id)
    case let .duplicateSourceLoopID(id):
      hasher.combine(18)
      hasher.combine(id)
    case let .duplicateDomainLoopID(id):
      hasher.combine(19)
      hasher.combine(id)
    case .eventPayloadMismatch:
      hasher.combine(20)
    case .adversarialConclusionRequired:
      hasher.combine(21)
    case .workOSCloseRequired:
      hasher.combine(22)
    }
  }
}

public enum TatwoPLGOrchestrator:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable
{
  case namespace

  public static func makeDomainLoopID(
    contractID: String,
    domain: TatwoPLGDomain,
    sourceLoopID: String
  ) -> String {
    makeDomainLoopID(
      contractID: contractID,
      domainRawValue: domain.rawValue,
      sourceLoopID: sourceLoopID)
  }

  public static func makeArtifactsDigest(
    testsRun: [String]
  ) -> String {
    let canonicalManifest = testsRun
      .compactMap(nonEmpty)
      .sorted()
      .joined(separator: "\n")
    return TatwoArtifactReviewHasher.sha256(canonicalManifest)
  }

  fileprivate static func makeDomainLoopID(
    contractID: String,
    domainRawValue: String,
    sourceLoopID: String
  ) -> String {
    let tail = contractID.split(separator: "-").last.map(String.init) ?? ""
    let contractShort8 = tail.count >= 8
      ? String(tail.prefix(8)).lowercased()
      : String(TatwoArtifactReviewHasher.sha256(contractID).prefix(8))
    let sourceHash8 = String(
      TatwoArtifactReviewHasher.sha256(sourceLoopID).prefix(8))
    return "dloop-\(contractShort8)-\(domainRawValue)-\(sourceHash8)"
  }

  public static func advanceFromPlanning(
    _ run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requirePhase(.planning, in: run)
    try validateBindings(in: run)

    return try transition(
      from: run,
      eventID: eventID,
      kind: .planningAdvanced,
      payload: .phase(.leadAdversarial))
  }

  public static func migratePlanningProjection(
    to branches: [TatwoPLGBranchGoal],
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requirePhase(.planning, in: run)
    try validatePlanningProjectionMigration(
      from: run.branchGoals,
      to: branches,
      in: run)

    return try transition(
      from: run,
      eventID: eventID,
      kind: .planningProjectionMigrated,
      payload: .planningProjection(branches))
  }

  public static func setAdversarialConclusion(
    _ conclusion: String,
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requirePhase(.leadAdversarial, in: run)
    try validateBindings(in: run)
    let normalized = conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw TatwoPLGError.adversarialConclusionRequired
    }

    return try transition(
      from: run,
      eventID: eventID,
      kind: .adversarialConclusionSet,
      payload: .adversarialConclusion(normalized))
  }

  public static func authorize(
    receipt: TatwoPLGHumanAuthReceipt,
    nowISO: String,
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requirePhase(.awaitingHumanAuth, in: run)
    try validateBindings(in: run)
    try requireValid(
      receipt: receipt,
      contractID: run.contractID,
      nowISO: nowISO)

    return try transition(
      from: run,
      eventID: eventID,
      kind: .humanAuthorized,
      payload: .humanAuthorization(receipt))
  }

  public static func addBranchGoals(
    _ branches: [TatwoPLGBranchGoal],
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requirePhase(.executingLoops, in: run)
    guard !branches.isEmpty else {
      throw TatwoPLGError.branchGoalsRequired
    }
    let allBindings = run.leadBindings + run.subBindings
    for branch in branches {
      guard allBindings.contains(
        where: { $0.id == branch.subBindingID })
      else {
        throw TatwoPLGError.bindingNotFound(branch.subBindingID)
      }
      try validateDomainBinding(branch, in: run)
    }
    let existingSourceIDs = Set(run.branchGoals.compactMap(\.sourceLoopID))
    var addedSourceIDs = Set<String>()
    for branch in branches {
      guard let sourceLoopID = nonEmpty(branch.sourceLoopID) else {
        throw TatwoPLGError.branchDomainBindingRequired(branch.id)
      }
      guard !existingSourceIDs.contains(sourceLoopID),
            addedSourceIDs.insert(sourceLoopID).inserted
      else {
        throw TatwoPLGError.duplicateSourceLoopID(sourceLoopID)
      }
    }
    let existingIDs = Set(run.branchGoals.compactMap(\.domainLoopID))
    var addedIDs = Set<String>()
    for branch in branches {
      guard let domainLoopID = branch.domainLoopID else {
        throw TatwoPLGError.branchDomainBindingRequired(branch.id)
      }
      guard !existingIDs.contains(domainLoopID),
            addedIDs.insert(domainLoopID).inserted
      else {
        throw TatwoPLGError.duplicateDomainLoopID(domainLoopID)
      }
    }

    return try transition(
      from: run,
      eventID: eventID,
      kind: .branchesAdded,
      payload: .branchesAdded(branches))
  }

  public static func reportBranch(
    id: UUID,
    status: TatwoLoopsStatus,
    reason: String?,
    domainReceipt: TatwoPLGDomainReceipt? = nil,
    nowISO: String,
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requireExecutingRun(run, nowISO: nowISO)
    guard status == .passed || status == .blocked else {
      throw TatwoPLGError.invalidBranchReportStatus(status)
    }
    guard let branch = run.branchGoals.first(where: { $0.id == id }) else {
      throw TatwoPLGError.branchNotFound(id)
    }
    try validateDomainBinding(branch, in: run)
    if status == .passed {
      guard let domainReceipt else {
        throw TatwoPLGError.branchDomainReceiptRequired(id)
      }
      try validateDomainReceipt(
        domainReceipt,
        for: branch,
        expectedVerdict: .pass)
    } else if let domainReceipt {
      guard domainReceipt.verdict == .blocked
        || domainReceipt.verdict == .fail
      else {
        throw TatwoPLGError.branchDomainReceiptMismatch(id)
      }
      try validateDomainReceipt(
        domainReceipt,
        for: branch,
        expectedVerdict: domainReceipt.verdict)
    }

    return try transition(
      from: run,
      eventID: eventID,
      kind: .branchReported,
      payload: domainReceipt.map {
        .branchReportWithDomainReceipt(
          id: id,
          status: status,
          reason: reason,
          domainReceipt: $0,
          nowISO: nowISO)
      } ?? .branchReport(
        id: id,
        status: status,
        reason: reason,
        nowISO: nowISO))
  }

  public static func replanBranch(
    id: UUID,
    reason: String?,
    deadlineISO: String?,
    nowISO: String,
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requireExecutingRun(run, nowISO: nowISO)
    guard let branch = run.branchGoals.first(where: { $0.id == id }) else {
      throw TatwoPLGError.branchNotFound(id)
    }
    guard branch.status == .blocked else {
      throw TatwoPLGError.branchNotBlocked(id)
    }
    guard !branch.escalated else {
      throw TatwoPLGError.branchAlreadyEscalated(id)
    }
    if branch.attempt >= branch.maxAttempts
      || branch.deadlineISO.map({ nowISO >= $0 }) == true
    {
      return try transition(
        from: run,
        eventID: eventID,
        kind: .branchEscalated,
        payload: .branchEscalation(
          id: id,
          reason: reason,
          nowISO: nowISO))
    }

    return try transition(
      from: run,
      eventID: eventID,
      kind: .branchReplanned,
      payload: .branchReplan(
        id: id,
        reason: reason,
        deadlineISO: deadlineISO,
        nowISO: nowISO))
  }

  public static func escalateBranch(
    id: UUID,
    reason: String?,
    nowISO: String,
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requireExecutingRun(run, nowISO: nowISO)
    guard let branch = run.branchGoals.first(where: { $0.id == id }) else {
      throw TatwoPLGError.branchNotFound(id)
    }
    guard branch.status == .blocked else {
      throw TatwoPLGError.branchNotBlocked(id)
    }

    return try transition(
      from: run,
      eventID: eventID,
      kind: .branchEscalated,
      payload: .branchEscalation(
        id: id,
        reason: reason,
        nowISO: nowISO))
  }

  public static func advanceToReporting(
    _ run: TatwoPLGRun,
    nowISO: String,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requireExecutingRun(run, nowISO: nowISO)
    guard !run.branchGoals.isEmpty,
          run.branchGoals.allSatisfy({ $0.status == .passed })
    else {
      throw TatwoPLGError.branchGoalsNotPassed
    }
    for branch in run.branchGoals {
      try validateDomainBinding(branch, in: run)
      guard let receipt = branch.domainReceipt else {
        throw TatwoPLGError.branchDomainReceiptRequired(branch.id)
      }
      try validateDomainReceipt(
        receipt,
        for: branch,
        expectedVerdict: .pass)
      guard receiptPresentation(for: branch, in: run) == .pass else {
        throw TatwoPLGError.branchDomainReceiptMismatch(branch.id)
      }
    }

    return try transition(
      from: run,
      eventID: eventID,
      kind: .reportingAdvanced,
      payload: .phase(.branchesReporting))
  }

  public static func advanceToMainlineCheck(
    _ run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requirePhase(.branchesReporting, in: run)
    try validateBindings(in: run)
    guard run.branchGoals.allSatisfy(\.reportedToMainline) else {
      throw TatwoPLGError.branchGoalsNotReported
    }
    for branch in run.branchGoals {
      guard branch.status == .passed,
            receiptPresentation(for: branch, in: run) == .pass
      else {
        throw TatwoPLGError.branchDomainReceiptMismatch(branch.id)
      }
    }

    return try transition(
      from: run,
      eventID: eventID,
      kind: .mainlineCheckAdvanced,
      payload: .phase(.mainlineGoalCheck))
  }

  public static func setMainlineGoalMet(
    _ met: Bool,
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try requirePhase(.mainlineGoalCheck, in: run)
    try validateBindings(in: run)
    guard !met else {
      throw TatwoPLGError.workOSCloseRequired
    }

    return try transition(
      from: run,
      eventID: eventID,
      kind: .mainlineGoalEvaluated,
      payload: .mainlineGoal(met))
  }

  public static func requestRollback(
    reason: String?,
    in run: TatwoPLGRun,
    expectedRevision: Int,
    eventID: UUID
  ) throws -> TatwoPLGTransition {
    try requireRevision(expectedRevision, in: run)
    try validateBindings(in: run)

    return try transition(
      from: run,
      eventID: eventID,
      kind: .rollbackRequested,
      payload: .rollback(reason: reason))
  }

  public static func resolveSubBinding(
    for branch: TatwoPLGBranchGoal,
    in run: TatwoPLGRun
  ) throws -> WorkOSIdentityBinding {
    guard let expectedIdentity = branch.ownerIdentity else {
      throw TatwoPLGError.branchDomainBindingRequired(branch.id)
    }
    guard let binding = (run.leadBindings + run.subBindings).first(
      where: { $0.id == branch.subBindingID })
    else {
      throw TatwoPLGError.bindingNotFound(branch.subBindingID)
    }
    guard TatwoLoopsIdentityResolver.resolve(
      identity: expectedIdentity,
      bindings: [binding]) != nil
    else {
      throw TatwoPLGError.bindingIdentityMismatch(
        bindingID: binding.id,
        expected: expectedIdentity,
        actual: binding.identity)
    }
    return binding
  }

  public static func project(
    _ event: TatwoPLGEvent,
    onto run: TatwoPLGRun
  ) throws -> TatwoPLGRun {
    guard event.atRevision == run.revision + 1 else {
      throw TatwoPLGError.staleRevision(
        expected: run.revision + 1,
        actual: event.atRevision)
    }

    var projected = run
    switch (event.kind, event.payload) {
    case let (.planningAdvanced, .phase(phase)):
      projected.phase = phase

    case let (.adversarialConclusionSet, .adversarialConclusion(conclusion)):
      projected.adversarialConclusion = conclusion
      projected.phase = .awaitingHumanAuth

    case let (.humanAuthorized, .humanAuthorization(receipt)):
      projected.humanAuth = receipt
      projected.phase = .executingLoops

    case let (
      .planningProjectionMigrated,
      .planningProjection(branches)
    ):
      try validatePlanningProjectionMigration(
        from: projected.branchGoals,
        to: branches,
        in: projected)
      projected.branchGoals = branches

    case let (.branchesAdded, .branchesAdded(branches)):
      try validateBranchAdditions(branches, to: projected)
      projected.branchGoals.append(contentsOf: branches)

    case let (.branchReported, .branchReport(id, status, reason, _)):
      let index = try branchIndex(id, in: projected)
      guard status == .blocked else {
        throw TatwoPLGError.invalidBranchReportStatus(status)
      }
      projected.branchGoals[index].status = status
      projected.branchGoals[index].reason = reason
      projected.branchGoals[index].reportedToMainline = false
      projected.branchGoals[index].domainReceipt = nil
      projected.branchGoals[index].clearAuthority()

    case let (
      .branchReported,
      .branchReportWithDomainReceipt(id, status, reason, domainReceipt, _)
    ):
      let index = try branchIndex(id, in: projected)
      let current = projected.branchGoals[index]
      guard status == .passed || status == .blocked else {
        throw TatwoPLGError.invalidBranchReportStatus(status)
      }
      let expectedVerdict: TatwoPLGDomainVerdict
      if status == .passed {
        expectedVerdict = .pass
      } else {
        guard domainReceipt.verdict == .blocked
          || domainReceipt.verdict == .fail
        else {
          throw TatwoPLGError.branchDomainReceiptMismatch(id)
        }
        expectedVerdict = domainReceipt.verdict
      }
      try validateDomainReceipt(
        domainReceipt,
        for: current,
        expectedVerdict: expectedVerdict)
      projected.branchGoals[index].status = status
      projected.branchGoals[index].reason = reason
      projected.branchGoals[index].reportedToMainline = status == .passed
      projected.branchGoals[index].domainReceipt = domainReceipt
      let seal = makeAuthoritySeal(
        branch: projected.branchGoals[index],
        contractID: projected.contractID,
        revision: event.atRevision)
      projected.branchGoals[index].setAuthority(
        revision: event.atRevision,
        seal: seal)

    case let (.branchReplanned, .branchReplan(id, reason, deadlineISO, _)):
      let index = try branchIndex(id, in: projected)
      projected.branchGoals[index].status = .planned
      projected.branchGoals[index].reason = reason
      projected.branchGoals[index].attempt += 1
      projected.branchGoals[index].deadlineISO = deadlineISO
      projected.branchGoals[index].reportedToMainline = false
      projected.branchGoals[index].domainReceipt = nil
      projected.branchGoals[index].clearAuthority()
      if let sourceLoopID = nonEmpty(projected.branchGoals[index].sourceLoopID),
         let domain = projected.branchGoals[index].domain
      {
        let nextSourceLoopID =
          "\(sourceLoopID)#replan-\(projected.branchGoals[index].attempt)"
        projected.branchGoals[index].sourceLoopID = nextSourceLoopID
        projected.branchGoals[index].domainLoopID = makeDomainLoopID(
          contractID: projected.contractID,
          domain: domain,
          sourceLoopID: nextSourceLoopID)
      } else {
        projected.branchGoals[index].quarantinePolicyD(
          "Policy D migration quarantine：replan 缺少 authoritative source loop identity")
      }

    case let (.branchEscalated, .branchEscalation(id, reason, _)):
      let index = try branchIndex(id, in: projected)
      projected.branchGoals[index].status = .blocked
      projected.branchGoals[index].reason = reason
      projected.branchGoals[index].reportedToMainline = false
      projected.branchGoals[index].escalated = true
      projected.branchGoals[index].domainReceipt = nil
      projected.branchGoals[index].clearAuthority()
      projected.phase = .rollbackRequired

    case let (.reportingAdvanced, .phase(phase)):
      guard phase == .branchesReporting else {
        throw TatwoPLGError.eventPayloadMismatch
      }
      projected.phase = phase

    case let (.mainlineCheckAdvanced, .phase(phase)):
      guard phase == .mainlineGoalCheck else {
        throw TatwoPLGError.eventPayloadMismatch
      }
      projected.phase = phase

    case let (.mainlineGoalEvaluated, .mainlineGoal(met)):
      guard !met else {
        throw TatwoPLGError.workOSCloseRequired
      }
      projected.mainlineGoalMet = met
      projected.phase = .rollbackRequired

    case (.rollbackRequested, .rollback):
      projected.phase = .rollbackRequired

    default:
      throw TatwoPLGError.eventPayloadMismatch
    }

    projected.revision = event.atRevision
    return projected
  }

  private static func transition(
    from run: TatwoPLGRun,
    eventID: UUID,
    kind: TatwoPLGEventKind,
    payload: TatwoPLGEventPayload
  ) throws -> TatwoPLGTransition {
    let event = TatwoPLGEvent(
      eventID: eventID,
      kind: kind,
      atRevision: run.revision + 1,
      payload: payload)
    var projected = try project(event, onto: run)
    projected.markLiveTransition()
    return TatwoPLGTransition(run: projected, event: event)
  }

  private static func requireExecutingRun(
    _ run: TatwoPLGRun,
    nowISO: String
  ) throws {
    try requirePhase(.executingLoops, in: run)
    try validateBindings(in: run)
    guard let receipt = run.humanAuth else {
      throw TatwoPLGError.authInvalid
    }
    try requireValid(
      receipt: receipt,
      contractID: run.contractID,
      nowISO: nowISO)
  }

  private static func requireValid(
    receipt: TatwoPLGHumanAuthReceipt,
    contractID: String,
    nowISO: String
  ) throws {
    guard !receipt.receiptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !receipt.actor.isEmpty,
          !receipt.issuedISO.isEmpty,
          !receipt.expiresISO.isEmpty,
          !receipt.scope.isEmpty,
          receipt.contractID == contractID,
          receipt.issuedISO <= nowISO,
          nowISO < receipt.expiresISO
    else {
      throw TatwoPLGError.authInvalid
    }
  }

  private static func validateBindings(in run: TatwoPLGRun) throws {
    guard TatwoLoopsIdentityResolver.resolve(
      identity: .lead,
      bindings: run.leadBindings) != nil
    else {
      throw TatwoPLGError.leadBindingRequired
    }
    try validateUniqueLoopIdentities(run.branchGoals)
    for branch in run.branchGoals {
      _ = try resolveSubBinding(for: branch, in: run)
      try validateDomainBinding(branch, in: run)
    }
  }

  private static func validatePlanningProjectionMigration(
    from current: [TatwoPLGBranchGoal],
    to migrated: [TatwoPLGBranchGoal],
    in run: TatwoPLGRun
  ) throws {
    guard !current.isEmpty,
          current.contains(where: \.isBlockedUnsupportedDomainProjection),
          current.allSatisfy({
            !$0.reportedToMainline
              && $0.domainReceipt == nil
              && $0.status != .passed
          }),
          migrated.count == current.count,
          Set(migrated.compactMap(\.sourceLoopID))
            == Set(current.compactMap(\.sourceLoopID)),
          !migrated.contains(where: \.isBlockedUnsupportedDomainProjection)
    else {
      throw TatwoPLGError.eventPayloadMismatch
    }
    try validateUniqueLoopIdentities(migrated)
    for branch in migrated {
      _ = try resolveSubBinding(for: branch, in: run)
      try validateDomainBinding(branch, in: run)
    }
    let migratedBySource = Dictionary(
      uniqueKeysWithValues: migrated.compactMap { branch in
        branch.sourceLoopID.map { ($0, branch) }
      })
    for branch in current {
      guard let sourceLoopID = branch.sourceLoopID,
            let replacement = migratedBySource[sourceLoopID]
      else {
        throw TatwoPLGError.eventPayloadMismatch
      }
      if !branch.isBlockedUnsupportedDomainProjection {
        guard replacement == branch else {
          throw TatwoPLGError.eventPayloadMismatch
        }
        continue
      }
      guard replacement.objective == branch.objective,
            replacement.subLabel == branch.subLabel,
            replacement.subBindingID == branch.subBindingID,
            replacement.status == .planned,
            replacement.reason == nil,
            replacement.attempt == branch.attempt,
            replacement.maxAttempts == branch.maxAttempts,
            replacement.deadlineISO == branch.deadlineISO,
            !replacement.reportedToMainline,
            replacement.escalated == branch.escalated,
            replacement.domainLoopID == branch.domainLoopID,
            replacement.sourceLoopID == branch.sourceLoopID,
            replacement.ownerIdentity == branch.ownerIdentity,
            replacement.planSlice == branch.planSlice,
            replacement.domainReceipt == nil,
            replacement.authorityRevision == nil,
            replacement.authoritySeal == nil
      else {
        throw TatwoPLGError.eventPayloadMismatch
      }
    }
  }

  private static func validateDomainBinding(
    _ branch: TatwoPLGBranchGoal,
    in run: TatwoPLGRun
  ) throws {
    guard let domain = branch.domain,
          let domainLoopID = nonEmpty(branch.domainLoopID),
          let sourceLoopID = nonEmpty(branch.sourceLoopID),
          branch.ownerIdentity != nil
    else {
      throw TatwoPLGError.branchDomainBindingRequired(branch.id)
    }
    let expectedID = makeDomainLoopID(
      contractID: run.contractID,
      domain: domain,
      sourceLoopID: sourceLoopID)
    guard domainLoopID == expectedID else {
      throw TatwoPLGError.branchDomainLoopIDMismatch(branch.id)
    }
    guard let planSlice = nonEmpty(branch.planSlice),
          TatwoObjectiveIdentity.normalize(planSlice)
            != TatwoObjectiveIdentity.normalize(run.planSummary)
    else {
      throw TatwoPLGError.branchPlanSliceRequired(branch.id)
    }
  }

  private static func validateDomainReceipt(
    _ receipt: TatwoPLGDomainReceipt,
    for branch: TatwoPLGBranchGoal,
    expectedVerdict: TatwoPLGDomainVerdict
  ) throws {
    guard receiptPayloadMatchesBranch(receipt, branch: branch),
          receipt.verdict == expectedVerdict
    else {
      throw TatwoPLGError.branchDomainReceiptMismatch(branch.id)
    }
  }

  fileprivate static func receiptPayloadMatchesBranch(
    _ receipt: TatwoPLGDomainReceipt,
    branch: TatwoPLGBranchGoal
  ) -> Bool {
    guard let domainLoopID = nonEmpty(branch.domainLoopID),
          let planSlice = nonEmpty(branch.planSlice)
    else {
      return false
    }
    let testsRun = receipt.testsRun.compactMap(nonEmpty)
    guard !testsRun.isEmpty else {
      return false
    }
    return receipt.domainLoopID == domainLoopID
      && receipt.objectiveHash
        == TatwoObjectiveIdentity.make(branch.objective).objectiveHash
      && receipt.inputsDigest
        == TatwoArtifactReviewHasher.sha256(planSlice)
      && receipt.artifactsDigest == makeArtifactsDigest(testsRun: testsRun)
  }

  public static func receiptPresentation(
    for branch: TatwoPLGBranchGoal,
    in run: TatwoPLGRun
  ) -> TatwoPLGReceiptPresentation {
    branchPresentation(for: branch, in: run).receipt
  }

  public static func branchPresentation(
    for branch: TatwoPLGBranchGoal,
    in run: TatwoPLGRun
  ) -> TatwoPLGBranchPresentation {
    let blocked = TatwoPLGBranchPresentation(
      receipt: .blocked,
      visualStatus: .blocked,
      isVerifiedPass: false)
    guard run.branchGoals.contains(branch) else {
      return blocked
    }
    do {
      try validateUniqueLoopIdentities(run.branchGoals)
      _ = try resolveSubBinding(for: branch, in: run)
      try validateDomainBinding(branch, in: run)
    } catch {
      return blocked
    }

    guard let receipt = branch.domainReceipt else {
      return TatwoPLGBranchPresentation(
        receipt: .blocked,
        visualStatus: branch.status == .passed ? .blocked : branch.status,
        isVerifiedPass: false)
    }
    guard run.hasTrustedAuthority,
          receiptPayloadMatchesBranch(receipt, branch: branch),
          authoritySealMatches(branch: branch, in: run)
    else {
      return blocked
    }
    switch receipt.verdict {
    case .pass:
      guard branch.status == .passed, branch.reportedToMainline else {
        return blocked
      }
      return TatwoPLGBranchPresentation(
        receipt: .pass,
        visualStatus: .passed,
        isVerifiedPass: true)
    case .fail:
      guard branch.status == .blocked, !branch.reportedToMainline else {
        return blocked
      }
      return TatwoPLGBranchPresentation(
        receipt: .fail,
        visualStatus: .blocked,
        isVerifiedPass: false)
    case .blocked:
      return blocked
    }
  }

  fileprivate static func quarantinedSnapshot(
    _ run: TatwoPLGRun
  ) -> TatwoPLGRun {
    var projected = run
    let sourceCounts = Dictionary(
      grouping: projected.branchGoals.compactMap(\.sourceLoopID),
      by: { $0 })
      .mapValues(\.count)
    let generatedCounts = Dictionary(
      grouping: projected.branchGoals.compactMap(\.domainLoopID),
      by: { $0 })
      .mapValues(\.count)
    var quarantinedAny = false

    for index in projected.branchGoals.indices {
      let branch = projected.branchGoals[index]
      var quarantineReason: String?

      if branch.isBlockedStructuralPolicyDProjection {
        continue
      } else if branch.reason?.contains("Policy D migration quarantine") == true {
        quarantineReason = branch.reason
      } else if let sourceLoopID = nonEmpty(branch.sourceLoopID),
                sourceCounts[sourceLoopID, default: 0] > 1
      {
        quarantineReason =
          "Policy D migration quarantine：duplicate source loop ID \(sourceLoopID)"
      } else if let domainLoopID = nonEmpty(branch.domainLoopID),
                generatedCounts[domainLoopID, default: 0] > 1
      {
        quarantineReason =
          "Policy D migration quarantine：duplicate generated domainLoopID \(domainLoopID)"
      } else {
        do {
          _ = try resolveSubBinding(for: branch, in: projected)
          if !branch.isBlockedUnsupportedDomainProjection {
            try validateDomainBinding(branch, in: projected)
          }
          if branch.domainReceipt != nil
            && !authoritySealMatches(branch: branch, in: projected)
          {
            quarantineReason =
              "Policy D migration quarantine：receipt authority seal mismatch"
          } else if branch.status == .passed || branch.reportedToMainline {
            if receiptPresentation(for: branch, in: projected) != .pass {
              quarantineReason =
                "Policy D migration quarantine：unvalidated pass/report state"
            }
          }
        } catch {
          quarantineReason =
            "Policy D migration quarantine：invalid binding or loop identity"
        }
      }

      if let quarantineReason {
        projected.branchGoals[index].quarantinePolicyD(quarantineReason)
        quarantinedAny = true
      }
    }
    if quarantinedAny {
      projected.phase = .rollbackRequired
    }
    return projected
  }

  private static func validateUniqueLoopIdentities(
    _ branches: [TatwoPLGBranchGoal]
  ) throws {
    var sourceIDs = Set<String>()
    var generatedIDs = Set<String>()
    for branch in branches {
      guard let sourceLoopID = nonEmpty(branch.sourceLoopID),
            let domainLoopID = nonEmpty(branch.domainLoopID)
      else {
        throw TatwoPLGError.branchDomainBindingRequired(branch.id)
      }
      guard sourceIDs.insert(sourceLoopID).inserted else {
        throw TatwoPLGError.duplicateSourceLoopID(sourceLoopID)
      }
      guard generatedIDs.insert(domainLoopID).inserted else {
        throw TatwoPLGError.duplicateDomainLoopID(domainLoopID)
      }
    }
  }

  private static func validateBranchAdditions(
    _ branches: [TatwoPLGBranchGoal],
    to run: TatwoPLGRun
  ) throws {
    guard !branches.isEmpty else {
      throw TatwoPLGError.branchGoalsRequired
    }
    let combined = run.branchGoals + branches
    try validateUniqueLoopIdentities(combined)
    for branch in branches {
      _ = try resolveSubBinding(for: branch, in: run)
      try validateDomainBinding(branch, in: run)
    }
  }

  private static func authoritySealMatches(
    branch: TatwoPLGBranchGoal,
    in run: TatwoPLGRun
  ) -> Bool {
    guard let revision = branch.authorityRevision,
          let seal = nonEmpty(branch.authoritySeal)
    else {
      return false
    }
    return seal == makeAuthoritySeal(
      branch: branch,
      contractID: run.contractID,
      revision: revision)
  }

  private static func makeAuthoritySeal(
    branch: TatwoPLGBranchGoal,
    contractID: String,
    revision: Int
  ) -> String {
    let receipt = branch.domainReceipt
    let payload = [
      contractID,
      String(revision),
      branch.id.uuidString.lowercased(),
      branch.sourceLoopID ?? "",
      branch.domainLoopID ?? "",
      branch.subBindingID,
      branch.ownerIdentity?.rawValue ?? "",
      TatwoObjectiveIdentity.make(branch.objective).objectiveHash,
      receipt?.inputsDigest ?? "",
      receipt?.artifactsDigest ?? "",
      receipt?.verdict.rawValue ?? "",
      makeArtifactsDigest(testsRun: receipt?.testsRun ?? [])
    ].joined(separator: "|")
    return TatwoArtifactReviewHasher.sha256(payload)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let normalized = value?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !normalized.isEmpty
    else {
      return nil
    }
    return normalized
  }

  private static func requireRevision(
    _ expected: Int,
    in run: TatwoPLGRun
  ) throws {
    guard run.revision == expected else {
      throw TatwoPLGError.staleRevision(
        expected: expected,
        actual: run.revision)
    }
  }

  private static func requirePhase(
    _ expected: TatwoPLGPhase,
    in run: TatwoPLGRun
  ) throws {
    guard run.phase == expected else {
      throw TatwoPLGError.invalidPhase(
        expected: expected,
        actual: run.phase)
    }
  }

  private static func branchIndex(
    _ id: UUID,
    in run: TatwoPLGRun
  ) throws -> Int {
    guard let index = run.branchGoals.firstIndex(where: { $0.id == id }) else {
      throw TatwoPLGError.branchNotFound(id)
    }
    return index
  }
}
