import Darwin
import Foundation
import Network

final class DevicePairingHost: @unchecked Sendable {
    private struct PairRequest: Codable {
        let code: String
        let publicKey: String
        let name: String
        var user: String?
        var deviceID: String?
    }

    private struct PairResponse: Codable {
        let ok: Bool
        var deviceID: String?
        var hostName: String?
        var hostUser: String?
        var reason: String?
        var hostDeviceID: String?
    }

    private final class StartProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private(set) var ready = false
        private(set) var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)

        func resolveReady() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            ready = true
            lock.unlock()
            semaphore.signal()
        }

        func resolveFailure(_ error: Error) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            failure = error
            lock.unlock()
            semaphore.signal()
        }
    }

    enum HostError: Error, LocalizedError {
        case noLocalAddress
        case noPortAvailable
        case listenerStartTimedOut
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLocalAddress: "pairing_no_local_address"
            case .noPortAvailable: "pairing_no_port_available"
            case .listenerStartTimedOut: "pairing_listener_start_timed_out"
            case let .listenerFailed(reason): "pairing_listener_failed:\(reason)"
            }
        }
    }

    private let registry: DeviceRegistry
    private let environment: [String: String]
    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.device-pairing-host")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var activeCode: TatwoDevicePairingCodeRecordV1?
    private var activeToken: UUID?
    private var failedAttempts = 0
    private(set) var port: Int?
    var onClose: (() -> Void)?

    init(
        registry: DeviceRegistry? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        self.registry = registry ?? DeviceRegistry(environment: environment)
    }

    func startPairingWindow() throws -> (code: String, expiresAt: Date, listenAddress: String) {
        cancelPairingWindow()
        let identity = try DeviceIdentityStore.forLocalDevice(
            entry: TatwoEntry(environment: environment)).read()
        let authority = identity.primaryDeviceID ?? identity.deviceID
        let code = try TatwoDevicePairingCodeEngineV1.mint(
            createdBy: identity.deviceID,
            authorityPrimary: authority,
            // Unassigned bootstrap pairing is epoch 0; it does not grant primary role.
            authorityEpoch: UInt64(identity.epoch ?? 0),
            ttlSeconds: 300)
        guard let bindAddress = Self.bindAddress(environment: environment) else {
            throw HostError.noLocalAddress
        }

        var lastFailure: Error?
        for candidatePort in Array(18800...18899).shuffled() {
            let nwPort = NWEndpoint.Port(rawValue: UInt16(candidatePort))!
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: nwPort)
            do {
                let candidate = try NWListener(using: parameters)
                let token = UUID()
                let probe = StartProbe()
                candidate.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection, token: token)
                }
                candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                    switch state {
                    case .ready:
                        probe.resolveReady()
                    case let .failed(error):
                        probe.resolveFailure(error)
                        if probe.ready, let candidate {
                            self?.finishWindow(listener: candidate, token: token)
                        }
                    case .cancelled:
                        if probe.ready, let candidate {
                            self?.finishWindow(listener: candidate, token: token)
                        }
                    default:
                        break
                    }
                }

                stateLock.lock()
                listener = candidate
                activeCode = code
                activeToken = token
                failedAttempts = 0
                port = candidatePort
                stateLock.unlock()
                candidate.start(queue: queue)

                guard probe.semaphore.wait(timeout: .now() + 2) == .success else {
                    candidate.cancel()
                    clearIfMatching(listener: candidate, token: token, notify: false)
                    lastFailure = HostError.listenerStartTimedOut
                    continue
                }
                guard probe.ready else {
                    candidate.cancel()
                    clearIfMatching(listener: candidate, token: token, notify: false)
                    lastFailure = probe.failure
                    continue
                }

                queue.asyncAfter(deadline: .now() + 300) { [weak self, weak candidate] in
                    guard let candidate else { return }
                    self?.finishWindow(listener: candidate, token: token)
                }
                return (code.seed, code.expiresAt, "\(bindAddress):\(candidatePort)")
            } catch {
                lastFailure = error
            }
        }
        if let lastFailure {
            throw HostError.listenerFailed(lastFailure.localizedDescription)
        }
        throw HostError.noPortAvailable
    }

    func cancelPairingWindow() {
        stateLock.lock()
        let current = listener
        let token = activeToken
        stateLock.unlock()
        guard let current, let token else { return }
        finishWindow(listener: current, token: token)
    }

    private func accept(_ connection: NWConnection, token: UUID) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receiveLine(from: connection, token: token, buffer: Data())
    }

    private func receiveLine(from connection: NWConnection, token: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var joined = buffer
            if let data { joined.append(data) }
            if joined.count > 65_536 {
                self.reject(connection, token: token, reason: "request_too_large")
                return
            }
            if let newline = joined.firstIndex(of: 0x0A) {
                self.handle(Data(joined[..<newline]), from: connection, token: token)
            } else if complete || error != nil {
                self.handle(joined, from: connection, token: token)
            } else {
                self.receiveLine(from: connection, token: token, buffer: joined)
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection, token: UUID) {
        guard let request = try? JSONDecoder().decode(PairRequest.self, from: data),
              !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            reject(connection, token: token, reason: "bad_request")
            return
        }

        stateLock.lock()
        guard activeToken == token, let record = activeCode else {
            stateLock.unlock()
            send(PairResponse(ok: false, reason: "pairing_window_closed"), to: connection)
            return
        }
        let local: DeviceIdentity
        do {
            guard let identity = try DeviceIdentityStore.readLocal(entry: TatwoEntry(environment: environment))
            else { throw DeviceIdentityError.identityConflict }
            local = identity
            activeCode = try TatwoDevicePairingCodeEngineV1.consume(
                seed: request.code,
                record: record,
                expectedPrimary: identity.primaryDeviceID ?? identity.deviceID,
                expectedEpoch: UInt64(identity.epoch ?? 0))
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            reject(connection, token: token, reason: error.localizedDescription)
            return
        }

        do {
            let deviceID = try registry.pairingDeviceID(
                publicKey: request.publicKey, requestedID: request.deviceID,
                localDeviceID: local.deviceID)
            let previous = registry.list().first { $0.id.lowercased() == deviceID }
            let fingerprint = try registry.authorize(publicKey: request.publicKey, deviceID: deviceID)
            do {
                _ = try registry.add(
                    id: deviceID,
                    name: request.name,
                    host: Self.remoteHost(connection.endpoint),
                    user: request.user ?? NSUserName(),
                    sshPort: 22,
                    publicKeyFingerprint: fingerprint,
                    workdirMap: previous?.workdirMap ?? [:],
                    lanHost: previous?.lanHost,
                    role: previous?.role,
                    epoch: previous?.epoch)
            } catch {
                // A failed re-pair must not revoke the previously authorized device.
                if previous == nil { try? registry.removeAuthorizedKey(deviceID: deviceID) }
                throw error
            }
            let response = PairResponse(
                ok: true,
                deviceID: deviceID,
                hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                hostUser: NSUserName(),
                hostDeviceID: local.deviceID)
            send(response, to: connection) { [weak self] in
                self?.finishCurrentWindow(token: token)
            }
        } catch {
            send(PairResponse(ok: false, reason: error.localizedDescription), to: connection) { [weak self] in
                self?.finishCurrentWindow(token: token)
            }
        }
    }

    private func reject(_ connection: NWConnection, token: UUID, reason: String) {
        stateLock.lock()
        guard activeToken == token else {
            stateLock.unlock()
            send(PairResponse(ok: false, reason: "pairing_window_closed"), to: connection)
            return
        }
        failedAttempts += 1
        let shouldClose = failedAttempts >= 5
        stateLock.unlock()
        send(PairResponse(ok: false, reason: reason), to: connection) { [weak self] in
            if shouldClose { self?.finishCurrentWindow(token: token) }
        }
    }

    private func send(_ response: PairResponse, to connection: NWConnection, completion: (() -> Void)? = nil) {
        guard var data = try? JSONEncoder().encode(response) else {
            connection.cancel()
            completion?()
            return
        }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    private func finishCurrentWindow(token: UUID) {
        stateLock.lock()
        let current = activeToken == token ? listener : nil
        stateLock.unlock()
        guard let current else { return }
        finishWindow(listener: current, token: token)
    }

    private func finishWindow(listener target: NWListener, token: UUID) {
        let didClear = clearIfMatching(listener: target, token: token, notify: true)
        if didClear { target.cancel() }
    }

    @discardableResult
    private func clearIfMatching(listener target: NWListener, token: UUID, notify: Bool) -> Bool {
        stateLock.lock()
        guard listener === target, activeToken == token else {
            stateLock.unlock()
            return false
        }
        listener = nil
        activeCode = nil
        activeToken = nil
        failedAttempts = 0
        port = nil
        let callback = notify ? onClose : nil
        stateLock.unlock()
        callback?()
        return true
    }

    private static func remoteHost(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return String(describing: endpoint) }
        return String(describing: host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func bindAddress(environment: [String: String]) -> String? {
        if let override = environment["TATWO2_PAIRING_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return "127.0.0.1" }
        defer { freeifaddrs(interfaces) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            defer { current = pointer.pointee.ifa_next }
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (pointer.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  (pointer.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let value = String(cString: host)
            if value.hasPrefix("10.") || value.hasPrefix(["192", "168", ""].joined(separator: ".")) || Self.isPrivate172(value) {
                return value
            }
        }
        return "127.0.0.1"
    }

    private static func isPrivate172(_ address: String) -> Bool {
        let fields = address.split(separator: ".")
        guard fields.count == 4, fields[0] == "172", let second = Int(fields[1]) else { return false }
        return (16...31).contains(second)
    }
}
