import AppKit
import Combine
import Darwin
import Foundation

struct IPadUseDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String

    private static func pairedWiredRows(_ data: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = root?["result"] as? [String: Any]
        return (result?["devices"] as? [[String: Any]] ?? []).filter { row in
            guard let hardware = row["hardwareProperties"] as? [String: Any],
                  row["deviceProperties"] is [String: Any],
                  let connection = row["connectionProperties"] as? [String: Any],
                  hardware["deviceType"] as? String == "iPad",
                  connection["transportType"] as? String == "wired",
                  connection["pairingState"] as? String == "paired",
                  let identifier = row["identifier"] as? String,
                  UUID(uuidString: identifier) != nil else { return false }
            return true
        }
    }

    static func pendingTunnelIdentifiers(_ data: Data) throws -> [String] {
        let ready = Set(try decode(data).map(\.id))
        return Array(Set(try pairedWiredRows(data).compactMap { $0["identifier"] as? String }))
            .filter { !ready.contains($0) }.sorted()
    }

    static func decode(_ data: Data) throws -> [Self] {
        try pairedWiredRows(data).compactMap { row in
            guard let properties = row["deviceProperties"] as? [String: Any],
                  let connection = row["connectionProperties"] as? [String: Any],
                  connection["tunnelState"] as? String == "connected",
                  let identifier = row["identifier"] as? String,
                  let address = connection["tunnelIPAddress"] as? String,
                  validAddress(address) else { return nil }
            return Self(id: identifier, name: properties["name"] as? String ?? "iPad", address: address)
        }
    }

    static func validAddress(_ address: String) -> Bool {
        var bytes = in6_addr()
        guard inet_pton(AF_INET6, address, &bytes) == 1 else { return false }
        return withUnsafeBytes(of: bytes) { ($0[0] & 0xfe) == 0xfc }
    }
}

struct IPadUseError: Error, LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

final class IPadUseTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Serializes cancellation with process launch so Stop cannot race a queued build.
final class IPadUseBuildProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

@MainActor
final class IPadUseController: ObservableObject {
    static let shared = IPadUseController()
    private static let port = 8117
    private static let requestTimeout: Double = 30
    private static let resourceTimeout: Double = 45
    @Published private(set) var devices: [IPadUseDevice] = []
    @Published private(set) var state = "尚未連接"
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var authorized = false
    @Published private(set) var preview: NSImage?
    @Published private(set) var testBundle: URL?
    @Published private(set) var stopUnconfirmed = false
    var activeDeviceName: String? { device?.name }
    var activeDeviceID: String? { device?.id }
    private var device: IPadUseDevice?
    private var runner: Process?
    private var buildProcess: IPadUseBuildProcess?
    private var runnerLog: FileHandle?
    private var sessionID: String?
    private var owner: UUID?
    private var token: String?
    private var runtimeTestBundle: URL?
    private var touchAuthorized = false
    private var generation = UUID()
    @Published private(set) var setupInProgress = false
    @Published private(set) var setupBlocker: String?
    private var setupAttempt: UUID?
    private var operationInFlight = false
    private var stopping = false
    private var terminationObserver: NSObjectProtocol?
    private let transportDelegate = IPadUseTransport()
    private lazy var transport = makeTransport(requestTimeout: Self.requestTimeout,
                                               resourceTimeout: Self.resourceTimeout)

