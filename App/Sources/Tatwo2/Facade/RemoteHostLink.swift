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
    private var statusProbeOnly = false
    private var pinnedHostsFile: URL?
    private var pinnedHostAlgorithm: String?
    /// 這次 pin 中的主機金鑰指紋，隧道成功後用來補記來源。
    private var pinnedHostFingerprint: String?
    private var activeEndpoint: DeviceEndpoint?
    private var endpointDeadline: Date?

    let localSocketPath: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        self.localSocketPath = "/tmp/t2-r-\(UUID().uuidString.lowercased().prefix(12)).sock"
    }

    deinit {
        disconnect()
        if let pinnedHostsFile { try? FileManager.default.removeItem(at: pinnedHostsFile) }
    }

    /// A dedicated RPC link authenticated against the pairing record's SSH HOST key.
    /// Do not use this with a record representing an inbound client key. No TOFU here.
    func callPinned(device: DeviceRecord, method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard tunnel == nil, !wantsConnection else { throw RemoteHostLinkError.invalidResponse }
        statusProbeOnly = true
        wantsConnection = true
        self.device = device
        defer {
            wantsConnection = false
            tunnel?.terminationHandler = nil
            if tunnel?.isRunning == true { tunnel?.terminate() }
            tunnel = nil
            _ = unlink(localSocketPath)
        }
        try establishLocked(device)
        return try callLocked(method: method, params: params)
    }

    /// Reuse the exact host-key pin established by callPinned; push only a captured
    /// commit into an inbox ref, never the primary's checked-out branch.
    func pushPinned(device: DeviceRecord, repository: String, localRepository: URL,
                    commit: String, ref: String) throws {
        guard pinnedHostsFile != nil, self.device?.id == device.id,
              !device.user.hasPrefix("-"), !device.host.hasPrefix("-"),
              device.user.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              device.host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              ref.hasPrefix("refs/heads/inbox/") else { throw RemoteHostLinkError.invalidResponse }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = localRepository
        var env = sshEnvironment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_SSH_COMMAND"] = (["/usr/bin/ssh"] + (try sshBaseArguments(device))).map(quote).joined(separator: " ")
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        process.arguments = ["-c", "core.hooksPath=/dev/null", "push", "--",
            "\(sshDestination(device)):\(repository)", "\(commit):\(ref)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RemoteHostLinkError.remoteError("branch_push_failed") }
    }

    /// A wake-up has no content or authority. Receiver must fetch independently
    /// from its own pinned primary; a spoofed notification cannot apply anything.
    func notifyDispatch(device: DeviceRecord) throws {
        lock.lock(); defer { lock.unlock() }
        statusProbeOnly = true; wantsConnection = true; self.device = device
        defer {
            wantsConnection = false; tunnel?.terminationHandler = nil
            if tunnel?.isRunning == true { tunnel?.terminate() }
            tunnel = nil; _ = unlink(localSocketPath)
        }
        try establishLocked(device)
        _ = try callLocked(method: "dispatch_wake", params: [:])
    }

    /// Use a dedicated short-lived link. Never connect(), call(), or schedule get_document.
    func queryDeviceStatus(device: DeviceRecord, primaryCommit: String? = nil) -> DeviceStatusProbe {
        lock.lock()
        defer {
            wantsConnection = false
            tunnel?.terminationHandler = nil
            if tunnel?.isRunning == true { tunnel?.terminate() }
            tunnel = nil
            _ = unlink(localSocketPath)
            lock.unlock()
        }
        statusProbeOnly = true
        var sshReachable = false
        do {
            self.device = device
            wantsConnection = true
            try establishLocked(device) { sshReachable = true }
            // Cancel the legacy reconnect handler before issuing any request.
            tunnel?.terminationHandler = nil
            let params: [String: Any] = primaryCommit.map { ["primary_commit": $0] } ?? [:]
            let result = try callLocked(method: "device_status", params: params)
            return .init(connection: .reachable, snapshot: try DeviceStatusSnapshot.decode(result),
                         acquiredAt: Date(), reason: nil)
        } catch {
            return .init(connection: sshReachable ? .appUnavailable : .sshUnavailable,
                         snapshot: nil, acquiredAt: Date(),
                         reason: sshReachable ? "app_rpc_unavailable" : "ssh_unavailable")
        }
    }

    func connect(device: DeviceRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        wantsConnection = true
        self.device = device
        try establishLocked(device)
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

    /// Only transport establishment retries. Never replay a mutating RPC on another endpoint.
    private func establishLocked(_ device: DeviceRecord, sshReady: () -> Void = {}) throws {
        // No route (including LAN) may turn a paired record back into TOFU.
        try prepareHostPin(device)
        // Sessions may predate an endpoint edit. Reload routes, never silently replace
        // the caller's paired identity/key with a differently paired registry record.
        let current = DeviceStatusReader.registry(environment: environment).first { $0.id == device.id }
        if let current, current.publicKeyFingerprint != device.publicKeyFingerprint || current.user != device.user {
            throw RemoteHostLinkError.remoteError("pairing_identity_changed")
        }
        let routes = current ?? device
        var lastError: Error = RemoteHostLinkError.remoteError("no_active_endpoints")
        for endpoint in routes.orderedEndpoints {
            stopTunnelLocked()
            activeEndpoint = endpoint
            endpointDeadline = Date().addingTimeInterval(8)
            defer { endpointDeadline = nil }
            do {
                let home = try sshHome(device)
                sshReady()
                remoteSocketPath = environment["TATWO2_REMOTE_OS_SOCKET"]
                    ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/tatwo2/live/os.sock").path
                try startTunnelLocked(device: device)
                let registry = DeviceRegistry(environment: environment)
                _ = try? registry.touch(id: device.id, endpoint: endpoint)
                // 隧道走通了，把這次實際比中的 known_hosts 指紋補記成 host 那一把（含來源與時間）。
                // recordFingerprint 只補空的或補來源，值不同會拒絕，不會覆蓋已 pin 的指紋。
                if let pinned = pinnedHostFingerprint {
                    _ = try? registry.recordFingerprint(
                        id: device.id, role: .host, fingerprint: pinned, source: "known_hosts")
                }
                return
            } catch {
                lastError = error
                stopTunnelLocked()
            }
        }
        throw lastError
    }

    private func stopTunnelLocked() {
        tunnel?.terminationHandler = nil
        if tunnel?.isRunning == true { tunnel?.terminate() }
        tunnel = nil
        _ = unlink(localSocketPath)
    }

    private func prepareHostPin(_ device: DeviceRecord) throws {
        // 隧道只認對方的主機金鑰。分流過的紀錄若沒有 host 指紋（例如自己是產生配對碼端，
        // 手上只有對方的客戶端金鑰）就直接擋掉，不會退回用另一把或 TOFU。
        pinnedHostFingerprint = nil
        guard let pinned = device.pinnedHostKeyFingerprint, pinned.hasPrefix("SHA256:") else {
            throw RemoteHostLinkError.remoteError("paired_host_key_not_found")
        }
        if let pinnedHostsFile { try? FileManager.default.removeItem(at: pinnedHostsFile) }
        pinnedHostsFile = nil; pinnedHostAlgorithm = nil
        let known = environment["TATWO2_SSH_KNOWN_HOSTS"] ?? environment["TATWO2_KNOWN_HOSTS"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts").path
        // Match key material, not an alias/hostname. Re-label ONLY the paired key for ssh's lookup.
        let lines = (try? String(contentsOfFile: known, encoding: .utf8))?.split(separator: "\n") ?? []
        var match: (String, String)?
        for line in lines where !line.hasPrefix("#") && !line.hasPrefix("@") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }
            let key = "\(parts[1]) \(parts[2])"
            if (try? DeviceRegistry.fingerprint(publicKey: key)) == pinned {
                match = (key, String(parts[1])); break
            }
        }
        guard let match else { throw RemoteHostLinkError.remoteError("paired_host_key_not_found") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("w91-host-" + UUID().uuidString)
        try Data(("tatwo-paired-host " + match.0 + "\n").utf8).write(to: file, options: .atomic)
        _ = chmod(file.path, 0o600)
        pinnedHostsFile = file
        pinnedHostAlgorithm = match.1 == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256" : match.1
        pinnedHostFingerprint = pinned
    }

    /// GUI launches do not inherit a terminal's Homebrew PATH. Keep the caller's
    /// precedence, but let an existing ProxyCommand find its installed helper.
    private var sshEnvironment: [String: String] {
        var result = environment
        var paths = (result["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for path in ["/opt/homebrew/bin", "/usr/local/bin"] where !paths.contains(path) { paths.append(path) }
        result["PATH"] = paths.joined(separator: ":")
        return result
    }

    private func sshDestination(_ device: DeviceRecord) -> String {
        if activeEndpoint?.kind == .alias { return activeEndpoint?.alias ?? "" }
        return "\(device.user)@\(activeEndpoint?.host ?? device.host)"
    }

    private func sshHome(_ device: DeviceRecord) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try sshBaseArguments(device) + [sshDestination(device), "echo $HOME"]
        process.environment = sshEnvironment
        // A file avoids pipe backpressure from a noisy ProxyCommand. Never read private keys.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("w91-ssh-" + UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = endpointDeadline ?? Date().addingTimeInterval(8)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning {
                process.terminate()
                _ = kill(process.processIdentifier, SIGKILL)
                throw RemoteHostLinkError.sshHomeLookupFailed("endpoint_timeout")
            }
            process.waitUntilExit()
        } catch {
            throw RemoteHostLinkError.sshHomeLookupFailed(error.localizedDescription)
        }
        let text = String(decoding: (try? Data(contentsOf: output)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        process.arguments = try sshBaseArguments(device) + [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localSocketPath):\(remoteSocketPath)",
            sshDestination(device),
        ]
        process.environment = sshEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw RemoteHostLinkError.tunnelStartFailed(error.localizedDescription)
        }
        tunnel = process

        let deadline = endpointDeadline ?? Date().addingTimeInterval(8)
        while Date() < deadline {
            if !process.isRunning {
                throw RemoteHostLinkError.tunnelStartFailed("ssh exited before forward became ready")
            }
            if FileManager.default.fileExists(atPath: localSocketPath) {
                if !statusProbeOnly {
                    process.terminationHandler = { [weak self] ended in
                        guard let self else { return }
                        self.lock.lock(); defer { self.lock.unlock() }
                        guard self.tunnel === ended else { return }
                        self.tunnel = nil
                        self.scheduleReconnectLocked()
                    }
                }
                return
            }
            usleep(50_000)
        }
        process.terminationHandler = nil
        if process.isRunning { process.terminate(); _ = kill(process.processIdentifier, SIGKILL) }
        tunnel = nil
        throw RemoteHostLinkError.tunnelUnavailable
    }

    private func sshBaseArguments(_ device: DeviceRecord) throws -> [String] {
        guard let pinnedHostsFile, let pinnedHostAlgorithm else {
            throw RemoteHostLinkError.remoteError("paired_host_key_not_found")
        }
        let port = activeEndpoint?.kind == .alias ? [] : ["-p", String(activeEndpoint?.port ?? device.sshPort)]
        // -o is parsed using ssh_config syntax even though Process uses argv.
        // Quote the value as well, since the approved staging volume has spaces.
        let knownHosts = pinnedHostsFile.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var arguments = [
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"\(knownHosts)\"", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlgorithms=\(pinnedHostAlgorithm)", "-o", "UpdateHostKeys=no",
            "-o", "KnownHostsCommand=none", "-o", "VerifyHostKeyDNS=no",
            "-o", "HostKeyAlias=tatwo-paired-host", "-o", "CheckHostIP=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
        ] + port
        if let key = environment["TATWO2_SSH_KEY_PATH"] { arguments += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        return arguments
    }

    private func callLocked(method: String, params: [String: Any]) throws -> [String: Any] {
        guard wantsConnection, let device else { throw RemoteHostLinkError.tunnelUnavailable }
        if tunnel?.isRunning != true { try establishLocked(device) }
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
            if n > 0 {
                out.append(contentsOf: chunk[0..<n])
                guard out.count <= 16 * 1024 * 1024 else { throw RemoteHostLinkError.invalidResponse }
                if out.last == 0x0A { break }; continue
            }
            if n == 0 { break }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw RemoteHostLinkError.invalidResponse }   // 逾時
            if errno == EINTR { continue }
            throw RemoteHostLinkError.connectFailed(errno)
        }
        return out
    }

    private func scheduleReconnectLocked() {
        guard !statusProbeOnly else { return }
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
                try self.establishLocked(device)
                _ = try self.callLocked(method: "get_document", params: [:])
                self.reconnectDelay = 1
            } catch {
                self.scheduleReconnectLocked()
            }
            self.lock.unlock()
        }
    }
}
