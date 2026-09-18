import Foundation
import Combine

/// The footer owns a lightweight count subscription; it never activates the Island pager.
/// Updates are bounded to one read/publication per second, including overlapping requests.
@MainActor final class IslandExceptionsCount: ObservableObject {
    static let shared = IslandExceptionsCount()
    /// One bounded snapshot is shared by the footer and the Island list. Keeping
    /// one source prevents the two surfaces from racing separate reads.
    @Published private(set) var data = IslandWorkSnapshot()
    @Published private(set) var hasLoaded = false
    @Published var showsWork = false
    var count: Int { data.exceptions.count }
    private var lastRead: TimeInterval = -.infinity
    private var reading = false
    private let read: @MainActor () async -> IslandWorkSnapshot
    init() {
        self.read = {
            if IslandWorkSnapshot.isWaitingFixture { return IslandWorkSnapshot.waitingFixture }
            guard let model = CLISessionsTermination.model else { return .init() }
            return await IslandWorkProvider.read(model: model, includeLastLine: false)
        }
    }
    init(read: @escaping @MainActor () async -> Int) {
        self.read = {
            let count = await read()
            return .init(exceptions: Array(repeating: .init(kind: .failed, title: "待處理事項",
                                                           target: .init(), since: Date(), hint: "需要查看原因"), count: count))
        }
    }
    init(read: @escaping @MainActor () async -> IslandWorkSnapshot) { self.read = read }
    var text: String { count > 0 ? "有 \(count) 件等你" : "無額外提醒" }
    func refresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        guard !reading, now - lastRead >= 1 else { return }
        reading = true; lastRead = now
        let value = await read()
        reading = false
        guard !Task.isCancelled else { return }
        data = IslandWorkSnapshot.ordered(value.exceptions + value.normal)
        hasLoaded = true
    }
    func observe() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }
}

/// Weak bridge to the existing Island state. No panel, engine, or bot is created here.
@MainActor enum IslandExceptionsNavigation {
    static weak var shell: TatwoIslandShellState?
    static weak var pager: IslandPager?
    static weak var botPage: BotPageState?
    /// Bot 分頁還沒建立（冷啟動只開過 Chat）時暫存目標；BotPageState 下一次 refreshLiveBots 吃掉。
    static var pendingBotID: String?
    static var requestedWork = false
    static func openWork() {
        requestedWork = true
        IslandExceptionsCount.shared.showsWork = true
        selectWork()
        shell?.expandForNavigation()
    }
    static func selectWork() {
        guard requestedWork, let pager, let index = pager.spaces.firstIndex(where: { $0.kind == .work }) else { return }
        pager.select(index); requestedWork = false
    }
    static func open(_ target: IslandWorkSnapshot.Target) {
        if let botID = target.botID, botPage == nil, libraryHasBot(botID) {
            pendingBotID = botID
            CLISessionsTermination.model?.mode = .bot
            return
        }
        if let botID = target.botID, let state = botPage {
            if state.fixture.principals.contains(where: { $0.id == botID }) {
                state.selectPrincipal(botID)
                CLISessionsTermination.model?.mode = .bot
                return
            }
            if let owner = state.fixture.principals.first(where: { $0.subs.contains(where: { $0.id == botID }) }) {
                state.selectSub(botID, of: owner.id)
                CLISessionsTermination.model?.mode = .bot
                return
            }
        }
        if target.threadID == nil, target.jobID != nil {
            // A detached background job has no chat room to select. Route to
            // the CLI work surface instead of rendering a dead "查看" button.
            CLISessionsTermination.model?.mode = .cli
            return
        }
        guard let model = CLISessionsTermination.model, let threadID = target.threadID,
              model.live?.doc.threads.contains(where: { $0.id == threadID }) == true else { return }
        model.mode = .chat
        model.selectLocalThread(threadID)
    }
    static func libraryHasBot(_ id: String) -> Bool {
        CLISessionsTermination.model?.botLibraryForBridge?.bot(id: id) != nil
    }
    static func canOpen(_ target: IslandWorkSnapshot.Target) -> Bool {
        if let botID = target.botID, let state = botPage,
           state.fixture.principals.contains(where: { $0.id == botID || $0.subs.contains(where: { $0.id == botID }) }) { return true }
        if let botID = target.botID, botPage == nil, libraryHasBot(botID) { return true }
        if target.threadID == nil, target.jobID != nil { return CLISessionsTermination.model != nil }
        guard let id = target.threadID else { return false }
        return CLISessionsTermination.model?.live?.doc.threads.contains(where: { $0.id == id }) == true
    }
}