    static var runtimeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tatwo2/ipad-use", isDirectory: true)
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "ipadUse.testBundle") {
            let candidate = URL(fileURLWithPath: saved)
            if Self.isTatwoTestBundle(candidate) { testBundle = candidate }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let process = self.runner
                self.stop()
                // App termination does not await the asynchronous stop task.
                if process?.isRunning == true { process?.terminate() }
            }
        }
    }

    func chooseTestBundle() {
        guard !busy, !connected else { return }
        let panel = NSOpenPanel()
        panel.title = "選擇 TATWO iPad use 設備檔案"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, url.pathExtension == "xctestrun" else { return }
        guard Self.isTatwoTestBundle(url) else {
            state = "拒絕非 TATWO iPad use 的設備檔案。"
            return
        }
        testBundle = url
        UserDefaults.standard.set(url.path, forKey: "ipadUse.testBundle")
        state = "已選擇進階設備檔案"
    }

    func discover() async {
        guard !busy, !connected else { return }
        busy = true
        setupBlocker = nil
        defer { busy = false }
        do {
            do {
                _ = try await Self.run(arguments: ["--find", "devicectl"], capture: true)
            } catch {
                setupBlocker = "xcode_tools_required"
                throw IPadUseError(description: "Mac 尚未提供可用的 iPad 裝置工具；需要安裝或選取完整 Xcode。")
            }
            devices = try await Self.discoverDevices()
            state = devices.isEmpty ? "未找到已信任且 USB 連接的 iPad；請解鎖並確認信任。" : "找到 \(devices.count) 台 USB iPad"
        } catch {
            devices = []
            if setupBlocker == nil { setupBlocker = "device_discovery_failed" }
            state = error.localizedDescription
        }
    }

    /// OS preparation is diagnostic until a person confirms the device scope in UI.
    /// Never infer device consent from a model-supplied permission field.
    func prepare(caller: UUID) async -> [String: Any] {
        if !busy, !connected, !setupInProgress, !stopping, !stopUnconfirmed {
            await discover()
        }
        var result = status(caller: caller)
        result["devices"] = devices.map { ["id": $0.id, "name": $0.name] }
        result["setupRequired"] = testBundle == nil
        result["nextAction"] = Self.setupNextAction(
            authorized: result["authorizedForCaller"] as? Bool == true,
            busy: busy || setupInProgress || operationInFlight || buildProcess != nil,
            stopPending: stopping || stopUnconfirmed,
            ownedElsewhere: authorized && owner != caller,
            deviceCount: devices.count, hasBundle: testBundle != nil)
        if let setupBlocker, !connected, !busy, !setupInProgress {
            result["nextAction"] = setupBlocker
        }
        result["settingsLocation"] = "OS → 設備 → iPad USE"
        return result
    }

    static func setupNextAction(authorized: Bool, busy: Bool, stopPending: Bool,
                               ownedElsewhere: Bool, deviceCount: Int, hasBundle: Bool) -> String {
        if stopPending { return "confirm_device_stopped" }
        if busy { return "wait" }
        if ownedElsewhere { return "device_owned_by_another_thread" }
        if authorized { return "operate" }
        if deviceCount == 0 { return "connect_unlock_and_trust" }
        if deviceCount > 1 { return "select_device" }
        return hasBundle ? "confirm_device_control" : "confirm_setup_and_control"
    }

    /// Called only by the device consent UI. One confirmation covers preparation,
    /// connection and the existing thread-bound control grant.
    func setupAndAuthorize(_ selected: IPadUseDevice, threadID: UUID) async {
        guard !setupInProgress, !busy, buildProcess == nil, !stopping, !stopUnconfirmed,
              !authorized || owner == threadID else { return }
        let attempt = UUID()
        setupAttempt = attempt
        setupInProgress = true
        defer {
            if setupAttempt == attempt {
                setupAttempt = nil
                setupInProgress = false
            }
        }
        if !connected {
            if testBundle.map({ !Self.isTatwoTestBundle($0) }) ?? true {
                await buildDevice(selected)
            }
            guard setupAttempt == attempt, !Task.isCancelled,
                  testBundle.map({ Self.isTatwoTestBundle($0) }) == true else { return }
        }
        guard setupAttempt == attempt, !Task.isCancelled else { return }
        await connectAndAuthorize(selected, threadID: threadID)
        guard setupAttempt == attempt, !Task.isCancelled,
              status(caller: threadID)["authorizedForCaller"] as? Bool == true else { return }
        do {
            _ = try await perform("ipad_screenshot", params: [:], caller: threadID)
            if setupAttempt == attempt { state = "iPad 已可操作" }
        } catch {
            if setupAttempt == attempt { state = error.localizedDescription }
        }
    }

    func buildDevice(_ selected: IPadUseDevice) async {
        guard !busy, !connected, buildProcess == nil else { return }
        busy = true
        let buildAttempt = generation
        setupBlocker = nil
        state = "正在以本機 Xcode 建立 TATWO iPad use…"
        defer {
            buildProcess = nil
            if generation == buildAttempt { busy = false }
        }
        do {
            guard let fresh = try await Self.discoverDevices().first(where: { $0.id == selected.id }) else {
                throw IPadUseError(description: "USB iPad 已中斷或信任狀態改變。")
            }
            try checkGeneration(buildAttempt)
            let teams: [String]
            do { teams = try await Self.signingTeams() }
            catch {
                setupBlocker = "apple_signing_setup_required"
                throw error
            }
            try checkGeneration(buildAttempt)
            let project = try Self.deviceProjectURL()
            let derived = Self.runtimeDirectory.appendingPathComponent("device-build", isDirectory: true)
            let logURL = Self.runtimeDirectory.appendingPathComponent("device-build.log")
            try FileManager.default.createDirectory(at: Self.runtimeDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try Data().write(to: logURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            var built = false
            for team in teams {
                try checkGeneration(buildAttempt)
                do {
                    let process = IPadUseBuildProcess()
                    buildProcess = process
                    try await Self.run(arguments: ["xcodebuild", "build-for-testing", "-project", project.path,
                                                   "-scheme", "TatwoIPadDevice", "-destination", "id=\(fresh.id)",
                                                   "-derivedDataPath", derived.path, "DEVELOPMENT_TEAM=\(team)",
                                                   "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
                                                   "-jobs", "2"], logURL: logURL, process: process)
                    built = true
                    break
                } catch { continue }
            }
            guard built else {
                throw IPadUseError(description: "Xcode 無法使用現有帳號簽署；請在 Xcode → Settings → Accounts 登入後重試。")
            }
            try checkGeneration(buildAttempt)
            try await Self.brandRunner(in: derived)
            try checkGeneration(buildAttempt)
            try Self.verifyRunnerIdentity(in: derived)
            guard let bundle = Self.findTestBundle(in: derived) else {
                throw IPadUseError(description: "建置完成但找不到 TATWO 設備檔案。")
            }
            testBundle = bundle
            UserDefaults.standard.set(bundle.path, forKey: "ipadUse.testBundle")
            devices = [fresh]
            state = "TATWO iPad use 已建立；首次使用請在 iPad 親自信任開發者 App。"
        } catch { if generation == buildAttempt { state = error.localizedDescription } }
    }

    static func discoverDevices() async throws -> [IPadUseDevice] {
        let directory = runtimeDirectory.appendingPathComponent("discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let output = directory.appendingPathComponent("devices.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        func snapshot() async throws -> Data {
            try await run(arguments: ["devicectl", "list", "devices", "--timeout", "10", "--json-output", output.path])
            return try Data(contentsOf: output)
        }
        return try await resolveDiscovery(snapshot(), prepare: { identifier in
            // CoreDevice lists a paired USB device before its tunnel is active.
            // A normal information query establishes it; no pairing or consent changes.
            _ = try await run(arguments: ["devicectl", "device", "info", "details", "--device", identifier,
                                      "--timeout", "20", "--json-output",
                                      directory.appendingPathComponent("details.json").path])
        }, refresh: { try await snapshot() })
    }

    static func resolveDiscovery(_ initial: Data,
                                 prepare: (String) async throws -> Void,
                                 refresh: () async throws -> Data) async throws -> [IPadUseDevice] {
        let pending = try IPadUseDevice.pendingTunnelIdentifiers(initial)
        guard !pending.isEmpty else { return try IPadUseDevice.decode(initial) }
        for identifier in pending {
            // A failed device must not hide other usable iPads. Re-read the live
            // list even after failure; never reuse a cached address or ready row.
            do { try await prepare(identifier) } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        let current = try await refresh()
        let ready = try IPadUseDevice.decode(current)
        if ready.isEmpty, !(try IPadUseDevice.pendingTunnelIdentifiers(current)).isEmpty {
            throw IPadUseError(description: "已找到已信任的 USB iPad，但 Xcode 尚未建立裝置通訊。請在 Xcode → Window → Devices and Simulators 查看裝置準備狀態或錯誤，再重新尋找。")
        }
        return ready
    }

    func connect(_ selected: IPadUseDevice) async {
        guard !busy, !connected, runner == nil, let testBundle else { return }
        busy = true
        state = "啟動 TATWO iPad use 設備…"
        let attempt = UUID()
        generation = attempt
        defer { if generation == attempt { busy = false } }
        do {
            guard Self.isTatwoTestBundle(testBundle),
                  FileManager.default.fileExists(atPath: testBundle.path),
                  let fresh = try await Self.discoverDevices().first(where: { $0.id == selected.id }) else {
                throw IPadUseError(description: "設備檔案或 USB 裝置不可用。")
            }
            device = fresh
            if await probeIdentity(on: fresh) {
                try await recoverPreviousSession(on: fresh, attempt: attempt)
            }
            try checkGeneration(attempt)
            let sessionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let prepared = try Self.prepareTestBundle(testBundle, token: sessionToken)
            token = sessionToken
            runtimeTestBundle = prepared
            var recovery = UserDefaults.standard.dictionary(forKey: "ipadUse.recoverySessions") ?? [:]
            recovery[fresh.id] = ["bundle": prepared.path, "ownerPID": Int(getpid())]
            UserDefaults.standard.set(recovery, forKey: "ipadUse.recoverySessions")
            let logURL = Self.runtimeDirectory.appendingPathComponent("runner-\(attempt.uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let log = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xcodebuild", "test-without-building", "-xctestrun", prepared.path,
                                 "-destination", "id=\(fresh.id)", "-jobs", "2",
                                 "-derivedDataPath", Self.runtimeDirectory.appendingPathComponent("device-build").path,
                                 "-test-timeouts-enabled", "NO",
                                 "-collect-test-diagnostics", "never"]
            process.standardOutput = log
            process.standardError = log
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == attempt, !self.stopping else { return }
                    self.stop(message: Self.deviceExitMessage(logURL: logURL))
                }
            }
            runner = process
            runnerLog = log
            try process.run()
            let deadline = Date.now.addingTimeInterval(120)
            while Date.now < deadline {
                try checkGeneration(attempt)
                guard process.isRunning else {
                    throw IPadUseError(description: Self.deviceExitMessage(logURL: logURL))
                }
                if let status = try? await requestJSON("GET", path: "v1/status"), status["ready"] as? Bool == true {
                    guard status["protocol"] as? Int == 2 else {
                        throw IPadUseError(description: "設備版本需要更新；請按「建立／更新設備」後重新連接。")
                    }
                    connected = true
                    state = "設備已就緒・尚未授權畫面與操作"
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw IPadUseError(description: "設備啟動逾時，已停止；不會自動重試。")
        } catch {
            if generation == attempt { stop(message: error.localizedDescription) }
        }
    }

    static func deviceExitMessage(logURL: URL) -> String {
        // Only inspect the small tail; never copy Xcode's raw diagnostics into
        // chat or ask a model to interpret private device logs.
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return "設備程式已退出；請重新連接並授權。"
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 16_384 ? end - 16_384 : 0)
        let tail = String(decoding: (try? handle.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
        if tail.contains("device is locked") {
            return "iPad 已鎖定；請解鎖後重新連線。"
        }
        if tail.contains("enabling automation mode") {
            return "iPad 自動化啟動逾時，已停止連線；這不代表裝置被鎖定。"
        }
        if tail.contains("Missing test product") {
            return "iPad 連線元件檔案已移動或遺失；請在設備設定重新建立／更新。"
        }
        return "iPad 自動化連線中斷；請重新連線。"
    }

    func connectAndAuthorize(_ selected: IPadUseDevice, threadID: UUID) async {
        guard !busy, !stopUnconfirmed, !stopping,
              !authorized || owner == threadID else { return }
        if connected, device?.id != selected.id {
            state = "另一台 iPad 已連線；請先停止，再選擇設備。"
            return
        }
        await connect(selected)
        guard connected, device?.id == selected.id,
              !authorized || owner == threadID else { return }
        await authorize(threadID: threadID, allowTouch: true)
    }

    func authorize(threadID: UUID, allowTouch: Bool) async {
        guard connected, !busy else { return }
        guard !operationInFlight else {
            state = "請等待目前操作完成，再切換授權討論串。"
            return
        }
        if authorized, owner == threadID, touchAuthorized == allowTouch { return }
        busy = true
        let attempt = generation
        defer { if generation == attempt { busy = false } }
        do {
            let result = try await requestJSON("POST", path: "v1/session", body: [:])
            try checkGeneration(attempt)
            guard let identifier = result["sessionID"] as? String, UUID(uuidString: identifier) != nil else {
                throw IPadUseError(description: "設備未建立有效工作階段。")
            }
            sessionID = identifier
            owner = threadID
            touchAuthorized = allowTouch
            authorized = true
            state = "已授權目前討論串・直到停止或連線中斷"
        } catch { if generation == attempt { stop(message: error.localizedDescription) } }
    }

    func stop(message: String = "已停止；裝置信任未撤銷。") {
        setupAttempt = nil
        setupInProgress = false
        buildProcess?.cancel()
        guard !stopping else { return }
        let previousDevice = device
        let previousToken = token
        let process = runner
        let cleanupBundle = runtimeTestBundle
        generation = UUID()
        authorized = false
        connected = false
        owner = nil
        touchAuthorized = false
        sessionID = nil
        device = nil
        token = nil
        preview = nil
        transport.invalidateAndCancel()
        transport = makeTransport(requestTimeout: Self.requestTimeout,
                                  resourceTimeout: Self.resourceTimeout)
        guard let process else {
            if let cleanupBundle { try? FileManager.default.removeItem(at: cleanupBundle) }
            runtimeTestBundle = nil
            busy = false
            state = message
            return
        }
        stopping = true
        stopUnconfirmed = false
        busy = true
        state = "授權已撤銷・確認設備停止中…"
        let cleanupGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            if let previousDevice, let previousToken {
                _ = try? await self.requestJSON("POST", path: "v1/stop", body: [:], device: previousDevice, token: previousToken)
            }
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate() }
            var reachable = false
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(400))
                if let previousDevice {
                    reachable = await self.probeIdentity(on: previousDevice)
                } else {
                    reachable = false
                }
                if !process.isRunning && !reachable { break }
            }
            guard self.generation == cleanupGeneration else { return }
            let confirmed = !process.isRunning && !reachable
            self.runner = confirmed ? nil : process
            if !confirmed {
                self.device = previousDevice
                self.token = previousToken
            }
            try? self.runnerLog?.close()
            self.runnerLog = nil
            if confirmed, let cleanupBundle {
                if let previousDevice { self.clearRecovery(for: previousDevice.id, bundle: cleanupBundle) }
                try? FileManager.default.removeItem(at: cleanupBundle)
            }
            self.runtimeTestBundle = confirmed ? nil : cleanupBundle
            self.stopping = false
            self.stopUnconfirmed = !confirmed
            self.busy = false
            self.state = confirmed ? message : "授權已撤銷，但設備退出未確認；請檢查 iPad。不可視為服務已停止。"
        }
    }

    func status(caller: UUID) -> [String: Any] {
        let active = connected && authorized && sessionID != nil && !stopping
        return ["connected": connected,
         "authorizedForCaller": active && owner == caller,
         "pencilPressure": "unsupported",
         "touchAuthorizedForCaller": active && owner == caller && touchAuthorized,
         "authorizationExpired": false,
         "setupBlocker": setupBlocker ?? "", "setupInProgress": setupInProgress,
         "busy": operationInFlight || busy || setupInProgress || buildProcess != nil, "deviceStopPending": stopping,
         "deviceStopUnconfirmed": stopUnconfirmed, "state": state]
    }

    func perform(_ method: String, params: [String: Any], caller: UUID) async throws -> [String: Any] {
        if method == "ipad_status" { return status(caller: caller) }
        if method == "ipad_prepare" { return await prepare(caller: caller) }
        guard connected, authorized, owner == caller, sessionID != nil, !stopping else {
            throw IPadUseError(description: "ipad_ui_consent_required_for_this_thread")
        }
        if method == "ipad_stop" {
            stop()
            return ["authorizationRevoked": true, "deviceStop": "verification_pending",
                    "inFlightDelivery": "may_have_already_reached_device"]
        }
        guard ["ipad_screenshot", "ipad_touch", "ipad_open_app"].contains(method) else {
            throw IPadUseError(description: "ipad_unknown_operation")
        }
        if method != "ipad_screenshot", !touchAuthorized { throw IPadUseError(description: "ipad_touch_consent_required") }
        let app = method == "ipad_open_app" ? try Self.appPayload(params) : nil
        guard !operationInFlight, !busy else { throw IPadUseError(description: "ipad_busy") }
        operationInFlight = true
        defer { operationInFlight = false }
        let attempt = generation
        do {
            guard let device, try await Self.discoverDevices().contains(where: {
                $0.id == device.id && $0.address == device.address
            }) else {
                throw IPadUseError(description: "ipad_usb_disconnected_or_changed")
            }
            try checkGeneration(attempt)
            if let app {
                let result = try await requestJSON("POST", path: "v1/app", body: app)
                try checkGeneration(attempt)
                return result
            }
            let foreground = try await requestJSON("GET", path: "v1/foreground")
            try checkGeneration(attempt)
            if method == "ipad_screenshot" {
                let data = try await requestData("GET", path: "v1/screenshot")
                try checkGeneration(attempt)
                guard let screenshot = NSImage(data: data) else { throw IPadUseError(description: "ipad_invalid_screenshot") }
                let after = try await requestJSON("GET", path: "v1/foreground")
                try checkGeneration(attempt)
                preview = screenshot
                var result: [String: Any] = ["imageBase64": data.base64EncodedString(), "mimeType": "image/png",
                                           "coordinateUnits": "points", "coordinateSpaceAvailable": false]
                if let window = Self.stableWindow(before: foreground, after: after) {
                    result["window"] = window
                    result["coordinateSpaceAvailable"] = true
                    result["bundleIdentifier"] = after["bundleIdentifier"]
                }
                return result
            }
            guard let width = foreground["width"] as? Double,
                  let height = foreground["height"] as? Double,
                  // Validate a single viewport here; the device compares it with
                  // its live app/frame immediately before delivering the touch.
                  let window = Self.stableWindow(before: foreground, after: foreground) else {
                throw IPadUseError(description: "ipad_select_app_required")
            }
            var touch = try Self.touchPayload(params, width: width, height: height)
            touch["expectedBundleIdentifier"] = foreground["bundleIdentifier"]
            touch["expectedWindow"] = window
            _ = try await requestJSON("POST", path: "v1/touch", body: touch)
            try checkGeneration(attempt)
            return ["delivered": true, "pencilPressure": false, "replayed": false]
        } catch {
            // A late timeout from a revoked session must not resurrect its UI or transport.
            guard generation == attempt else {
                throw IPadUseError(description: "ipad_operation_cancelled")
            }
            if method == "ipad_screenshot", Self.isTimeout(error) {
                transport.invalidateAndCancel()
                transport = makeTransport(requestTimeout: Self.requestTimeout,
                                          resourceTimeout: Self.resourceTimeout)
                state = "截圖逾時；連線與授權仍保留，可安全重新擷取。"
                throw IPadUseError(description: "ipad_screenshot_timeout_retry_safe")
            }
            if let error = error as? IPadUseError,
               ["ipad_invalid_touch", "ipad_invalid_point", "ipad_unknown_operation",
                "ipad_invalid_app", "ipad_app_not_foreground", "ipad_select_app_required", "ipad_foreground_changed"].contains(error.description) {
                throw error
            }
            if generation == attempt { stop(message: "操作未確認或連線中斷，已停止；請檢查 iPad，不會自動重播。") }
            throw error
        }
    }

    static func appPayload(_ params: [String: Any]) throws -> [String: Any] {
        guard Set(params.keys).isSubset(of: ["bundleIdentifier", "callerThreadID"]),
              let identifier = params["bundleIdentifier"] as? String,
              identifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#, options: .regularExpression) != nil else {
            throw IPadUseError(description: "ipad_invalid_app")
        }
        return ["bundleIdentifier": identifier]
    }

    static func stableWindow(before: [String: Any], after: [String: Any]) -> [String: Double]? {
        guard let identifier = before["bundleIdentifier"] as? String, !identifier.isEmpty,
              identifier == after["bundleIdentifier"] as? String else { return nil }
        var window: [String: Double] = [:]
        for key in ["x", "y", "width", "height"] {
            guard let value = before[key] as? Double, value.isFinite,
                  value == after[key] as? Double else { return nil }
            window[key] = value
        }
        guard window["width"]! > 0, window["height"]! > 0 else { return nil }
        return window
    }

    static func touchPayload(_ params: [String: Any], width: Double, height: Double) throws -> [String: Any] {
        guard Set(params.keys).isSubset(of: ["points", "durationMs", "callerThreadID"]),
              let points = params["points"] as? [[String: Any]], (1...2).contains(points.count),
              let duration = params["durationMs"] as? NSNumber,
              CFGetTypeID(duration) != CFBooleanGetTypeID(), duration.doubleValue.isFinite,
              duration.doubleValue >= 50, duration.doubleValue <= 5_000,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw IPadUseError(description: "ipad_invalid_touch")
        }
        for point in points {
            guard Set(point.keys) == ["x", "y"],
                  let horizontal = point["x"] as? NSNumber, let vertical = point["y"] as? NSNumber,
                  CFGetTypeID(horizontal) != CFBooleanGetTypeID(), CFGetTypeID(vertical) != CFBooleanGetTypeID(),
                  horizontal.doubleValue.isFinite, vertical.doubleValue.isFinite,
                  horizontal.doubleValue >= 0, horizontal.doubleValue < width,
                  vertical.doubleValue >= 0, vertical.doubleValue < height else {
                throw IPadUseError(description: "ipad_invalid_point")
            }
        }
        return ["points": points, "durationMs": duration]
    }

    static func prepareTestBundle(_ source: URL, token: String) throws -> URL {
        guard token.count >= 32,
              var root = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any] else {
            throw IPadUseError(description: "設備檔案格式無效。")
        }
        root = replacingTestRoot(root, with: source.deletingLastPathComponent().path) as? [String: Any] ?? root
        for key in root.keys {
            guard var configuration = root[key] as? [String: Any], configuration["TestBundlePath"] != nil else { continue }
            var environment = configuration["EnvironmentVariables"] as? [String: Any] ?? [:]
            environment["TATWO_IPAD_USE_TOKEN"] = token
            configuration["EnvironmentVariables"] = environment
            root[key] = configuration
        }
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let destination = runtimeDirectory.appendingPathComponent("session-\(UUID().uuidString).xctestrun")
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    /// Reuses the existing private xctestrun only to stop a previous owned
    /// service. It never restores its authorization or sends a touch.
    private func recoverPreviousSession(on device: IPadUseDevice, attempt: UUID) async throws {
        let recovery = UserDefaults.standard.dictionary(forKey: "ipadUse.recoverySessions") ?? [:]
        guard let record = recovery[device.id] as? [String: Any],
              let path = record["bundle"] as? String,
              let ownerPID = record["ownerPID"] as? Int, ownerPID > 0, ownerPID <= Int(Int32.max),
              let previousToken = Self.recoveryToken(from: URL(fileURLWithPath: path)) else {
            throw IPadUseError(description: "裝置已有其他控制服務；請先在原工作階段停止，或在 iPad 關閉 TATWO 設備程式。")
        }
        if Self.recoveryOwnerIsActive(pid: ownerPID) {
            throw IPadUseError(description: "另一個 TATWO OS 仍在使用這台 iPad；不會中斷其工作。")
        }
        state = "清理上次中斷的設備連線…"
        let result = try await requestJSON("POST", path: "v1/stop", body: [:], device: device, token: previousToken)
        try checkGeneration(attempt)
        guard result["stopped"] as? Bool == true else {
            throw IPadUseError(description: "舊設備服務未確認停止；不會接管或重播操作。")
        }
        try await Task.sleep(for: .milliseconds(500))
        try checkGeneration(attempt)
        guard !(await probeIdentity(on: device)) else {
            throw IPadUseError(description: "舊設備服務仍在停止中，請稍後再連接。")
        }
        try checkGeneration(attempt)
        clearRecovery(for: device.id, bundle: URL(fileURLWithPath: path))
    }

    static func recoveryOwnerIsActive(pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return true }
        // Same-process retry is already gated by runner == nil in connect().
        if pid == Int(getpid()) { return false }
        return Darwin.kill(pid_t(pid), 0) == 0 || errno != ESRCH
    }

    static func recoveryToken(from bundle: URL) -> String? {
        let root = runtimeDirectory.standardizedFileURL
        let file = bundle.standardizedFileURL
        guard file.deletingLastPathComponent() == root,
              file.lastPathComponent.hasPrefix("session-"),
              file.resolvingSymlinksInPath() == root.resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              Self.isTatwoTestBundle(file),
              let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        for value in plist.values {
            guard let configuration = value as? [String: Any],
                  let environment = configuration["EnvironmentVariables"] as? [String: Any],
                  let token = environment["TATWO_IPAD_USE_TOKEN"] as? String,
                  token.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else { continue }
            return token
        }
        return nil
    }

    private func clearRecovery(for deviceID: String, bundle: URL) {
        var recovery = UserDefaults.standard.dictionary(forKey: "ipadUse.recoverySessions") ?? [:]
        guard let record = recovery[deviceID] as? [String: Any], record["bundle"] as? String == bundle.path else { return }
        recovery.removeValue(forKey: deviceID)
        UserDefaults.standard.set(recovery, forKey: "ipadUse.recoverySessions")
    }

    static func isTatwoTestBundle(_ source: URL) -> Bool {
        guard source.pathExtension == "xctestrun",
              let data = try? Data(contentsOf: source),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return root.values.contains { value in
            guard let configuration = value as? [String: Any] else { return false }
            return configuration["TestHostBundleIdentifier"] as? String == "ai.tatwo.ipaduse.device.xctrunner"
                && configuration["BlueprintName"] as? String == "TatwoIPadDevice"
        }
    }

    private static func replacingTestRoot(_ value: Any, with root: String) -> Any {
        if let string = value as? String { return string.replacingOccurrences(of: "__TESTROOT__", with: root) }
        if let array = value as? [Any] { return array.map { replacingTestRoot($0, with: root) } }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { replacingTestRoot($0, with: root) } }
        return value
    }

    private func requestJSON(_ method: String, path: String, body: [String: Any]? = nil,
                             device explicitDevice: IPadUseDevice? = nil, token explicitToken: String? = nil) async throws -> [String: Any] {
        let data = try await requestData(method, path: path, body: body, device: explicitDevice, token: explicitToken)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["error"] == nil else {
            throw IPadUseError(description: "ipad_transport_rejected")
        }
        return result
    }

    private func requestData(_ method: String, path: String, body: [String: Any]? = nil,
                             device explicitDevice: IPadUseDevice? = nil, token explicitToken: String? = nil) async throws -> Data {
        guard let target = explicitDevice ?? device, IPadUseDevice.validAddress(target.address),
              let url = URL(string: "http://[\(target.address)]:\(Self.port)/\(path)") else {
            throw IPadUseError(description: "ipad_no_endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if path != "v1/identity" {
            guard let credential = explicitToken ?? token else { throw IPadUseError(description: "ipad_no_session_token") }
            request.setValue(credential, forHTTPHeaderField: "X-Tatwo-Token")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await transport.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= 24_000_000 else { throw IPadUseError(description: "ipad_transport_rejected") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 24_000_000 else { throw IPadUseError(description: "ipad_response_too_large") }
            data.append(byte)
        }
        guard response.statusCode == 200 else {
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = body["error"] as? String,
               ["ipad_invalid_app", "ipad_app_not_foreground", "ipad_foreground_changed"].contains(code) {
                throw IPadUseError(description: code)
            }
            throw IPadUseError(description: "ipad_transport_rejected")
        }
        return data
    }

    private func probeIdentity(on target: IPadUseDevice) async -> Bool {
        guard let result = try? await requestJSON("GET", path: "v1/identity", device: target),
              result["name"] as? String == "TATWO iPad use",
              let version = result["protocol"] as? Int, [1, 2].contains(version) else { return false }
        return true
    }

    private static func isTimeout(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut
    }

    private func checkGeneration(_ attempt: UUID) throws {
        guard generation == attempt else { throw IPadUseError(description: "ipad_operation_cancelled") }
    }

    private func makeTransport(requestTimeout: Double, resourceTimeout: Double) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: transportDelegate, delegateQueue: nil)
    }

    private static func deviceProjectURL() throws -> URL {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("iPadUseDevice/TatwoIPadDevice.xcodeproj"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Device/iPadUseDevice/TatwoIPadDevice.xcodeproj")
        ].compactMap { $0 }
        guard let project = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw IPadUseError(description: "App 內缺少 TATWO iPad use 裝置專案。")
        }
        return project
    }

    private static func signingTeams() async throws -> [String] {
        var teams: [String] = []
        let profiles = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true)
        for profile in (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? []
            where profile.pathExtension == "mobileprovision" {
            guard let data = try? await run(arguments: ["cms", "-D", "-i", profile.path],
                                            executable: "/usr/bin/security", capture: true),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let team = (plist["TeamIdentifier"] as? [String])?.first,
                  team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
                  (plist["ExpirationDate"] as? Date ?? .distantPast) > Date.now,
                  !teams.contains(team) else { continue }
            teams.append(team)
        }
        if let data = try? await run(arguments: ["find-identity", "-v", "-p", "codesigning"],
                                     executable: "/usr/bin/security", capture: true) {
            let text = String(decoding: data, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: #"Apple Development: [^\"]+ \(([A-Z0-9]{10})\)"#)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let team = String(text[range])
                if !teams.contains(team) { teams.append(team) }
            }
        }
        guard !teams.isEmpty else {
            throw IPadUseError(description: "缺少有效的 Apple 開發簽署憑證；請在 Xcode → Settings → Accounts 確認帳號及開發憑證。")
        }
        return teams
    }

    private static func findTestBundle(in derived: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: derived, includingPropertiesForKeys: nil) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first {
            $0.pathExtension == "xctestrun" && $0.lastPathComponent.hasPrefix("TatwoIPadDevice_")
        }
    }

    private static func verifyRunnerIdentity(in derived: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: derived, includingPropertiesForKeys: nil),
              let runner = enumerator.compactMap({ $0 as? URL }).first(where: {
                  $0.pathExtension == "app" && $0.lastPathComponent.hasSuffix("-Runner.app")
              }) else {
            throw IPadUseError(description: "找不到 TATWO iPad use 裝置 App。")
        }
        let plist = runner.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleDisplayName"] as? String == "TATWO iPad use",
              info["CFBundleIdentifier"] as? String == "ai.tatwo.ipaduse.device.xctrunner" else {
            throw IPadUseError(description: "裝置 App 名稱或 Bundle ID 驗證失敗。")
        }
    }

    private static func brandRunner(in derived: URL) async throws {
        guard let enumerator = FileManager.default.enumerator(at: derived, includingPropertiesForKeys: nil),
              let runner = enumerator.compactMap({ $0 as? URL }).first(where: {
                  $0.pathExtension == "app" && $0.lastPathComponent.hasSuffix("-Runner.app")
              }) else {
            throw IPadUseError(description: "找不到 TATWO iPad use 裝置 App。")
        }
        let temporary = runtimeDirectory.appendingPathComponent("certificate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let certificatePrefix = temporary.appendingPathComponent("certificate").path
        _ = try await run(arguments: ["-d", "--extract-certificates=\(certificatePrefix)", runner.path],
                          executable: "/usr/bin/codesign", capture: true)
        let certificate = URL(fileURLWithPath: certificatePrefix + "0")
        guard FileManager.default.fileExists(atPath: certificate.path) else {
            throw IPadUseError(description: "無法取得 Xcode 裝置簽署憑證。")
        }
        let digestData = try await run(arguments: ["-a", "1", certificate.path],
                                       executable: "/usr/bin/shasum", capture: true)
        guard let digest = String(decoding: digestData, as: UTF8.self).split(separator: " ").first.map(String.init),
              digest.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil else {
            throw IPadUseError(description: "Xcode 裝置簽署憑證格式無效。")
        }
        let plist = runner.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              var info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw IPadUseError(description: "裝置 App 資訊檔無效。")
        }
        info["CFBundleDisplayName"] = "TATWO iPad use"
        info["CFBundleName"] = "TATWO iPad use"
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: plist, options: .atomic)
        _ = try await run(arguments: ["--force", "--sign", digest,
                                      "--preserve-metadata=identifier,entitlements,requirements,flags",
                                      "--timestamp=none", runner.path], executable: "/usr/bin/codesign", capture: true)
        _ = try await run(arguments: ["--verify", "--deep", "--strict", runner.path],
                          executable: "/usr/bin/codesign", capture: true)
    }

    @discardableResult
    private static func run(arguments: [String], executable: String = "/usr/bin/xcrun",
                            logURL: URL? = nil, capture: Bool = false, process suppliedProcess: IPadUseBuildProcess? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                let process = suppliedProcess?.process ?? Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                let log = logURL.flatMap { try? FileHandle(forWritingTo: $0) }
                process.standardOutput = capture ? pipe : (log ?? FileHandle.nullDevice)
                process.standardError = capture ? pipe : (log ?? FileHandle.nullDevice)
                process.standardInput = FileHandle.nullDevice
                do {
                    if let suppliedProcess { try suppliedProcess.start() }
                    else { try process.run() }
                    process.waitUntilExit()
                    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
                    try? log?.close()
                    guard process.terminationStatus == 0 else {
                        throw IPadUseError(description: "Xcode 操作失敗；請查看私有 iPad USE 記錄。")
                    }
                    continuation.resume(returning: data)
                } catch {
                    try? log?.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
