import Foundation

/// Diagnostics never read forms, tool arguments/results, cookies or credentials.
/// All page-controlled display strings pass here before entering a snapshot.
enum BrowserDiagnosticsPrivacy {
    static func host(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let bareIPv6 = !value.contains("://") && !value.hasPrefix("[") && value.filter { $0 == ":" }.count > 1
        let input = value.contains("://") ? value : "https://" + (bareIPv6 ? "[\(value)]" : value)
        guard let host = URLComponents(string: input)?.host, !host.isEmpty else { return "—" }
        return text(host.lowercased())
    }

    static func text(_ value: String) -> String {
        var text = String(value.prefix(2048))
        // A title/tool name may itself contain a URL, a query, or credential-shaped text.
        text = text.replacingOccurrences(of: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s]+"#,
                                        with: "[網址]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)(password|passwd|pwd|token|secret|authorization).*"#,
                                        with: "[已遮蔽]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)(\?|%3f|#|%23).*"#,
                                        with: "", options: .regularExpression)
        text = text.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(text.prefix(256))
    }
}
