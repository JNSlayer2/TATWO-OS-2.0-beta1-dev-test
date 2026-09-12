import Foundation
import WebKit

@MainActor enum IslandExceptionsAcceptance {
    static func run() async -> Bool {
        var failed = false
        func check(_ name: String, _ condition: Bool) {
            print("ISLANDTEST \(condition ? "PASS" : "FAIL") exceptions \(name)")
            failed = failed || !condition
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var collapse = IslandCollapsePolicy()
        collapse.handle(.hoverEntered)
        collapse.handle(.hoverExited(at: 100))
        check("policy leave under 3 seconds stays open", !collapse.handle(.tick(now: 102.999)))
        check("policy leave at 3 seconds collapses", collapse.handle(.tick(now: 103)))
        collapse.handle(.hoverExited(at: 200))
        check("policy leave over 3 seconds collapses", collapse.handle(.tick(now: 204)))
        collapse.handle(.itemTapped)
        collapse.handle(.hoverExited(at: 300))
        check("policy item tap prevents auto collapse", !collapse.handle(.tick(now: 400)))
        collapse.handle(.hoverEntered)
        collapse.handle(.hoverExited(at: 401))
        check("policy hover does not clear item latch", !collapse.handle(.tick(now: 405)))
        check("policy escape collapses", collapse.handle(.escape))
        collapse.handle(.hoverExited(at: 500))
        collapse.handle(.hoverEntered)
        check("policy hover return cancels pending collapse", !collapse.handle(.tick(now: 600)))
        collapse.handle(.itemTapped)
        check("policy outside tap collapses", collapse.handle(.outsideTapped))
        collapse.handle(.hoverExited(at: 700))
        check("policy dismissal resets item latch", collapse.handle(.tick(now: 703)))
        var approval = LiveThreadRecord(title: "approval", updatedAt: now)
        approval.subStatus = "running"
        var stalled = LiveThreadRecord(title: "stalled", updatedAt: now.addingTimeInterval(-901))
        stalled.subStatus = "running"
        let bot = BotLibraryRecord(id: "test", name: "memory", emoji: "", role: "", engine: "", workdir: "")
        var bots = BotLibrarySnapshot(bots: [bot])
        bots.pending[bot.id] = [.init(id: "pending", text: "fixture", at: "2026-01-01T00:00:00Z", threadID: approval.id.uuidString)]
        let job = BackgroundJobManager.Snapshot(jobID: UUID(), title: "failed", state: "exited", startedAt: now,
                                               lastLine: "", threadID: approval.id, exitCode: 1)
        let value = IslandWorkProvider.project(threads: [stalled, approval], pending: [approval.id], running: [], bots: bots, jobs: [job], now: now)
        check("four kinds sorted", value.exceptions.compactMap(\.kind) == IslandWorkSnapshot.Kind.allCases)
        check("targets preserve source", value.exceptions[0].threadID == approval.id && value.exceptions[1].botID == bot.id && value.exceptions[3].jobID == job.jobID)
        let many = (0..<30).flatMap { index -> [IslandWorkSnapshot.Item] in
            let target = IslandWorkSnapshot.Target(threadID: UUID())
            return [.init(kind: .failed, title: "e\(index)", target: target, since: now, hint: ""),
                    .init(kind: nil, title: "n\(index)", target: target, since: now, hint: "")]
        }
        let capped = IslandWorkSnapshot.ordered(many)
        check("independent 20 row caps", capped.exceptions.count == 20 && capped.normal.count == 20)
        check("deterministic ties", IslandWorkSnapshot.ordered(many.reversed()).exceptions.map(\.id) == capped.exceptions.map(\.id))
        approval.subStatus = "done"; stalled.subStatus = "done"; bots.pending = [:]
        var success = job; success.exitCode = 0
        let resolved = IslandWorkProvider.project(threads: [approval, stalled], pending: [], running: [], bots: bots, jobs: [success], now: now)
        check("resolved exceptions disappear", resolved.exceptions.isEmpty)
        stalled.subStatus = "running"; stalled.updatedAt = now.addingTimeInterval(-900)
        let boundary = IslandWorkProvider.project(threads: [stalled], pending: [], running: [], bots: .init(), jobs: [], now: now)
        check("900 seconds is not over threshold", boundary.exceptions.isEmpty && boundary.normal.count == 1)
        stalled.subStatus = "failed"
        check("failed room without active run", IslandWorkProvider.project(threads: [stalled], pending: [], running: [], bots: .init(), jobs: [], now: now).exceptions.first?.kind == .failed)
        var reads = 0
        let provider = IslandWorkProvider { reads += 1; return value }
        try? await Task.sleep(nanoseconds: 30_000_000)
        check("collapsed provider never starts", reads == 0)
        provider.activate()
        try? await Task.sleep(nanoseconds: 30_000_000)
        check("expanded provider refreshes", reads == 1 && provider.data.exceptions.count == 4)
        provider.suspend()
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        check("collapsed provider stops polling", reads == 1)
        provider.unload()
        check("unload clears data", provider.data.exceptions.isEmpty)
        let late = IslandWorkProvider { try? await Task.sleep(nanoseconds: 100_000_000); return value }
        late.activate(); await Task.yield(); late.suspend()
        try? await Task.sleep(nanoseconds: 150_000_000)
        check("cancelled in-flight read never publishes", late.data.exceptions.isEmpty)
        var countReads = 0; var sourceCount = 3
        let counter = IslandExceptionsCount { countReads += 1; return sourceCount }
        await counter.refresh(now: 10); await counter.refresh(now: 10.2); await counter.refresh(now: 10.999)
        check("count throttles under one second", countReads == 1 && counter.text == "有 3 件等你")
        sourceCount = 0; await counter.refresh(now: 11)
        check("count clears at one second", countReads == 2 && counter.text == "無額外提醒")
        let shell = TatwoIslandShellState()
        IslandExceptionsNavigation.shell = shell
        IslandExceptionsNavigation.openWork()
        check("single action expands existing shell", shell.isExpanded)
        IslandExceptionsNavigation.shell = nil; IslandExceptionsNavigation.requestedWork = false
        // GOAL #5 Island 收合無殘留 WebContent：真 IslandQuotesProvider 的 activate→suspend／unload 釋放（DEBUG-only 靜態 HTML 注入，0 網路）
        #if DEBUG
        let previousFlag = ProcessInfo.processInfo.environment["TATWO2_ISLAND_QUOTES_TEST_STATIC"]
        setenv("TATWO2_ISLAND_QUOTES_TEST_STATIC", "1", 1)
        defer { if let previousFlag { setenv("TATWO2_ISLAND_QUOTES_TEST_STATIC", previousFlag, 1) } else { unsetenv("TATWO2_ISLAND_QUOTES_TEST_STATIC") } }
        // 只在測試內建 navigation 並注入 openExternal 擷取：絕不讓負例真的開外部瀏覽器（Codex 13:55）
        let navigation = IslandQuotesNavigation()
        var externallyOpened: [URL] = []
        navigation.openExternal = { externallyOpened.append($0) }
        let httpsPolicy = navigation.policy(for: URL(string: "https://example.com/")!)
        let filePolicy = navigation.policy(for: URL(string: "file:///etc/hosts")!)
        check("quotes policy: about:blank only allowed under test flag", IslandQuotesNavigation.allowed(URL(string: "about:blank")!) == false
            && navigation.policy(for: URL(string: "about:blank")!) == .allow
            && httpsPolicy == .cancel && filePolicy == .cancel)
        check("quotes policy: non-allowlisted https is handed to (captured) external opener, file scheme never", externallyOpened == [URL(string: "https://example.com/")!])
        let quotesProvider = IslandQuotesProvider(settings: ["symbols": "BINANCE:BTCUSDT"])
        weak var weakView: WKWebView?
        // 建立→suspend 整段包在外層 autoreleasepool（Codex 13:56）：建 view 時的 autoreleased 暫存要在等待前 drain，才能真的看 weak ref
        autoreleasepool {
            quotesProvider.activate()
            weakView = quotesProvider.webView
            check("quotes activate creates one WKWebView", quotesProvider.webView != nil && weakView != nil)
            quotesProvider.activate()
            check("quotes activate is idempotent", quotesProvider.webView === weakView)
            quotesProvider.suspend()
            check("quotes suspend releases provider reference", quotesProvider.webView == nil)
        }
        let deallocStart = Date(); var deallocAt: TimeInterval? = nil
        for _ in 0..<100 where weakView != nil { autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        if weakView == nil { deallocAt = Date().timeIntervalSince(deallocStart) }
        print("ISLANDTEST NOTE quotes WKWebView dealloc after suspend: \(deallocAt.map { String(format: "%.2fs", $0) } ?? "not within 5s")")
        check("quotes WKWebView deallocated after suspend (weak ref nil within 5s)", weakView == nil)
        quotesProvider.unload()
        check("quotes unload after suspend is a no-op", quotesProvider.webView == nil)
        quotesProvider.activate(); quotesProvider.pauseForMemory()
        check("quotes pauseForMemory unloads and blocks re-activate", quotesProvider.webView == nil && quotesProvider.memoryPaused && { quotesProvider.activate(); return quotesProvider.webView == nil }())
        #else
        print("ISLANDTEST BLOCKED quotes lifecycle needs DEBUG build（static HTML 注入只在 DEBUG）")
        failed = true
        #endif
        return !failed
    }
}
