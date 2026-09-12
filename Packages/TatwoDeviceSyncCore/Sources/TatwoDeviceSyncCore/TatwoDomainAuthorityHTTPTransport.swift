import Foundation
import TatwoDomainContracts
import TatwoWorkReceiptContracts

/// HTTP implementation of `TatwoDomainAuthorityCoordinatorPort` against the
/// Tatwo Domain Coordinator service (`Services/TatwoDomainCoordinator`).
///
/// Mirrors `TatwoDomainCoordinatorHTTPTransport`: same client abstraction,
/// secret handling, endpoint allowlist (https-only plus loopback testing
/// escape hatch), timeout plumbing, and error mapping via
/// `TatwoDomainCoordinatorTransportErrorV1`.
public final class TatwoDomainAuthorityHTTPTransport:
    TatwoDomainAuthorityCoordinatorPort
{
    private struct HumanConfirmation: Encodable {
        let approved: Bool
        let approvalID: String
        let approvedAt: Date
    }

    private struct GrantCommand: Encodable {
        let type: String
        let domainID: String
        let deviceID: String
        let leaseEpoch: UInt64
        let fencingToken: String
        let idempotencyKey: String
        let expectedSequence: UInt64
        let expiresAt: Date
        let humanConfirmation: HumanConfirmation
        let correlationID: String
    }

    private struct GrantResponse: Decodable {
        let ok: Bool
        let code: String
        let sequence: UInt64
        let lease: GrantedLease
        let idempotentReplay: Bool?
    }

    private struct GrantedLease: Decodable {
        let domainID: String
        let holderDeviceID: String
        let leaseEpoch: UInt64
        let fencingToken: String
        let expiresAt: Date
    }

    private struct SnapshotResponse: Decodable {
        let ok: Bool
        let snapshot: SnapshotPayload
    }

    private struct SnapshotPayload: Decodable {
        let domainID: String
        let nextSequence: UInt64
        let activeLease: ActiveLeasePayload?
    }

    /// Coordinator lease shape (`core.mjs` `#grantAuthorityLease`): it emits
    /// `leaseEpoch`, snake_case `source`, and `humanApprovalID`, and does not
    /// emit `receiptMetadata`. Fields the contract's `TatwoAuthorityLeaseV1`
    /// requires but the coordinator may omit are optional here so a lease can
    /// be surfaced only when it is fully reconstructible without fabrication.
    private struct ActiveLeasePayload: Decodable {
        let domainID: String
        let holderDeviceID: String
        let leaseEpoch: UInt64
        let fencingToken: String
        let observedAt: Date
        let expiresAt: Date
        let source: String?
        let receiptMetadata: TatwoWorkReceiptMetadataV1?
    }

    private struct ErrorResponse: Decodable {
        let code: String?
    }

    private let baseURL: URL
    private let secretProvider: () -> String?
    private let client: any TatwoDomainCoordinatorHTTPClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let timeout: TimeInterval

    public init(
        baseURL: URL,
        allowInsecureLoopbackForTesting: Bool = false,
        secretProvider: @escaping () -> String?,
        client: any TatwoDomainCoordinatorHTTPClient =
            TatwoURLSessionDomainCoordinatorHTTPClient(),
        timeout: TimeInterval = 30
    ) throws {
        guard Self.isAllowedEndpoint(
            baseURL,
            allowInsecureLoopbackForTesting: allowInsecureLoopbackForTesting
        ) else {
            throw TatwoDomainCoordinatorTransportErrorV1.insecureEndpoint
        }
        self.baseURL = baseURL
        self.secretProvider = secretProvider
        self.client = client
        self.timeout = timeout
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // The coordinator serializes dates via `Date.toISOString()`, which
        // includes fractional seconds; plain `.iso8601` decoding rejects them.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = Self.parseISO8601(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(raw)"
                )
            }
            return date
        }
    }

    public func fetchSnapshotSummary(
        domainID: String
    ) throws -> TatwoCoordinatorSnapshotSummaryV1 {
        let secret = try validatedSecret()
        var request = makeRequest(
            endpoint: endpointURL(domainID: domainID, resource: "snapshot"),
            method: "GET",
            secret: secret
        )
        request.httpBody = nil

        let data = try perform(request)
        guard let decoded = try? decoder.decode(SnapshotResponse.self, from: data),
              decoded.ok
        else {
            throw TatwoDomainCoordinatorTransportErrorV1.malformedResponse
        }
        guard decoded.snapshot.domainID == domainID else {
            throw TatwoDomainCoordinatorTransportErrorV1.acknowledgementMismatch
        }

        return TatwoCoordinatorSnapshotSummaryV1(
            domainID: decoded.snapshot.domainID,
            nextSequence: decoded.snapshot.nextSequence,
            activeLease: Self.reconstructLease(decoded.snapshot.activeLease),
            activeLeaseEpoch: decoded.snapshot.activeLease?.leaseEpoch,
            activeLeaseHolderDeviceID: decoded.snapshot.activeLease?.holderDeviceID
        )
    }

    public func grantAuthorityLease(
        _ request: TatwoAuthorityLeaseGrantRequestV1
    ) throws -> TatwoAuthorityLeaseGrantAcknowledgementV1 {
        let secret = try validatedSecret()
        var urlRequest = makeRequest(
            endpoint: endpointURL(domainID: request.domainID, resource: "command"),
            method: "POST",
            secret: secret
        )
        urlRequest.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "content-type"
        )
        urlRequest.httpBody = try encoder.encode(
            GrantCommand(
                type: "grant_authority_lease",
                domainID: request.domainID,
                deviceID: request.toDeviceID,
                leaseEpoch: request.leaseEpoch,
                fencingToken: request.fencingToken,
                idempotencyKey: request.idempotencyKey,
                expectedSequence: request.expectedSequence,
                expiresAt: request.expiresAt,
                humanConfirmation: HumanConfirmation(
                    approved: true,
                    approvalID: request.approvalID,
                    approvedAt: request.approvedAt
                ),
                correlationID: request.correlationID
            )
        )

        let data = try perform(urlRequest)
        guard let decoded = try? decoder.decode(GrantResponse.self, from: data),
              decoded.ok,
              decoded.code == "authority_lease_granted"
        else {
            throw TatwoDomainCoordinatorTransportErrorV1.malformedResponse
        }
        guard decoded.lease.domainID == request.domainID,
              decoded.lease.holderDeviceID == request.toDeviceID,
              decoded.lease.leaseEpoch == request.leaseEpoch,
              decoded.lease.fencingToken == request.fencingToken
        else {
            throw TatwoDomainCoordinatorTransportErrorV1.acknowledgementMismatch
        }

        return TatwoAuthorityLeaseGrantAcknowledgementV1(
            code: decoded.code,
            sequence: decoded.sequence,
            holderDeviceID: decoded.lease.holderDeviceID,
            leaseEpoch: decoded.lease.leaseEpoch,
            fencingToken: decoded.lease.fencingToken,
            expiresAt: decoded.lease.expiresAt,
            idempotentReplay: decoded.idempotentReplay ?? false
        )
    }

    // MARK: - Shared plumbing

    private func validatedSecret() throws -> String {
        guard let secret = secretProvider(),
              secret.utf8.count >= 32,
              secret.utf8.count <= 4_096,
              secret.unicodeScalars.allSatisfy({
                  $0.value > 0x20 && $0.value != 0x7F
              })
        else {
            throw TatwoDomainCoordinatorTransportErrorV1.credentialMissing
        }
        return secret
    }

    private func endpointURL(domainID: String, resource: String) -> URL {
        baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("domains", isDirectory: true)
            .appendingPathComponent(domainID, isDirectory: true)
            .appendingPathComponent(resource, isDirectory: false)
    }

    private func makeRequest(
        endpoint: URL,
        method: String,
        secret: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        return request
    }

    private func perform(_ request: URLRequest) throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try client.send(request)
        } catch {
            throw TatwoDomainCoordinatorTransportErrorV1.unavailable
        }
        guard (200...299).contains(response.statusCode) else {
            let code = (try? decoder.decode(ErrorResponse.self, from: data).code)
                ?? "http_\(response.statusCode)"
            throw TatwoDomainCoordinatorTransportErrorV1.remoteRejected(
                statusCode: response.statusCode,
                code: code
            )
        }
        return data
    }

    /// Rebuilds a contract lease only when the coordinator response carries
    /// every required field. `core.mjs` currently returns no
    /// `receiptMetadata`, and `TatwoAuthorityLeaseV1.receiptMetadata` is
    /// non-optional, so rather than fabricating placeholder metadata the
    /// summary reports `nil` for a lease it cannot faithfully reconstruct.
    private static func reconstructLease(
        _ payload: ActiveLeasePayload?
    ) -> TatwoAuthorityLeaseV1? {
        guard let payload,
              let receiptMetadata = payload.receiptMetadata,
              let source = mapLeaseSource(payload.source)
        else {
            return nil
        }
        return TatwoAuthorityLeaseV1(
            domainID: payload.domainID,
            holderDeviceID: payload.holderDeviceID,
            epoch: payload.leaseEpoch,
            fencingToken: payload.fencingToken,
            observedAt: payload.observedAt,
            expiresAt: payload.expiresAt,
            source: source,
            receiptMetadata: receiptMetadata
        )
    }

    private static func mapLeaseSource(
        _ raw: String?
    ) -> TatwoAuthorityLeaseSourceV1? {
        switch raw {
        case "human_confirmed", "humanConfirmed":
            .humanConfirmed
        case "imported_verified_receipt", "importedVerifiedReceipt":
            .importedVerifiedReceipt
        default:
            nil
        }
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func isAllowedEndpoint(
        _ url: URL,
        allowInsecureLoopbackForTesting: Bool
    ) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return false
        }
        if scheme == "https" {
            return true
        }
        guard scheme == "http", allowInsecureLoopbackForTesting else {
            return false
        }
        return ["127.0.0.1", "::1", "localhost"].contains(host)
    }
}
