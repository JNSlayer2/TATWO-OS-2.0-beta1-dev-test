@MainActor final class TatwoUltraworkAppDelegate: NSObject {
    var reply: NSApplication.TerminateReply = .terminateLater
    var asked = 0
    var terminated = 0
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { asked += 1; return reply }
    func applicationWillTerminate(_ notification: Notification) { terminated += 1; CLISessionsTermination.events.append("wrapped") }
    func application(_ application: NSApplication, open urls: [URL]) {}
}
@MainActor enum CLISessionsTermination {
    static var events: [String] = []
    static func shouldTerminate() -> Bool { events += ["save", "detach", "finishWrites"]; return true }
}
@main struct Fixture {
    @MainActor static func main() {
        var queued: [() -> Void] = []
        var answer: ((Bool) -> Void)?
        var presentations = 0
        var replies: [Bool] = []
        let coordinator = TatwoTerminationCoordinator(present: { _, completion in
            presentations += 1; answer = completion
        }, schedule: { queued.append($0) })
        precondition(coordinator.request(requiresConfirmation: false, window: nil, reply: { replies.append($0) }) == .terminateNow)
        precondition(!coordinator.confirmationPending && queued.isEmpty && replies.isEmpty)
        precondition(coordinator.request(requiresConfirmation: true, window: nil, reply: { replies.append($0) }) == .terminateLater)
        precondition(coordinator.request(requiresConfirmation: true, window: nil, reply: { replies.append($0) }) == .terminateLater)
        precondition(queued.count == 1 && presentations == 0 && coordinator.confirmationPending)
        queued.removeFirst()()
        precondition(presentations == 1)
        answer?(false)
        precondition(replies == [false] && !coordinator.confirmationPending)
        answer?(true)
        precondition(replies == [false], "late duplicate callback must not approve a cancelled Quit")
        precondition(coordinator.request(requiresConfirmation: true, window: nil, reply: { replies.append($0) }) == .terminateLater)
        queued.removeFirst()(); answer?(true)
        precondition(replies == [false, true] && presentations == 2)

        let wrapped = TatwoUltraworkAppDelegate()
        let delegate = Tatwo2CLITerminationDelegate(wrapped: wrapped)
        let app = NSApplication.shared
        precondition(delegate.applicationShouldTerminate(app) == .terminateLater)
        precondition(CLISessionsTermination.events.isEmpty && wrapped.asked == 1)
        wrapped.reply = .terminateCancel
        precondition(delegate.applicationShouldTerminate(app) == .terminateCancel)
        precondition(CLISessionsTermination.events.isEmpty)
        wrapped.reply = .terminateNow
        precondition(delegate.applicationShouldTerminate(app) == .terminateNow)
        precondition(CLISessionsTermination.events.isEmpty, "even bypass cleanup waits for actual termination")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        precondition(CLISessionsTermination.events == ["save", "detach", "finishWrites", "wrapped"])
        precondition(wrapped.terminated == 1)
        print("PASS: native Quit scheduling, cancellation, explicit approval, bypass, duplicate requests and post-approval CLI persistence ordering")
    }
}
