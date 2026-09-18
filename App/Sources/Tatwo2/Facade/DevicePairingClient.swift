import Foundation
import CryptoKit
import Network

final class DevicePairingClient: @unchecked Sendable {
    private struct PairRequest: Codable {
        let code: String
        let publicKey: String
        let name: String
        var user: String?      // 副機自己的登入名，主機記名單用（2026-09-05 真雙機抓到兩邊都記成自己）
        var deviceID: String?
        // 加入端自報的兩把公鑰指紋：客戶端金鑰讓主機交叉核對送來的公鑰，
        // 主機金鑰讓主機之後能 pin 住反向隧道（舊版主機沒有這兩欄，照樣相容）。
        var clientKeyFingerprint: String?
        var hostKeyFingerprint: String?
    }

    private struct PairResponse: Codable {
        let ok: Bool
        var deviceID: String?
        var hostName: String?
        var hostUser: String?   // 主機的登入名，副機之後 ssh 要用
        var reason: String?
        var hostDeviceID: String?
        // 產生配對碼端自報的兩把公鑰指紋。主機金鑰用來跟 ssh-keyscan 的結果交叉核對，
        // 客戶端金鑰讓加入端之後能驗主機送來的 RPC 簽章。
        var hostKeyFingerprint: String?
        var clientKeyFingerprint: String?
    }

    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        var result: Result<PairResponse, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        func resolve(_ value: Result<PairResponse, Error>) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            result = value
            lock.unlock()
            semaphore.signal()
        }
    }

    enum ClientError: Error, LocalizedError {
        case invalidHost
        case invalidPort
        case keyGenerationFailed(String)
        case publicKeyUnreadable
        case connectionTimedOut
        case responseInvalid
        case pairingRejected(String)
        case sshVerificationFailed
        case hostFingerprintUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidHost: "invalid_host"
            case .invalidPort: "invalid_port"
            case let .keyGenerationFailed(reason): "ssh_keygen_failed:\(reason)"
            case .publicKeyUnreadable: "ssh_public_key_unreadable"
            case .connectionTimedOut: "pairing_connection_timed_out"
            case .responseInvalid: "pairing_response_invalid"
            case let .pairingRejected(reason): "pairing_rejected:\(reason)"
            case .sshVerificationFailed: "ssh_batch_mode_verification_failed"
            case .hostFingerprintUnavailable: "ssh_host_fingerprint_unavailable"
            }
        }
    }

    private let registry: DeviceRegistry
    private let entry: TatwoEntry
    private let environment: [String: String]
    private let privateKeyURL: URL
    private let sshVerifier: (String) -> Bool
    private let hostFingerprintResolver: (String) -> String?
    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.device-pairing-client")

    init(
        registry: DeviceRegistry? = nil,
        privateKeyURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sshVerifier: ((String) -> Bool)? = nil,
        hostFingerprintResolver: ((String) -> String?)? = nil
    ) {
        self.registry = registry ?? DeviceRegistry(environment: environment)
        self.entry = TatwoEntry(environment: environment)
        self.environment = environment
        let resolvedPrivateKeyURL = privateKeyURL
            ?? environment["TATWO2_SSH_KEY_PATH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519")
        self.privateKeyURL = resolvedPrivateKeyURL
        self.sshVerifier = sshVerifier ?? {
            Self.verifySSH(host: $0, privateKeyURL: resolvedPrivateKeyURL, environment: environment)
        }
        self.hostFingerprintResolver = hostFingerprintResolver ?? Self.resolveHostFingerprint
    }

    @discardableResult
    func pair(host: String, port: Int, code: String, name: String) throws -> DeviceRecord {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanHost.contains(where: \.isWhitespace) else {
            throw ClientError.invalidHost
        }
        guard (1...65_535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ClientError.invalidPort
        }
        let publicKey = try ensurePublicKey()
        // A first pairing adopts the host-issued UUID; an already identified device keeps it.
        let local = try DeviceIdentityStore.readLocal(entry: entry)
        let request = PairRequest(
            code: code.uppercased(), publicKey: publicKey, name: name, user: NSUserName(),
            deviceID: local?.deviceID,
            clientKeyFingerprint: try? DeviceRegistry.fingerprint(publicKey: publicKey),
            hostKeyFingerprint: DeviceRegistry.localHostKeyFingerprint(environment: environment))
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)

        let connection = NWConnection(host: NWEndpoint.Host(cleanHost), port: nwPort, using: .tcp)
        let reply = ReplyBox()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        reply.resolve(.failure(error))
                        connection.cancel()
                    } else {
                        self?.receiveLine(from: connection, buffer: Data(), reply: reply)
                    }
                })
            case let .failed(error):
                reply.resolve(.failure(error))
                connection.cancel()
            case let .waiting(error):
                reply.resolve(.failure(error))
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard reply.semaphore.wait(timeout: .now() + 12) == .success else {
            connection.cancel()
            throw ClientError.connectionTimedOut
        }
        connection.cancel()
        let response: PairResponse
        switch reply.result {
        case let .success(value): response = value
        case let .failure(error): throw error
        case .none: throw ClientError.responseInvalid
        }
        guard response.ok else {
            throw ClientError.pairingRejected(response.reason ?? "unknown")
        }
        // Older hosts (before W76) do not return hostDeviceID. Accept that during the
        // two-device upgrade window: derive a stable per-host ID instead of failing pairing.
        guard let deviceID = response.deviceID, let hostName = response.hostName else {
            throw ClientError.responseInvalid
        }
        let hostDeviceID = response.hostDeviceID
            ?? UUID(uuidString: Self.legacyHostID(host: cleanHost, name: hostName))?.uuidString
            ?? UUID().uuidString
        guard UUID(uuidString: deviceID) != nil, UUID(uuidString: hostDeviceID) != nil,
              deviceID.lowercased() != hostDeviceID.lowercased(),
              local.map({ $0.deviceID.lowercased() == deviceID.lowercased() }) ?? true
        else {
            throw ClientError.responseInvalid
        }
        let hostUser = response.hostUser ?? NSUserName()
        guard sshVerifier("\(hostUser)@\(cleanHost)") else {
            throw ClientError.sshVerificationFailed
        }
        guard let fingerprint = hostFingerprintResolver(cleanHost) else {
            throw ClientError.hostFingerprintUnavailable
        }
        // pin 住的永遠是這裡實際掃到的主機金鑰（跟分流前同一個值）。主機自報的那把只當佐證：
        // 一致就把來源記成 pairing，不一致（例如 sshd 用的不是預設 host key）就記成 ssh_keyscan，
        // 不會改掉 pin 的值，也不會因為對方自報而多信任什麼。
        let hostKeySource = response.hostKeyFingerprint == fingerprint ? "pairing" : "ssh_keyscan"
        // 主機的客戶端金鑰指紋只在格式正確時收下；收不到就留空，之後 RPC 照樣擋。
        let peerClientKey = response.clientKeyFingerprint.flatMap { $0.hasPrefix("SHA256:") ? $0 : nil }
        _ = try DeviceIdentityStore.forLocalDevice(entry: entry, pairedDeviceID: deviceID, name: name)
        let now = Date()
        return try registry.recordPairedHost(DeviceRecord(
            id: hostDeviceID.lowercased(),
            name: hostName,
            host: cleanHost,
            user: hostUser,
            sshPort: 22,
            publicKeyFingerprint: fingerprint,
            addedAt: now, lastSeenAt: now, workdirMap: [:],
            hostKeyFingerprint: fingerprint,
            clientKeyFingerprint: peerClientKey,
            hostKeyFingerprintSource: .init(source: hostKeySource, recordedAt: now),
            clientKeyFingerprintSource: peerClientKey.map { _ in
                .init(source: "pairing", recordedAt: now) }),
            localDeviceID: deviceID)
    }

    /// Deterministic UUID-shaped ID for a pre-W76 host (name-based, lowercase hex).
    static func legacyHostID(host: String, name: String) -> String {
        let digest = Array(SHA256.hash(data: Data("tatwo-legacy-host:\(host.lowercased()):\(name)".utf8)))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-5\(String(c[13..<16]))-a\(String(c[17..<20]))-\(String(c[20..<32]))"
    }

    private func ensurePublicKey() throws -> String {
        let publicURL = URL(fileURLWithPath: privateKeyURL.path + ".pub")
        if !FileManager.default.fileExists(atPath: publicURL.path) {
            try FileManager.default.createDirectory(
                at: privateKeyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let result = Self.run(
                executable: "/usr/bin/ssh-keygen",
                arguments: ["-t", "ed25519", "-N", "", "-f", privateKeyURL.path])
            guard result.status == 0 else {
                throw ClientError.keyGenerationFailed(result.output)
            }
        }
        guard let value = try? String(contentsOf: publicURL, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ClientError.publicKeyUnreadable
        }
        return value
    }

    private func receiveLine(from connection: NWConnection, buffer: Data, reply: ReplyBox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else {
                reply.resolve(.failure(ClientError.responseInvalid))
                return
            }
            var joined = buffer
            if let data { joined.append(data) }
            if joined.count > 65_536 {
                reply.resolve(.failure(ClientError.responseInvalid))
                return
            }
            if let newline = joined.firstIndex(of: 0x0A) {
                self.decodeReply(Data(joined[..<newline]), into: reply)
            } else if complete || error != nil {
                if let error {
                    reply.resolve(.failure(error))
                } else {
                    self.decodeReply(joined, into: reply)
                }
            } else {
                self.receiveLine(from: connection, buffer: joined, reply: reply)
            }
        }
    }

    private func decodeReply(_ data: Data, into reply: ReplyBox) {
        guard let response = try? JSONDecoder().decode(PairResponse.self, from: data) else {
            reply.resolve(.failure(ClientError.responseInvalid))
            return
        }
        reply.resolve(.success(response))
    }

    private static func verifySSH(
        host: String,
        privateKeyURL: URL,
        environment: [String: String]
    ) -> Bool {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
        ]
        if environment["TATWO2_SSH_KNOWN_HOSTS"] == nil {
            arguments += ["-o", "StrictHostKeyChecking=accept-new"]   // 第一次連新主機不能卡在 host key 詢問
        }
        if let knownHosts = environment["TATWO2_SSH_KNOWN_HOSTS"], !knownHosts.isEmpty {
            arguments += [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(knownHosts)",
            ]
        }
        if environment["TATWO2_SSH_KEY_PATH"] != nil {
            arguments += ["-i", privateKeyURL.path]
        }
        arguments += [host, "echo", "ok"]
        let result = run(
            executable: "/usr/bin/ssh",
            arguments: arguments)
        return result.status == 0 && result.output.split(whereSeparator: \.isNewline).contains("ok")
    }

    private static func resolveHostFingerprint(host: String) -> String? {
        let result = run(
            executable: "/usr/bin/ssh-keyscan",
            arguments: ["-T", "5", "-p", "22", host])
        guard result.status == 0 || !result.output.isEmpty else { return nil }
        let keys = result.output.split(whereSeparator: \.isNewline).map(String.init)
        guard let line = keys.first(where: { $0.contains(" ssh-ed25519 ") }),
              let keyStart = line.range(of: "ssh-ed25519 ")
        else { return nil }
        return try? DeviceRegistry.fingerprint(publicKey: String(line[keyStart.lowerBound...]))
    }

    private static func run(executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
