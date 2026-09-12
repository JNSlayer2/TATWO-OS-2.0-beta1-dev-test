public extension EngineID {
  static let claude: EngineID = "claude"
}

public enum TatwoPLGRunFactory {
  public static func make(
    objective: String,
    contractID: String,
    goalID: String,
    leadModelIDs: [String],
    subModelIDs: [String],
    nowISO: String
  ) -> TatwoPLGRun {
    TatwoPLGRun(
      goalID: goalID,
      contractID: contractID,
      revision: 0,
      phase: .planning,
      leadBindings: leadModelIDs.map {
        binding(identity: .lead, modelID: $0, nowISO: nowISO)
      },
      subBindings: subModelIDs.map {
        binding(identity: .sub, modelID: $0, nowISO: nowISO)
      },
      planSummary: objective,
      adversarialConclusion: nil,
      humanAuth: nil,
      branchGoals: [],
      mainlineGoalMet: nil)
  }

  private static func binding(
    identity: IdentityKind,
    modelID: String,
    nowISO: String
  ) -> WorkOSIdentityBinding {
    WorkOSIdentityBinding(
      id: "role-\(identity.rawValue)-\(modelID)",
      identity: identity,
      label: modelID,
      engineID: engineID(for: modelID),
      modelID: modelID,
      authority: .brainOnly,
      canMutateHost: false,
      sourceSlotID: "thread-config-\(identity.rawValue)",
      bindingRule: "Thread config binding created at \(nowISO).")
  }

  private static func engineID(for modelID: String) -> EngineID {
    let normalized = modelID.lowercased()
    let claudeMarkers = ["fable", "opus", "sonnet", "haiku"]
    return claudeMarkers.contains(where: normalized.contains) ? .claude : .modelGateway
  }
}
