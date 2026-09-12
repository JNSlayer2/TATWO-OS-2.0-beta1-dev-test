import Foundation
import TatwoDomainContracts

public protocol TatwoDomainCoordinatorHTTPClient: AnyObject {
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
}

public final class TatwoURLSessionDomainCoordinatorHTTPClient:
    TatwoDomainCoordinatorHTTPClient,
    @unchecked Sendable
{
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<(Data, HTTPURLResponse), Error>?

        func store(_ result: Result<(Data, HTTPURLResponse), Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func load() -> Result<(Data, HTTPURLResponse), Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 30
    ) {
        self.session = session
        self.timeout = timeout
    }

    public func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.store(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                box.store(.failure(URLError(.badServerResponse)))
                return
            }
            box.store(.success((data ?? Data(), response)))
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw URLError(.timedOut)
        }
        guard let result = box.load() else {
            throw URLError(.unknown)
        }
        return try result.get()
    }
}

public final class TatwoDomainCoordinatorHTTPTransport:
    TatwoDomainCoordinatorTransportPort
{
    private struct AppendCommand: Encodable {
        let type: String
        let domainID: String
        let deviceID: String
        let leaseEpoch: UInt64
        let fencingToken: String
        let idempotencyKey: String
        let expectedSequence: UInt64
        let schemaVersion: Int
        let protocolVersion: Int
        let eventID: String
        let eventKind: TatwoDomainEventKindV1
        let payloadClass: TatwoDomainPayloadClassV1
        let payload: TatwoDomainJSONValueV1
        let payloadDigest: String
        let occurredAt: Date
        let correlationID: String
    }

    private struct AppendResponse: Decodable {
        let ok: Bool
        let code: String
        let sequence: UInt64
        let eventID: String
        let idempotencyKey: String
        let payloadDigest: String
        let idempotentReplay: Bool?
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
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(
        event: TatwoDomainEventV1,
        correlationID: String
    ) throws -> TatwoDomainCoordinatorAppendAcknowledgementV1 {
        guard let secret = secretProvider(),
              secret.utf8.count >= 32,
              secret.utf8.count <= 4_096,
              secret.unicodeScalars.allSatisfy({
                  $0.value > 0x20 && $0.value != 0x7F
              })
        else {
            throw TatwoDomainCoordinatorTransportErrorV1.credentialMissing
        }

        let endpoint = baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("domains", isDirectory: true)
            .appendingPathComponent(event.domainID, isDirectory: true)
            .appendingPathComponent("command", isDirectory: false)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "content-type"
        )
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        request.httpBody = try encoder.encode(
            AppendCommand(
                type: "append_domain_event",
                domainID: event.domainID,
                deviceID: event.deviceID,
                leaseEpoch: event.leaseEpoch,
                fencingToken: event.fencingToken,
                idempotencyKey: event.idempotencyKey,
                expectedSequence: event.sequence,
                schemaVersion: event.schemaVersion,
                protocolVersion: event.protocolVersion,
                eventID: event.eventID,
                eventKind: event.kind,
                payloadClass: event.payloadClass,
                payload: event.payload,
                payloadDigest: event.payloadDigest,
                occurredAt: event.observedAt,
                correlationID: correlationID
            )
        )

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
        guard let decoded = try? decoder.decode(AppendResponse.self, from: data),
              decoded.ok,
              ["domain_event_appended", "domain_event_duplicate"].contains(decoded.code)
        else {
            throw TatwoDomainCoordinatorTransportErrorV1.malformedResponse
        }
        guard decoded.eventID == event.eventID,
              decoded.idempotencyKey == event.idempotencyKey,
              decoded.sequence == event.sequence,
              decoded.payloadDigest == event.payloadDigest
        else {
            throw TatwoDomainCoordinatorTransportErrorV1.acknowledgementMismatch
        }

        return TatwoDomainCoordinatorAppendAcknowledgementV1(
            code: decoded.code,
            eventID: decoded.eventID,
            idempotencyKey: decoded.idempotencyKey,
            sequence: decoded.sequence,
            payloadDigest: decoded.payloadDigest,
            idempotentReplay: decoded.idempotentReplay ?? false
        )
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
