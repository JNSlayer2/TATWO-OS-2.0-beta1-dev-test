import Foundation
import Combine

/// The footer owns a lightweight count subscription; it never activates the Island pager.
/// Updates are bounded to one read/publication per second, including overlapping requests.
@MainActor final class IslandExceptionsCount: ObservableObject {
    @Published private(set) var count = 0
    private var lastRead: TimeInterval = -.infinity
    private var reading = false
    private let read: @MainActor () async -> Int
    init(read: @escaping @MainActor () async -> Int = {
        if IslandWorkSnapshot.isWaitingFixture { return IslandWorkSnapshot.waitingFixture.exceptions.count }
        guard let model = CLISessionsTermination.model else { return 0 }
        return await IslandWorkProvider.read(model: model, includeLastLine: false).exceptions.count
    }) { self.read = read }
    var text: String { count > 0 ? "有 \(count) 件等你" : "無額外提醒" }
    func refresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        guard !reading, now - lastRead >= 1 else { return }
        reading = true; lastRead = now
        let value = await read()
        reading = false
        guard !Task.isCancelled else { return }
        count = max(0, min(20, value))
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
        guard let id = target.threadID else { return false }
        return CLISessionsTermination.model?.live?.doc.threads.contains(where: { $0.id == id }) == true
    }
}
