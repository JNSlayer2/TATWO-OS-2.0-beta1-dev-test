import Darwin
import Foundation

enum RemoteHostLinkError: Error, LocalizedError {
    case sshHomeLookupFailed(String)
    case tunnelStartFailed(String)
    case tunnelUnavailable
    case socketPathTooLong
    case connectFailed(Int32)
    case invalidResponse
    case remoteError(String)

    var errorDescription: String? {
        switch self {
        case .sshHomeLookupFailed(let detail): "ssh_home_lookup_failed: \(detail)"
        case .tunnelStartFailed(let detail): "ssh_tunnel_start_failed: \(detail)"
        case .tunnelUnavailable: "ssh_tunnel_unavailable"
        case .socketPathTooLong: "unix_socket_path_too_long"
        case .connectFailed(let code): "unix_socket_connect_failed: errno=\(code)"
        case .invalidResponse: "invalid_json_rpc_response"
        case .remoteError(let detail): "remote_error: \(detail)"
        }
    }
}

/// R2 的 App-to-App SSH socket 轉發。這層只管連線、重連與 JSON-RPC，不碰 SSH 設定。
final class RemoteHostLink: @unchecked Sendable {
    private let environment: [String: String]
    private let lock = NSLock()
    private let reconnectQueue = DispatchQueue(label: "ai.tatwo.tatwo2.remote-reconnect", qos: .utility)
    private var device: DeviceRecord?
    private var tunnel: Process?
    private var remoteSocketPath: String?
    private var reconnectDelay: TimeInterval = 1
    private var reconnectScheduled = false
    private var wantsConnection = false

    let localSocketPath: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        self.localSocketPath = "/tmp/t2-r-\(UUID().uuidString.lowercased().prefix(12)).sock"
    }

    deinit {
        disconnect()
    }

    func connect(device: DeviceRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        wantsConnection = true
        self.device = device
        remoteSocketPath = try resolveRemoteSocketPath(device)
        try startTunnelLocked(device: device)
        _ = try callLocked(method: "get_document", params: [:])
        reconnectDelay = 1
    }

    func disconnect() {
        lock.lock()
        wantsConnection = false
        reconnectScheduled = false
        let process = tunnel
        tunnel = nil
        lock.unlock()
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        _ = unlink(localSocketPath)
    }

    func call(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try callLocked(method: method, params: params)
        } catch {
            scheduleReconnectLocked()
            throw error
        }
    }

    private func resolveRemoteSocketPath(_ device: DeviceRecord) throws -> String {
        if let override = environment["TATWO2_REMOTE_OS_SOCKET"], !override.isEmpty {
            return override
        }
        let home = try sshHome(device)
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/tatwo2/live/os.sock")
            .path
    }

    private func sshHome(_ device: DeviceRecord) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshBaseArguments(device) + ["\(device.user)@\(device.host)", "echo $HOME"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw RemoteHostLinkError.sshHomeLookupFailed(error.localizedDescription)
        }
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else {
            throw RemoteHostLinkError.sshHomeLookupFailed(
                "exit=\(process.terminationStatus) \(String(text.prefix(240)))")
        }
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
    }

    private func startTunnelLocked(device: DeviceRecord) throws {
        if let tunnel, tunnel.isRunning, FileManager.default.fileExists(atPath: localSocketPath) {
            return
        }
        tunnel?.terminationHandler = nil
        if tunnel?.isRunning == true { tunnel?.terminate() }
        tunnel = nil
        _ = unlink(localSocketPath)
        guard let remoteSocketPath else { throw RemoteHostLinkError.tunnelUnavailable }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshBaseArguments(device) + [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localSocketPath):\(remoteSocketPath)",
            "\(device.user)@\(device.host)",
        ]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.tunnel = nil
            self.scheduleReconnectLocked()
            self.lock.unlock()
        }
        do {
            try process.run()
        } catch {
            throw RemoteHostLinkError.tunnelStartFailed(error.localizedDescription)
        }
        tunnel = process

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !process.isRunning {
                throw RemoteHostLinkError.tunnelStartFailed("ssh exited before forward became ready")
            }
            if FileManager.default.fileExists(atPath: localSocketPath) { return }
            usleep(50_000)
        }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        tunnel = nil
        throw RemoteHostLinkError.tunnelUnavailable
    }

    private func sshBaseArguments(_ device: DeviceRecord) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8",
            "-p", String(device.sshPort),
        ]
    }

    private func callLocked(method: String, params: [String: Any]) throws -> [String: Any] {
        guard wantsConnection, let device else { throw RemoteHostLinkError.tunnelUnavailable }
        try startTunnelLocked(device: device)
        let request: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "method": method,
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw RemoteHostLinkError.invalidResponse
        }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        let responseData = try transact(data)
        guard
            let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let ok = response["ok"] as? Bool
        else {
            throw RemoteHostLinkError.invalidResponse
        }
        guard ok else {
            throw RemoteHostLinkError.remoteError(response["error"] as? String ?? "unknown")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw RemoteHostLinkError.invalidResponse
        }
        reconnectDelay = 1
        return result
    }

    private func transact(_ data: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteHostLinkError.connectFailed(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = localSocketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strlcpy(destination, source, capacity)
            }
        }
        guard copied < capacity else { throw RemoteHostLinkError.socketPathTooLong }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw RemoteHostLinkError.connectFailed(errno) }
        // 對端慢或睡著時不能無限等（03:41／03:52 兩次主執行緒卡死就是這裡）：收發各 10 秒
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try handle.write(contentsOf: data)
        _ = Darwin.shutdown(fd, SHUT_WR)
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 65536) }
            if n > 0 { out.append(contentsOf: chunk[0..<n]); if out.last == 0x0A { break }; continue }
            if n == 0 { break }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw RemoteHostLinkError.invalidResponse }   // 逾時
            if errno == EINTR { continue }
            throw RemoteHostLinkError.connectFailed(errno)
        }
        return out
    }

    private func scheduleReconnectLocked() {
        guard wantsConnection, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        reconnectQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.reconnectScheduled = false
            guard self.wantsConnection, let device = self.device else {
                self.lock.unlock()
                return
            }
            do {
                try self.startTunnelLocked(device: device)
                _ = try self.callLocked(method: "get_document", params: [:])
                self.reconnectDelay = 1
            } catch {
                self.scheduleReconnectLocked()
            }
            self.lock.unlock()
        }
    }
}
