import Foundation

public enum TatwoPrivacyRedactor {
  public static func redacted(_ input: String) -> String {
    var value = input
    let replacements: [(String, String)] = [
      (#"Authorization:\s*Bearer\s+[A-Za-z0-9._\-]+"#, "Authorization: Bearer <redacted>"),
      (#"sk-[A-Za-z0-9_\-]{10,}"#, "<token>"),
      (
        #"(?i)\b(auth\.json|access_token|refresh_token|api[_-]?key)\b"#,
        "<private-auth-material>"
      ),
      (
        #"(?i)\bcookie\b(?=\s*[:=])"#,
        "<private-auth-material>"
      ),
      (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
      (#"/Users/[^\n\"'`<>]+"#, "<local-path>"),
      (#"/Volumes/[^\n\"'`<>]+"#, "<local-path>"),
      (#"~/\.codex/[^\s"'`<>]+"#, "<codex-private-path>"),
      (#"\$HOME/\.codex/[^\s"'`<>]+"#, "<codex-private-path>"),
    ]
    for (pattern, replacement) in replacements {
      value = value.replacingOccurrences(
        of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
    return value
  }
}
