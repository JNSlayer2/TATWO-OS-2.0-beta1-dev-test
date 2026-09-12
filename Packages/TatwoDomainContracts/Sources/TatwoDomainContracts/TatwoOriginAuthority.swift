import Foundation

/// Structured failure returned when a production mutation is not authorized by
/// the current handoff lease.
public enum TatwoOriginAuthorityError: Error, LocalizedError, Sendable, Equatable {
    case originWriteFenced(
        surface: String,
        domainID: String?,
        deviceID: String,
        epoch: UInt64
    )
    case durableStoreUnavailable(surface: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .originWriteFenced(surface, domainID, deviceID, epoch):
            let domain = domainID ?? "unbound"
            return
                "origin authority fenced surface=\(surface) domain=\(domain) "
                + "device=\(deviceID) epoch=\(epoch)"
        case let .durableStoreUnavailable(surface, detail):
            return "origin authority durable store unavailable surface=\(surface): \(detail)"
        }
    }
}

/// Durable, create-only registry of authority domains.
///
/// A lease domain is a capability namespace, not caller input.  Production
/// lease construction must first observe a matching registration in this
/// store; a caller cannot create a new authority namespace by merely passing a
/// different `domainID`.  Registration is intentionally a separate,
/// human-gated operation.
public enum TatwoAuthorityDomainRegistryError: Error, LocalizedError, Sendable, Equatable {
    case invalidDomainID
    case domainNotRegistered(String)
    case domainAlreadyRegistered(String)
    case corruptRegistration(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDomainID:
            return "authority domain id is invalid"
        case let .domainNotRegistered(domainID):
            return "authority domain is not registered: \(domainID)"
        case let .domainAlreadyRegistered(domainID):
            return "authority domain is already registered: \(domainID)"
        case let .corruptRegistration(detail):
            return "authority domain registration is corrupt: \(detail)"
        }
    }
}

/// File-backed create-only domain registration table.
///
/// The per-domain marker files are durable and never overwritten.  The
/// implementation is deliberately small: OS-level ACLs/signatures remain the
/// production hardening layer, while the userland contract guarantees that
/// lease creation is gated by an existing durable registration.
public final class TatwoAuthorityDomainRegistryV1: @unchecked Sendable {
    public static let schemaName = "TatwoAuthorityDomainRegistrationV1"

    private let rootURL: URL
    private let lock = NSLock()

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var domainsURL: URL {
        rootURL.appendingPathComponent("domains", isDirectory: true)
    }

    public func register(
        domainID: String,
        registeredAt: Date = Date(),
        source: String = "human-confirmed"
    ) throws {
        let normalized = try Self.normalize(domainID)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(
            at: domainsURL,
            withIntermediateDirectories: true)
        let url = markerURL(for: normalized)
        if FileManager.default.fileExists(atPath: url.path) {
            throw TatwoAuthorityDomainRegistryError.domainAlreadyRegistered(normalized)
        }
        let record = TatwoAuthorityDomainRegistrationV1(
            domainID: normalized,
            registeredAt: registeredAt,
            source: source)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // The create-only check is protected by the in-process lock; callers
        // must additionally protect the root with OS ACLs for cross-process
        // adversaries.
        try encoder.encode(record).write(to: url, options: [.atomic])
    }

    public func isRegistered(domainID: String) -> Bool {
        guard let normalized = try? Self.normalize(domainID) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let url = markerURL(for: normalized)
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(
            TatwoAuthorityDomainRegistrationV1.self,
            from: data)
        else {
            return false
        }
        return record.schema == Self.schemaName && record.domainID == normalized
    }

    public func requireRegistered(domainID: String) throws {
        let normalized = try Self.normalize(domainID)
        guard isRegistered(domainID: normalized) else {
            throw TatwoAuthorityDomainRegistryError.domainNotRegistered(normalized)
        }
    }

    private func markerURL(for domainID: String) -> URL {
        domainsURL.appendingPathComponent("\(domainID).json", isDirectory: false)
    }

