public enum TatwoLoopsIdentityResolver {
  public static func resolve(
    identity: IdentityKind,
    bindings: [WorkOSIdentityBinding]
  ) -> WorkOSIdentityBinding? {
    bindings.first { $0.identity == identity }
  }

  public static func resolveModelID(
    identity: IdentityKind,
    bindings: [WorkOSIdentityBinding],
    fallback: String?
  ) -> String? {
    resolve(identity: identity, bindings: bindings)?.modelID ?? fallback
  }
}
