import CryptoKit
import Foundation

struct BrowserNetworkSecurityPolicy: Equatable, Sendable {
    var sendsGlobalPrivacyControl = true
    var reducesCrossOriginReferrers = true
    var blocksThirdPartyCookies = true
    var privacyStrict = true

    static let `default` = BrowserNetworkSecurityPolicy()
}

enum BrowserSecurityFailureDomain: String, Sendable {
    case advisoryTrackerRules
    case privateNetwork
    case localDenyList
    case invalidCertificate
    case profileIsolation

    var failsClosed: Bool {
        switch self {
        case .advisoryTrackerRules:
            false
        case .privateNetwork,
             .localDenyList,
             .invalidCertificate,
             .profileIsolation:
            true
        }
    }
}

struct BrowserHostDenyList: Equatable, Sendable {
    struct Document: Codable, Equatable, Sendable {
        static let schema = "TatwoBrowserHostDenyListV1"

        let schema: String
        let exactHosts: [String]
        let suffixes: [String]
    }

    enum LoadError: Error, Equatable {
        case invalidSchema
        case invalidHost(String)
        case oversizedDocument
    }

    static let maximumDocumentBytes = 16 * 1_048_576

    let exactHosts: Set<String>
    let suffixes: Set<String>

    init(
        exactHosts: some Sequence<String> = [],
        suffixes: some Sequence<String> = []
    ) throws {
        self.exactHosts = try Set(exactHosts.map(Self.canonicalEntry))
        self.suffixes = try Set(suffixes.map(Self.canonicalEntry))
    }

    init(jsonData: Data) throws {
        guard jsonData.count <= Self.maximumDocumentBytes else {
            throw LoadError.oversizedDocument
        }
        let document = try JSONDecoder().decode(Document.self, from: jsonData)
        guard document.schema == Document.schema else {
            throw LoadError.invalidSchema
        }
        try self.init(
            exactHosts: document.exactHosts,
            suffixes: document.suffixes)
    }

    init(combining lists: some Sequence<BrowserHostDenyList>) {
        exactHosts = lists.reduce(into: Set<String>()) {
            $0.formUnion($1.exactHosts)
        }
        suffixes = lists.reduce(into: Set<String>()) {
            $0.formUnion($1.suffixes)
        }
    }

    func blocks(host rawHost: String) -> Bool {
        guard let host = Self.canonicalHost(rawHost) else {
            return true
        }
        if exactHosts.contains(host) || suffixes.contains(host) {
            return true
        }
        var searchStart = host.startIndex
        while let dot = host[searchStart...].firstIndex(of: ".") {
            let suffixStart = host.index(after: dot)
            if suffixes.contains(String(host[suffixStart...])) {
                return true
            }
            searchStart = suffixStart
        }
        return false
    }

    func blocks(url: URL) -> Bool {
        guard let host = url.host else {
            return true
        }
        return blocks(host: host)
    }

    private static func canonicalEntry(_ raw: String) throws -> String {
        guard let host = canonicalHost(raw) else {
            throw LoadError.invalidHost(raw)
        }
        return host
    }

    static func canonicalHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(
                  from: CharacterSet(charactersIn: "/:@?#")) == nil,
              trimmed.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace
                      && !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        var host = trimmed.lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty,
              URLComponents(string: "https://\(host)")?.host != nil
        else {
            return nil
        }
        return host
    }
}

enum BrowserHostDenyListLoader {
    static func load(
        bundledAdminURL: URL? = nil,
        adminURL: URL?,
        userURL: URL?,
        fileManager: FileManager = .default
    ) throws -> BrowserHostDenyList {
        let lists: [BrowserHostDenyList] =
            try [bundledAdminURL, adminURL, userURL].compactMap {
                (url: URL?) throws -> BrowserHostDenyList? in
                guard let url,
                      fileManager.fileExists(atPath: url.path)
                else {
                    return nil
                }
                return try BrowserHostDenyList(
                    jsonData: Data(
                        contentsOf: url,
                        options: [.mappedIfSafe]))
            }
        return BrowserHostDenyList(combining: lists)
    }
}

struct BrowserBlocklistManifest: Codable, Equatable, Sendable {
    struct Output: Codable, Equatable, Sendable {
        let file: String
        let sha256: String
        let exactCount: Int
        let suffixCount: Int
    }

    static let schema = "TatwoBrowserBlocklistManifestV1"

    let schema: String
    let generatedAt: String
    let output: Output
}

enum BrowserBundledHostDenyList {
    enum VerificationError: Error, Equatable {
        case resourceMissing
        case invalidManifest
        case invalidOutputFile
        case digestMismatch
        case countMismatch
    }

    private static let defaultResourceVerification: Result<URL, Error> =
        Result {
            try verifiedResourceURL(in: .module)
        }

    static func verifiedResourceURL() throws -> URL {
        try defaultResourceVerification.get()
    }

