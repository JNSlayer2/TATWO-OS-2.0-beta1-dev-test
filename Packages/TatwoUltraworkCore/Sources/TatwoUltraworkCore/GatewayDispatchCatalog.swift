import Foundation

/// Canonical in-repo source for Work OS identity-to-model routing through
/// `tatwo.gateway.dispatch`. Provider brands do not select the runner.
public enum TatwoGatewayDispatchCatalog {
  public static let allowedModels = TatwoModelIdentityRegistry.canonicalModelIDs

  public static let expensiveModels: Set<String> = ["fable-5", "opus-5"]

  public static let aliases = TatwoModelIdentityRegistry.aliases

  public static func models(for identity: IdentityKind) -> [String] {
    switch identity {
    case .lead: return ["fable-5"]
    case .supervisor: return ["gpt-5.6-terra"]
    case .sub: return ["gpt-5.6-sol"]
    case .verifier: return ["fable-5"]
    case .consultant: return ["sonnet-5"]
    case .news: return ["grok-build"]
    }
  }

  public static func normalize(_ value: String?) -> String {
    TatwoModelIdentityRegistry.normalize(value)
  }
}
