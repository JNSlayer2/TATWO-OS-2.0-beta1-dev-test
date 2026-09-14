import Foundation
import TatwoDomainContracts
import XCTest

@testable import TatwoDeviceSyncCore

final class TatwoDomainAuthorityHTTPTransportTests: XCTestCase {
    private static let secret = String(repeating: "s", count: 48)

    private func makeTransport(
        client: AuthorityStubHTTPClient,
        baseURL: URL = URL(string: "https://sync.example.invalid")!,
        allowInsecureLoopbackForTesting: Bool = false,
        secret: String? = TatwoDomainAuthorityHTTPTransportTests.secret
    ) throws -> TatwoDomainAuthorityHTTPTransport {
        try TatwoDomainAuthorityHTTPTransport(
            baseURL: baseURL,
            allowInsecureLoopbackForTesting: allowInsecureLoopbackForTesting,
            secretProvider: { secret },
            client: client
        )
    }

    private func makeGrantRequest() -> TatwoAuthorityLeaseGrantRequestV1 {
        TatwoAuthorityLeaseGrantRequestV1(
            domainID: "studio",
            toDeviceID: "mini",
            leaseEpoch: 1,
            fencingToken: "fence-1",
            expectedSequence: 1,
            expiresAt: Date(timeIntervalSince1970: 1_000),
            approvalID: "approval-1",
            approvedAt: Date(timeIntervalSince1970: 500),
            idempotencyKey: "idem-1",
            correlationID: "corr-1"
        )
    }

    func testGrantAuthorityLeaseRoundTripSendsCoordinatorCommandSchema() throws {
        let client = AuthorityStubHTTPClient()
        client.responseBody = try JSONSerialization.data(
            withJSONObject: [
                "ok": true,
                "code": "authority_lease_granted",
                "sequence": 1,
                "lease": [
                    "schema": "TatwoAuthorityLeaseV1",
                    "domainID": "studio",
                    "holderDeviceID": "mini",
                    "leaseEpoch": 1,
                    "fencingToken": "fence-1",
                    "observedAt": "1970-01-01T00:08:00.000Z",
                    "expiresAt": "1970-01-01T00:16:40.000Z",
                    "source": "human_confirmed",
                    "humanApprovalID": "approval-1"
                ],
                "idempotentReplay": false,
                "mutated": true
            ],
            options: [.sortedKeys]
        )
        let transport = try makeTransport(client: client)

        let acknowledgement = try transport.grantAuthorityLease(makeGrantRequest())

        XCTAssertEqual(acknowledgement.code, "authority_lease_granted")
        XCTAssertEqual(acknowledgement.sequence, 1)
        XCTAssertEqual(acknowledgement.holderDeviceID, "mini")
        XCTAssertEqual(acknowledgement.leaseEpoch, 1)
        XCTAssertEqual(acknowledgement.fencingToken, "fence-1")
        XCTAssertEqual(
            acknowledgement.expiresAt,
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertFalse(acknowledgement.idempotentReplay)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/domains/studio/command")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "authorization"),
            "Bearer \(Self.secret)"
        )
        let body = try XCTUnwrap(request.httpBody)
        let command = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(command["type"] as? String, "grant_authority_lease")
        XCTAssertEqual(command["domainID"] as? String, "studio")
        XCTAssertEqual(command["deviceID"] as? String, "mini")
        XCTAssertEqual(command["leaseEpoch"] as? Int, 1)
        XCTAssertEqual(command["fencingToken"] as? String, "fence-1")
        XCTAssertEqual(command["idempotencyKey"] as? String, "idem-1")
        XCTAssertEqual(command["expectedSequence"] as? Int, 1)
        XCTAssertEqual(command["correlationID"] as? String, "corr-1")
        let confirmation = try XCTUnwrap(
            command["humanConfirmation"] as? [String: Any]
        )
        XCTAssertEqual(confirmation["approved"] as? Bool, true)
        XCTAssertEqual(confirmation["approvalID"] as? String, "approval-1")
        XCTAssertNotNil(confirmation["approvedAt"] as? String)
    }

