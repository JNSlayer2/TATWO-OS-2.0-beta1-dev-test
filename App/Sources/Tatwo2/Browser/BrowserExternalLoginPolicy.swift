import Foundation

enum BrowserExternalLoginPolicy {
    /// A login handoff starts at the website's origin. Never send callback paths,
    /// query tokens, URL passwords, fragments or local-file URLs to another app.
    static func websiteOrigin(_ raw: String?) -> URL? {
        guard let raw, let original = URLComponents(string: raw),
              let scheme = original.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = original.host, !host.isEmpty,
              original.user == nil, original.password == nil else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = original.port
        origin.path = "/"
        return origin.url
    }
}
