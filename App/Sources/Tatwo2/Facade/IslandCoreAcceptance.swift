import Foundation
import AppKit

@MainActor enum IslandCoreAcceptance {
    final class Counter: IslandSpaceProvider {
        var active = false; var activations = 0; var suspensions = 0; var unloads = 0
        var snapshot = IslandSpaceSnapshot()
        func activate() { if !active { activations += 1 }; active = true }
        func suspend() { active = false; suspensions += 1 }
        func unload() { active = false; unloads += 1 }
    }
    final class Script: IslandScriptExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        private func record() { lock.lock(); calls += 1; lock.unlock() }
        func run(_ script: String) async throws -> String { record(); return "Test song\u{1f}Test artist\u{1f}true\u{1f}12.5\u{1f}180000" }
        func cancel() {}
    }
    final class MemorySample: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func read() -> UInt64? {
            lock.lock(); defer { lock.unlock() }; calls += 1
            return calls == 1 ? 100_000_000 : 500_000_000
        }
    }
    static func run() async -> Bool {
        var failed = !(await IslandExceptionsAcceptance.run())
        func check(_ name: String, _ value: Bool) {
            print("ISLANDTEST \(value ? "PASS" : "FAIL") \(name)")
            if !value { failed = true }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tatwo2-islandtest-\(UUID().uuidString)")
        setenv("TATWO2_LIVE_ROOT", root.path, 1)
        // No sidecar/LLM startup: permission scope is exercised directly on an isolated engine.
        let liveStore = await Task.detached { ChatLiveStore(root: root.appendingPathComponent("permissions")) }.value
        let engine = ChatLiveEngine(store: liveStore, environment: [:])
        let thread = UUID(), other = UUID()
        check("permission starts empty", engine.pendingPermissionThreadIDs.isEmpty)
        engine.withPendingPermission(thread) {
            check("permission visible inside callback", engine.pendingPermissionThreadIDs == [thread])
            engine.withPendingPermission(thread) {}
            check("nested same-thread reply retains pending", engine.pendingPermissionThreadIDs == [thread])
            engine.withPendingPermission(other) {
                check("concurrent thread permissions", engine.pendingPermissionThreadIDs == [thread, other])
            }
            check("pending overrides tool event", IslandWorkProvider.phase(pending: true, event: "tool") == "等你")
        }
        check("permission removed after reply", engine.pendingPermissionThreadIDs.isEmpty)
        enum ScopeError: Error { case rejected }
        do { try engine.withPendingPermission(thread) { throw ScopeError.rejected } } catch {}
        check("permission cleaned on error", engine.pendingPermissionThreadIDs.isEmpty)
        check("old permission event is not waiting", IslandWorkProvider.phase(pending: false, event: "permission") == "思考中")
        let device = DeviceRecord(id: "test-device", name: "測試工作室", host: "", user: "", sshPort: 22,
                                  publicKeyFingerprint: "", addedAt: Date(), lastSeenAt: Date(), workdirMap: [:])
        check("device display name not id", IslandWorkProvider.deviceName(id: device.id, devices: [device]) == device.name)
        check("unknown device does not leak id", IslandWorkProvider.deviceName(id: "missing", devices: [device]) == nil)
        let jobRoot = root.appendingPathComponent("jobs")
        do {
            let manager = await Task.detached { BackgroundJobManager(root: jobRoot) }.value
            check("background empty snapshot", await manager.snapshot().isEmpty)
            let record = try await Task.detached {
                try manager.run(command: "printf 'first\\nlast\\n'", cwd: jobRoot.path, title: "Island test", threadID: thread)
            }.value
            var rows = await manager.snapshot()
            for _ in 0..<30 {
                if rows.first?.state == "exited" { break }
                try await Task.sleep(nanoseconds: 100_000_000)
                rows = await manager.snapshot()
            }
            check("background snapshot fields and last line", rows.count == 1 && rows[0].jobID == record.jobID && rows[0].title == record.title && rows[0].state == "exited" && rows[0].startedAt == record.startedAt && rows[0].lastLine == "last")
            let registry = jobRoot.appendingPathComponent("bg-jobs.json")
            let before = try await Task.detached { try Data(contentsOf: registry) }.value
            _ = await manager.snapshot()
            let after = try await Task.detached { try Data(contentsOf: registry) }.value
            check("background snapshot never writes registry", before == after)
        } catch { check("background snapshot error: \(error)", false) }
        check("bridge absent manager remains empty", await OSAgentBridge.shared.backgroundJobSnapshot().isEmpty)
        let store = IslandSpaceStore(root: root)
        do {
            var rows = try await store.load()
            check("store default work/music/quotes", rows.map(\.kind) == [.work, .music, .quotes])
            rows[0].order = 5; rows[1].enabled = false
            try await store.save(rows)
            let loaded = try await IslandSpaceStore(root: root).load()
            check("store reorder/disable roundtrip", rows == loaded)
            let counters = rows.map { _ in Counter() }
            let providers = Dictionary(uniqueKeysWithValues: zip(rows, counters).map { ($0.0.id, $0.1 as any IslandSpaceProvider) })
            let pager = IslandPager(spaces: rows, providers: providers, unloadDelay: 0.5)
            check("disabled excluded and order applied", pager.spaces.map(\.kind) == [.quotes, .work])
            pager.select(-10); check("pager lower clamp", pager.currentIndex == 0)
            pager.select(999); check("pager upper clamp", pager.currentIndex == 1)
            pager.next(); check("pager no wrap", pager.currentIndex == 1)
            pager.isVisible = true
            check("only current provider active", counters.filter(\.active).count == 1 && counters[0].active)
            pager.prev()
            check("previous suspended synchronously under 1s", !counters[0].active && counters[2].active && counters.filter(\.active).count == 1)
            pager.isVisible = false
            check("collapse suspends all immediately", counters.allSatisfy { !$0.active })
            try await Task.sleep(nanoseconds: 650_000_000)
            check("collapse timeout unloads all", counters.allSatisfy { $0.unloads == 1 })
            pager.isVisible = true; pager.isVisible = false
            try await Task.sleep(nanoseconds: 100_000_000)
            pager.isVisible = true
            try await Task.sleep(nanoseconds: 550_000_000)
            check("reopen cancels pending unload", counters.allSatisfy { $0.unloads == 1 })
            pager.isVisible = false
            let corrupt = Data("{broken".utf8)
            try await Task.detached { try corrupt.write(to: store.url, options: .atomic) }.value
            do { _ = try await store.load(); check("corruption rejected", false) } catch { check("corruption rejected", true) }
            do { try await store.save(rows); check("corrupt save refused", false) } catch { check("corrupt save refused", true) }
            let after = try await Task.detached { try Data(contentsOf: store.url) }.value
            check("corrupt bytes not overwritten", after == corrupt)
        } catch { print("ISLANDTEST FAIL store/pager \(error)"); failed = true }
        let quotes = IslandQuotesProvider(settings: ["symbols": "NASDAQ:AAPL,BINANCE:BTCUSDT,<script>"])
        check("quotes symbols validated", quotes.symbols == ["NASDAQ:AAPL", "BINANCE:BTCUSDT"])
        check("quotes official URL/config", IslandQuotesNavigation.allowed(quotes.widgetURL) && (URLComponents(url: quotes.widgetURL, resolvingAgainstBaseURL: false)?.fragment?.contains("NASDAQ:AAPL") == true))
        var external: [URL] = []
        quotes.navigation.openExternal = { external.append($0) }
        check("navigation allows official CDN", quotes.navigation.policy(for: URL(string: "https://s.tradingview.com/test")!) == .allow)
        check("navigation blocks suffix spoof", quotes.navigation.policy(for: URL(string: "https://tradingview.com.evil.example/test")!) == .cancel && external.count == 1)
        check("navigation blocks file without browser", quotes.navigation.policy(for: URL(string: "file:///tmp/test")!) == .cancel && external.count == 1)
        check("navigation blocks credentials", !IslandQuotesNavigation.allowed(URL(string: "https://user@tradingview.com/test")!))
        let script = Script()
        let music = IslandMusicProvider(executor: script, installed: { [.spotify] })
        music.activate()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("fake osascript nowPlaying parsed", music.nowPlaying == .init(app: "Spotify", title: "Test song", artist: "Test artist", isPlaying: true, position: 12.5, duration: 180))
        music.suspend(); let previous = music.nowPlaying; let calls = script.count
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        check("music suspended no state update or polling after 2s", music.nowPlaying == previous && script.count == calls)
        music.unload(); check("music unload drops snapshot", music.nowPlaying == nil)
        let executor = IslandOSAScriptExecutor()
        let before = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let installed = await Task.detached {
            IslandMusicProvider.Player.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.rawValue) != nil }
        }.value
        for app in installed {
            if before.contains(app.rawValue) { print("ISLANDTEST 未跑 real \(app.title) not-running check: App already running"); continue }
            do {
                let value = try await executor.run(IslandMusicProvider.script(app))
                check("real \(app.title) not running => NONE", value == "NONE")
                check("real \(app.title) not launched", !NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.rawValue })
            } catch { check("real \(app.title) not-running osascript", false) }
        }
        if installed.isEmpty { print("ISLANDTEST 未跑 real osascript: no installed players") }
        let timeoutStart = Date()
        do { _ = try await executor.run("delay 10\nreturn \"late\""); check("osascript 3s timeout", false) }
        catch { check("osascript 3s timeout", Date().timeIntervalSince(timeoutStart) < 3.8) }
        let cancelTask = Task { try? await executor.run("delay 10") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let cancelStart = Date(); executor.cancel(); _ = await cancelTask.value
        check("osascript cancel under 1s", Date().timeIntervalSince(cancelStart) < 1)
        check("resident memory sampled", IslandResourceGuard.residentBytes() != nil)
        let memory = MemorySample()
        let resourceGuard = IslandResourceGuard(interval: 0.05, sample: { memory.read() })
        var ready = false
        resourceGuard.start(onReady: { ready = true }, onLimit: { quotes.pauseForMemory() })
        try? await Task.sleep(nanoseconds: 150_000_000)
        check("300MB guard pauses quotes after baseline", ready && quotes.memoryPaused && quotes.webView == nil)
        resourceGuard.stop()
        print("ISLANDTEST \(failed ? "FAIL" : "PASS")")
        return !failed
    }
}
