import Foundation
import Combine

struct IslandWorkSnapshot {
    enum Kind: Int, CaseIterable { case awaitingApproval, pendingMemory, stalled, failed }
    struct Target: Equatable { var threadID: UUID?; var botID: String?; var jobID: UUID? }
    struct Item: Identifiable {
        var kind: Kind?
        var title: String
        var target: Target
        var since: Date
        var hint: String
        var threadID: UUID? { target.threadID }
        var botID: String? { target.botID }
        var jobID: UUID? { target.jobID }
        var id: String { "\(kind?.rawValue ?? -1):\(jobID?.uuidString ?? botID ?? threadID?.uuidString ?? title)" }
    }
    var exceptions: [Item] = []
    var normal: [Item] = []
    static var waitingFixture: Self {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        return .ordered((0..<3).map { index in
            .init(kind: .awaitingApproval, title: "待確認工作 \(index + 1)",
                  target: .init(threadID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")),
                  since: since, hint: "等待批准")
        })
    }
    static var isWaitingFixture: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil && env["TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"] == "等你"
    }
    static func ordered(_ items: [Item]) -> Self {
        let sorted = items.sorted {
            if $0.kind?.rawValue != $1.kind?.rawValue { return ($0.kind?.rawValue ?? 4) < ($1.kind?.rawValue ?? 4) }
            if $0.since != $1.since { return $0.since < $1.since }
            return $0.id < $1.id
        }
        return .init(exceptions: Array(sorted.filter { $0.kind != nil }.prefix(20)),
                     normal: Array(sorted.filter { $0.kind == nil }.prefix(20)))
    }
}
@MainActor final class IslandWorkProvider: ObservableObject, IslandSpaceProvider {
    @Published private(set) var data = IslandWorkSnapshot()
    private let read: @MainActor () async -> IslandWorkSnapshot
    private var polling: Task<Void, Never>?
    init(read: @escaping @MainActor () async -> IslandWorkSnapshot = { IslandWorkSnapshot() }) { self.read = read }
    var snapshot: IslandSpaceSnapshot { .init(lines: (data.exceptions + data.normal).map { "\($0.title) · \($0.hint)" }) }
    func activate() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let value = await self.read()
                guard !Task.isCancelled else { return }
                self.data = value
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    func suspend() { polling?.cancel(); polling = nil }
    func unload() { suspend(); data = .init() }
    deinit { polling?.cancel() }
    static func deviceName(id: String?, devices: [DeviceRecord]) -> String? {
        guard let id else { return nil }
        return devices.first { $0.id == id }?.name
    }
    static func phase(pending: Bool, event: String) -> String {
        pending ? "等你" : event.lowercased().contains("tool") ? "工具" : "思考中"
    }
    // Pure, bounded projection shared by the work page and the lightweight count source.
    static func project(threads: [LiveThreadRecord], pending: Set<UUID>, running: Set<UUID>,
                        bots: BotLibrarySnapshot, jobs: [BackgroundJobManager.Snapshot], now: Date) -> IslandWorkSnapshot {
        var items: [IslandWorkSnapshot.Item] = []
        for thread in threads.prefix(2000) {
            let since = thread.lastOutputAt ?? thread.updatedAt
            let kind: IslandWorkSnapshot.Kind?
            if pending.contains(thread.id) { kind = .awaitingApproval }
            else if thread.subStatus == "failed" { kind = .failed }
            else if (running.contains(thread.id) || thread.subStatus == "running") && now.timeIntervalSince(since) > 900 { kind = .stalled }
            else { kind = nil }
            guard kind != nil || running.contains(thread.id) || thread.subStatus == "running" else { continue }
            let hint = kind == .awaitingApproval ? "等待批准" : kind == .failed ? "房間失敗" : kind == .stalled ? "超過 15 分鐘沒有輸出" : phase(pending: false, event: thread.messages.last?.eventKind ?? "")
            items.append(.init(kind: kind, title: String(thread.title.prefix(200)), target: .init(threadID: thread.id), since: since, hint: hint))
        }
        let dates = ISO8601DateFormatter()
        for bot in bots.bots.prefix(200) {
            guard let pending = bots.pending[bot.id], let first = pending.first else { continue }
            items.append(.init(kind: .pendingMemory, title: String(bot.name.prefix(200)),
                               target: .init(threadID: UUID(uuidString: first.threadID), botID: bot.id),
                               since: dates.date(from: first.at) ?? .distantPast, hint: "\(pending.count) 筆記憶待確認"))
        }
        for job in jobs.prefix(200) {
            let failed = job.exitCode.map { $0 != 0 } ?? false
            guard failed || job.state == "running" else { continue }
            items.append(.init(kind: failed ? .failed : nil, title: String(job.title.prefix(200)),
                               target: .init(threadID: job.threadID, jobID: job.jobID), since: job.startedAt,
                               hint: failed ? "背景工作失敗（\(job.exitCode ?? 0)）" : String(job.lastLine.prefix(200))))
        }
        return .ordered(items)
    }
    static func read(model: ChatPageModel, includeLastLine: Bool = true) async -> IslandWorkSnapshot {
        if IslandWorkSnapshot.isWaitingFixture { return .waitingFixture }
        guard let live = model.live else { return .init() }
        let threads = Array(live.doc.threads.prefix(2000))
        let pending = live.pendingPermissionThreadIDs
        let running = Set(threads.filter { live.isRunning($0.id) }.map(\.id))
        let bots = model.botLibraryForBridge?.snapshot ?? .init()
        let jobs = await OSAgentBridge.shared.backgroundJobSnapshot(includeLastLine: includeLastLine)
        return project(threads: threads, pending: pending, running: running, bots: bots, jobs: jobs, now: Date())
    }
}
