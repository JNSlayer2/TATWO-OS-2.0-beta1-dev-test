import AppKit

/// Quit confirmation is visible even when Tatwo Island or the main window is hidden.
/// No work is detached here: actual cleanup belongs to applicationWillTerminate.
@MainActor
final class TatwoTerminationCoordinator {
    typealias Presenter = (NSWindow?, @escaping (Bool) -> Void) -> Void
    typealias Scheduler = (@escaping () -> Void) -> Void
    private let present: Presenter
    private let schedule: Scheduler
    private(set) var confirmationPending = false

    init(present: Presenter? = nil, schedule: Scheduler? = nil) {
        self.present = present ?? Self.presentNativeConfirmation
        // CEF can invoke terminate from inside a main-queue message-pump block.
        // AppKit then runs a nested event loop waiting for terminateLater.
        // Another main-queue block cannot execute until the outer block returns.
        // A run-loop source remains serviceable during that nested wait.
        self.schedule = schedule ?? { action in
            RunLoop.main.perform(inModes: [.common, .modalPanel, .eventTracking], block: action)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    func request(requiresConfirmation: Bool, window: NSWindow?, reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !confirmationPending else { return .terminateLater }
        guard requiresConfirmation else { return .terminateNow }
        confirmationPending = true
        schedule { [weak self, weak window] in
            guard let self else { reply(false); return }
            var replied = false
            self.present(window) { [weak self] approved in
                guard !replied else { return }
                replied = true
                self?.confirmationPending = false
                reply(approved)
            }
        }
        return .terminateLater
    }

    private static func presentNativeConfirmation(window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "結束 TATWO OS？"
        alert.informativeText = "執行中的工作與瀏覽器下載可能中斷。取消會保留目前的工作狀態。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "結束")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil {
            window.makeKeyAndOrderFront(nil)
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { window.endSheet(alert.window, returnCode: .alertFirstButtonReturn) }
            }
            alert.beginSheetModal(for: window) { response in
                if let observer { NotificationCenter.default.removeObserver(observer) }
                completion(response == .alertSecondButtonReturn)
            }
        } else {
            // This runs on the next turn, never inside AppKit's termination callback.
            // A native modal window also covers the Island-only / no-window case.
            alert.window.level = .modalPanel
            completion(alert.runModal() == .alertSecondButtonReturn)
        }
    }
}