    private static func normalize(_ domainID: String) throws -> String {
        let normalized = domainID.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.count <= 128,
            normalized.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(
                    CharacterSet(charactersIn: "._-")).contains($0)
            })
        else {
            throw TatwoAuthorityDomainRegistryError.invalidDomainID
        }
        return normalized
    }
}

public struct TatwoAuthorityDomainRegistrationV1: Codable, Hashable, Sendable {
    public let schema: String
    public let domainID: String
    public let registeredAt: Date
    public let source: String

    public init(
        schema: String = TatwoAuthorityDomainRegistryV1.schemaName,
        domainID: String,
        registeredAt: Date,
        source: String
    ) {
        self.schema = schema
        self.domainID = domainID
        self.registeredAt = registeredAt
        self.source = source
    }
}

/// Injection point for every production control-plane mutation.
///
/// A nil `authorityDomainID` is only a test/legacy fixture mode. Production
/// bootstrap must bind a durable, registered handoff lease provider.
public protocol TatwoOriginAuthorityProviding: Sendable {
    var authorityDomainID: String? { get }
    var authorityEpoch: UInt64? { get }

    func isOriginAuthority(
        deviceID: String,
        epoch: UInt64,
        now: Date
    ) -> Bool

    func requireOriginAuthority(
        deviceID: String,
        epoch: UInt64,
        surface: String,
        now: Date
    ) throws

    func requireAuthorityLeaseAdoption(
        deviceID: String,
        epoch: UInt64,
        surface: String,
        now: Date
    ) throws
}

public extension TatwoOriginAuthorityProviding {
    func requireOriginAuthority(
        deviceID: String,
        epoch: UInt64,
        surface: String,
        now: Date
    ) throws {
        // A nil domain means this caller is on the pre-handoff path.  Keep
        // that legacy route behaviorally unchanged: authority fencing only
        // applies once a lease domain is explicitly bound.  A provider that
        // represents an unavailable production authority may override this
        // method to remain fail-closed; it is not a legacy route.
        guard authorityDomainID != nil else { return }
        guard isOriginAuthority(deviceID: deviceID, epoch: epoch, now: now) else {
            throw TatwoOriginAuthorityError.originWriteFenced(
                surface: surface,
                domainID: authorityDomainID,
                deviceID: deviceID,
                epoch: epoch
            )
        }
    }

    func requireAuthorityLeaseAdoption(
        deviceID: String,
        epoch: UInt64,
        surface: String,
        now: Date
    ) throws {
        try requireOriginAuthority(
            deviceID: deviceID,
            epoch: epoch,
            surface: surface,
            now: now
        )
    }
}

/// Default provider preserving the pre-handoff, single-device behavior.
public struct TatwoDefaultOriginAuthorityProvider: TatwoOriginAuthorityProviding {
    public let authorityDomainID: String? = nil
    public let authorityEpoch: UInt64? = nil

    public init() {}

    public func isOriginAuthority(
        deviceID: String,
        epoch: UInt64,
        now: Date
    ) -> Bool {
        true
    }
}

/// Fail-closed provider used by non-test channel construction when no sealed
/// durable handoff provider was supplied.
public struct TatwoUnavailableOriginAuthorityProvider: TatwoOriginAuthorityProviding {
    public let authorityDomainID: String? = nil
    public let authorityEpoch: UInt64? = nil

    public init() {}

    public func isOriginAuthority(
        deviceID: String,
        epoch: UInt64,
        now: Date
    ) -> Bool {
        false
    }

    /// A missing production lease is not the legacy/default no-handoff route.
    /// Keep this sentinel fail-closed even though it carries no domain ID;
    /// otherwise the nil-domain compatibility bypass would turn an absent
    /// production authority into an allow-all writer.
    public func requireOriginAuthority(
        deviceID: String,
        epoch: UInt64,
        surface: String,
        now: Date
    ) throws {
        throw TatwoOriginAuthorityError.originWriteFenced(
            surface: surface,
            domainID: authorityDomainID,
            deviceID: deviceID,
            epoch: epoch
        )
    }
}