    private static func verifiedResourceURL(
        in bundle: Bundle
    ) throws -> URL {
        guard let listURL = bundle.url(
            forResource: "browser-host-deny-list",
            withExtension: "json",
            subdirectory: "BrowserBlocklists"),
              let manifestURL = bundle.url(
                forResource: "browser-blocklists-manifest",
                withExtension: "json",
                subdirectory: "BrowserBlocklists")
        else {
            throw VerificationError.resourceMissing
        }
        return try verify(listURL: listURL, manifestURL: manifestURL)
    }

    @discardableResult
    static func verify(
        listURL: URL,
        manifestURL: URL
    ) throws -> URL {
        let manifest: BrowserBlocklistManifest
        do {
            manifest = try JSONDecoder().decode(
                BrowserBlocklistManifest.self,
                from: Data(contentsOf: manifestURL, options: [.mappedIfSafe]))
        } catch {
            throw VerificationError.invalidManifest
        }
        guard manifest.schema == BrowserBlocklistManifest.schema else {
            throw VerificationError.invalidManifest
        }
        guard manifest.output.file == listURL.lastPathComponent else {
            throw VerificationError.invalidOutputFile
        }
        let data = try Data(contentsOf: listURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == manifest.output.sha256.lowercased() else {
            throw VerificationError.digestMismatch
        }
        let list = try BrowserHostDenyList(jsonData: data)
        guard list.exactHosts.count == manifest.output.exactCount,
              list.suffixes.count == manifest.output.suffixCount
        else {
            throw VerificationError.countMismatch
        }
        return listURL
    }
}

enum BrowserSameSitePolicy {
    private static let commonCountryCodeSecondLevelDomains: Set<String> = [
        "ac", "co", "com", "edu", "gov", "net", "org",
    ]

    static func isSameSite(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              lhsScheme == rhsScheme,
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased()
        else {
            return false
        }
        return registrableDomain(lhsHost) == registrableDomain(rhsHost)
    }

    private static func registrableDomain(_ host: String) -> String {
        if host.contains(":")
            || host.unicodeScalars.allSatisfy({
                CharacterSet.decimalDigits.contains($0) || $0 == "."
            })
        {
            return host
        }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else {
            return host
        }
        let topLevel = labels[labels.count - 1]
        let secondLevel = labels[labels.count - 2]
        if topLevel.count == 2,
           commonCountryCodeSecondLevelDomains.contains(secondLevel),
           labels.count >= 3
        {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }
}

struct BrowserRequestPolicyDecision: Equatable, Sendable {
    let isAllowed: Bool
    let secGPC: String?
    let referrer: String?
    let originHeader: String?
}

enum BrowserRequestPolicyEvaluator {
    static func evaluate(
        requestURL: URL,
        referrerURL: URL?,
        originHeader: String?,
        policy: BrowserNetworkSecurityPolicy = .default
    ) -> BrowserRequestPolicyDecision {
        guard requestURL.user == nil,
              requestURL.password == nil
        else {
            return BrowserRequestPolicyDecision(
                isAllowed: false,
                secGPC: nil,
                referrer: nil,
                originHeader: originHeader)
        }

        let reducedReferrer: String?
        if policy.reducesCrossOriginReferrers,
           let referrerURL,
           !sameOrigin(referrerURL, requestURL)
        {
            reducedReferrer = origin(of: referrerURL)
        } else {
            reducedReferrer = referrerURL?.absoluteString
        }
        return BrowserRequestPolicyDecision(
            isAllowed: true,
            secGPC: policy.sendsGlobalPrivacyControl ? "1" : nil,
            referrer: reducedReferrer,
            originHeader: originHeader)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        origin(of: lhs) == origin(of: rhs)
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        let defaultPort = scheme == "http" ? 80 : 443
        if let port = url.port, port != defaultPort {
            components.port = port
        }
        return components.url?.absoluteString
    }
}

enum BrowserProfilePolicyTag: String, Codable, Equatable, Sendable {
    case humanPersistent = "human-persistent"
    case humanEphemeral = "human-ephemeral"
    case agentEphemeral = "agent-ephemeral"

    static func mayShareRequestContext(
        _ lhs: BrowserProfilePolicyTag,
        _ rhs: BrowserProfilePolicyTag
    ) -> Bool {
        lhs == rhs
    }
}

struct BrowserNavigationEpochState: Equatable, Sendable {
    private(set) var navigationGeneration: UInt64 = 0
    private(set) var documentEpoch: UInt64 = 0
    private(set) var isValid = false

    @discardableResult
    mutating func didCommitMainFrameNavigation() -> Bool {
        let nextGeneration = navigationGeneration.addingReportingOverflow(1)
        let nextEpoch = documentEpoch.addingReportingOverflow(1)
        guard !nextGeneration.overflow, !nextEpoch.overflow else {
            invalidate()
            return false
        }
        navigationGeneration = nextGeneration.partialValue
        documentEpoch = nextEpoch.partialValue
        isValid = true
        return true
    }

    mutating func invalidate() {
        isValid = false
        let nextEpoch = documentEpoch.addingReportingOverflow(1)
        documentEpoch = nextEpoch.overflow ? .max : nextEpoch.partialValue
    }
}