    func testGrantAuthorityLeaseMaps401ToRemoteRejected() throws {
        let client = AuthorityStubHTTPClient()
        client.statusCode = 401
        client.responseBody = try JSONSerialization.data(
            withJSONObject: [
                "ok": false,
                "code": "unauthorized",
                "detail": "Coordinator credential rejected"
            ],
            options: [.sortedKeys]
        )
        let transport = try makeTransport(client: client)

        XCTAssertThrowsError(
            try transport.grantAuthorityLease(makeGrantRequest())
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .remoteRejected(statusCode: 401, code: "unauthorized")
            )
        }
    }

    func testInitRejectsNonHTTPSNonLoopbackEndpoints() throws {
        XCTAssertThrowsError(
            try makeTransport(
                client: AuthorityStubHTTPClient(),
                baseURL: URL(string: "http://example.com")!
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .insecureEndpoint
            )
        }
        XCTAssertThrowsError(
            try makeTransport(
                client: AuthorityStubHTTPClient(),
                baseURL: URL(string: "http://" + [192, 168, 1, 10].map(String.init).joined(separator: ".") + ":18789")!,
                allowInsecureLoopbackForTesting: true
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .insecureEndpoint
            )
        }
        XCTAssertNoThrow(
            try makeTransport(
                client: AuthorityStubHTTPClient(),
                baseURL: URL(string: "http://127.0.0.1:18789")!,
                allowInsecureLoopbackForTesting: true
            )
        )
    }

    func testMalformedJSONMapsToMalformedResponse() throws {
        let client = AuthorityStubHTTPClient()
        client.responseBody = Data("not json".utf8)
        let transport = try makeTransport(client: client)

        XCTAssertThrowsError(
            try transport.grantAuthorityLease(makeGrantRequest())
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .malformedResponse
            )
        }
        XCTAssertThrowsError(
            try transport.fetchSnapshotSummary(domainID: "studio")
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .malformedResponse
            )
        }
    }

    func testFetchSnapshotSummaryWithoutLeaseReturnsNilActiveLease() throws {
        let client = AuthorityStubHTTPClient()
        client.responseBody = try JSONSerialization.data(
            withJSONObject: [
                "ok": true,
                "snapshot": [
                    "schema": "TatwoDomainCoordinatorSnapshotV1",
                    "domainID": "studio",
                    "nextSequence": 7,
                    "activeLease": NSNull(),
                    "events": []
                ]
            ],
            options: [.sortedKeys]
        )
        let transport = try makeTransport(client: client)

        let summary = try transport.fetchSnapshotSummary(domainID: "studio")

        XCTAssertEqual(summary.domainID, "studio")
        XCTAssertEqual(summary.nextSequence, 7)
        XCTAssertNil(summary.activeLease)
        XCTAssertNil(summary.activeLeaseEpoch)
        XCTAssertNil(summary.activeLeaseHolderDeviceID)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/domains/studio/snapshot")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "authorization"),
            "Bearer \(Self.secret)"
        )
    }

    func testFetchSnapshotSummaryDoesNotFabricateLeaseWithoutReceiptMetadata() throws {
        let client = AuthorityStubHTTPClient()
        client.responseBody = try JSONSerialization.data(
            withJSONObject: [
                "ok": true,
                "snapshot": [
                    "schema": "TatwoDomainCoordinatorSnapshotV1",
                    "domainID": "studio",
                    "nextSequence": 2,
                    "activeLease": [
                        "schema": "TatwoAuthorityLeaseV1",
                        "domainID": "studio",
                        "holderDeviceID": "mini",
                        "leaseEpoch": 1,
                        "fencingToken": "fence-1",
                        "observedAt": "1970-01-01T00:08:00.000Z",
                        "expiresAt": "1970-01-01T00:16:40.000Z",
                        "source": "human_confirmed",
                        "humanApprovalID": "approval-1"
                    ],
                    "events": []
                ]
            ],
            options: [.sortedKeys]
        )
        let transport = try makeTransport(client: client)

        let summary = try transport.fetchSnapshotSummary(domainID: "studio")

        XCTAssertEqual(summary.nextSequence, 2)
        // core.mjs leases carry no receiptMetadata; the contract lease
        // requires it, so the summary must report nil instead of fabricating.
        XCTAssertNil(summary.activeLease)
        // The lightweight lease facts are still surfaced from the raw
        // coordinator JSON without fabricating receiptMetadata.
        XCTAssertEqual(summary.activeLeaseEpoch, 1)
        XCTAssertEqual(summary.activeLeaseHolderDeviceID, "mini")
    }

    func testFetchSnapshotSummaryRejectsDomainMismatch() throws {
        let client = AuthorityStubHTTPClient()
        client.responseBody = try JSONSerialization.data(
            withJSONObject: [
                "ok": true,
                "snapshot": [
                    "schema": "TatwoDomainCoordinatorSnapshotV1",
                    "domainID": "other",
                    "nextSequence": 1,
                    "activeLease": NSNull(),
                    "events": []
                ]
            ],
            options: [.sortedKeys]
        )
        let transport = try makeTransport(client: client)

        XCTAssertThrowsError(
            try transport.fetchSnapshotSummary(domainID: "studio")
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .acknowledgementMismatch
            )
        }
    }

    func testGrantAuthorityLeaseRejectsAcknowledgementMismatch() throws {
        let client = AuthorityStubHTTPClient()
        client.responseBody = try JSONSerialization.data(
            withJSONObject: [
                "ok": true,
                "code": "authority_lease_granted",
                "sequence": 1,
                "lease": [
                    "domainID": "studio",
                    "holderDeviceID": "other-device",
                    "leaseEpoch": 1,
                    "fencingToken": "fence-1",
                    "observedAt": "1970-01-01T00:08:00.000Z",
                    "expiresAt": "1970-01-01T00:16:40.000Z"
                ],
                "idempotentReplay": false
            ],
            options: [.sortedKeys]
        )
        let transport = try makeTransport(client: client)

        XCTAssertThrowsError(
            try transport.grantAuthorityLease(makeGrantRequest())
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .acknowledgementMismatch
            )
        }
    }

    func testInvalidSecretMapsToCredentialMissing() throws {
        let transport = try makeTransport(
            client: AuthorityStubHTTPClient(),
            secret: String(repeating: "s", count: 31) + "\n"
        )

        XCTAssertThrowsError(
            try transport.fetchSnapshotSummary(domainID: "studio")
        ) { error in
            XCTAssertEqual(
                error as? TatwoDomainCoordinatorTransportErrorV1,
                .credentialMissing
            )
        }
    }
}

private final class AuthorityStubHTTPClient: TatwoDomainCoordinatorHTTPClient {
    var responseBody = Data()
    var statusCode = 200
    var thrownError: Error?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let thrownError {
            throw thrownError
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/2",
            headerFields: ["content-type": "application/json"]
        )!
        return (responseBody, response)
    }
}
