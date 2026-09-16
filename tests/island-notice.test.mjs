import { writeBrowserVisualTokens } from './helpers/browser-visual-fixture.mjs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const read = p => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
const noticePath = fileURLToPath(new URL('../App/Sources/Tatwo2/New/IslandNotice.swift', import.meta.url));
const compatPath = fileURLToPath(new URL('../App/Sources/Tatwo2/New/ComputerUseConsentPrompt.swift', import.meta.url));
const facade = read('App/Sources/Tatwo2/Facade/OS1Stubs.swift');
const interrupt = facade.slice(facade.indexOf('enum TatwoInterruptKind'), facade.indexOf('// MARK: - CLI 假水電'));
const run = (cmd, args) => execFileSync(cmd, args, { encoding: 'utf8', timeout: 120_000 });

test('swiftc real notice + compatibility UI + presenter: FIFO, timeout, fallback and cancellation', {
  skip: process.platform !== 'darwin', timeout: 180_000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w43-island-notice-'));
  const fixture = join(dir, 'Fixture.swift');
  const binary = join(dir, 'fixture');
  writeFileSync(fixture, String.raw`
import AppKit
import SwiftUI
import Combine

@MainActor enum IslandExceptionsNavigation {
    static var shell: Shell?
    final class Shell { func holdOpen(_ value: Bool) {} }
}
enum LiquidGlassTokens { static let brandAccent = Color.blue }
struct ComputerUseArrowGlyph: View {
    enum Style { case aurora }
    let style: Style
    let spin: Angle
    var body: some View { Color.clear }
}
` + interrupt + String.raw`

@main struct Fixture {
    @MainActor static func pump(_ predicate: () -> Bool, timeout: TimeInterval = 2) {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(predicate(), "run loop stalled")
    }
    @MainActor static func later(_ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: 0.02, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    @MainActor static func main() {
        var holds: [Bool] = []
        let notice = IslandNotice(fallback: { _, _, _ in fatalError("unexpected fallback") },
                                  holdOpen: { holds.append($0) })
        notice.hostAvailable = true
        var shown: [IslandNotice.Kind] = []
        let observation = notice.$current.compactMap { $0?.kind }.sink { shown.append($0) }
        var ask: IslandNotice.Decision?
        var confirm: Bool?
        Task { @MainActor in ask = await notice.ask(title: "ask", detail: "", allowLabel: "允許", timeout: 2) }
        pump { notice.current?.kind == .ask }
        let firstID = notice.current!.id
        Task { @MainActor in confirm = await notice.confirm(title: "confirm", detail: "", timeout: 2) }
        // Main queue marker executes after the scheduled task enqueues confirm.
        var enqueued = false
        DispatchQueue.main.async { enqueued = true }
        pump { enqueued }
        notice.info(title: "info", detail: "", duration: 0.2)
        precondition(shown == [.ask])
        notice.resolve(.allow, id: firstID)
        precondition(notice.current?.kind == .confirm)
        notice.resolve(.allow, id: firstID) // stale click must not accept the next card
        precondition(notice.current?.kind == .confirm)
        notice.resolve(.cancel, id: notice.current!.id)
        precondition(notice.current?.kind == .info)
        precondition(!holds.contains(false), "lease flickered between queued cards")
        pump { notice.current == nil && ask != nil && confirm != nil }
        precondition(ask == .allow && confirm == false)
        precondition(shown == [.ask, .confirm, .info] && holds.last == false)
        withExtendedLifetime(observation) {}
        print("FIFO / stale click / holdOpen passed")

        ask = nil
        confirm = nil
        Task { @MainActor in ask = await notice.ask(title: "timeout", detail: "", allowLabel: "允許", timeout: 0.03) }
        Task { @MainActor in confirm = await notice.confirm(title: "timeout", detail: "", timeout: 0.06) }
        pump { ask != nil && confirm != nil }
        precondition(ask == .timeout && confirm == false && notice.current == nil)
        // Queued requests have bounded lifetimes too; expiry cannot remove the active card.
        notice.info(title: "long info", detail: "", duration: 1)
        confirm = nil
        Task { @MainActor in confirm = await notice.confirm(title: "queued timeout", detail: "", timeout: 0.02) }
        pump { confirm != nil }
        precondition(confirm == false && notice.current?.title == "long info")
        notice.resolve(.cancel, id: notice.current!.id)
        precondition(!notice.confirmBlocking(title: "blocking timeout", detail: "", timeout: 0.03))
        precondition(notice.current == nil)
        // Unlike interactive timeouts, info duration starts when the card is visible.
        notice.info(title: "held info", detail: "", duration: 0.08)
        notice.info(title: "queued info", detail: "", duration: 0.02)
        pump { notice.current?.title == "queued info" }
        precondition(notice.current!.deadline > Date())
        pump { notice.current == nil }
        print("async / queued / blocking timeouts passed")

        var fallbackKinds: [IslandNotice.Kind] = []
        var logs = 0
        var dismisses = 0
        let fallback = IslandNotice(fallback: { request, _, complete in
            fallbackKinds.append(request.kind)
            complete(request.kind == .ask ? .allow : .cancel)
            return { dismisses += 1; complete(.allow) } // late callback ignored
        }, holdOpen: { precondition(!$0) }, log: { _ in logs += 1 })
        ask = nil
        confirm = nil
        Task { @MainActor in ask = await fallback.ask(title: "fallback", detail: "", allowLabel: "允許", timeout: 1) }
        pump { ask != nil }
        Task { @MainActor in confirm = await fallback.confirm(title: "fallback", detail: "", timeout: 1) }
        pump { confirm != nil }
        fallback.info(title: "skip", detail: "")
        precondition(ask == .allow && confirm == false && logs == 1 && dismisses == 2)
        precondition(fallbackKinds == [.ask, .confirm] && fallback.current == nil)
        precondition(!fallback.confirmBlocking(title: "fallback blocking", detail: ""))
        let hanging = IslandNotice(fallback: { _, _, _ in { dismisses += 1 } }, holdOpen: { _ in })
        precondition(!hanging.confirmBlocking(title: "fallback timeout", detail: "", timeout: 0.03))
        precondition(dismisses == 4)
        var hostLostResult: IslandNotice.Decision?
        let migrating = IslandNotice(fallback: { _, _, complete in
            later { complete(.cancel) }
            return nil
        }, holdOpen: { _ in })
        migrating.hostAvailable = true
        Task { @MainActor in hostLostResult = await migrating.ask(title: "host lost", detail: "", allowLabel: "允許", timeout: 1) }
        pump { migrating.current != nil }
        migrating.hostAvailable = false
        precondition(migrating.current == nil)
        pump { hostLostResult != nil }
        precondition(hostLostResult == .cancel)
        print("injected fallback / cleanup / info logging passed")

        let shared = IslandNotice.shared
        shared.hostAvailable = true
        // Window close / Esc only ask while work is running; simulate running work here.
        TatwoInterruptGate.activityProvider = { true }
        for kind: TatwoInterruptKind in [.appTerminate, .windowClose, .escapeClose, .composerStop] {
            later {
                precondition(shared.current?.kind == .confirm)
                precondition(shared.current?.allowLabel == "確認" && shared.current?.cancelLabel == "取消")
                precondition(!shared.confirmBlocking(title: "reentrant", detail: ""))
                shared.resolve(.cancel, id: shared.current!.id)
            }
            precondition(!TatwoInterruptConfirmationPresenter.confirm(kind: kind))
        }
        later { shared.resolve(.cancel, id: shared.current!.id) }
        precondition(!TatwoInterruptConfirmationPresenter.confirm(kind: .appTerminate,
            snapshot: TatwoLoopsTerminationSnapshot(), window: nil))
        later { shared.resolve(.allow, id: shared.current!.id) }
        precondition(TatwoInterruptConfirmationPresenter.confirm(kind: .windowClose, window: nil))
        precondition(TatwoInterruptGate.decision(kind: .appTerminate,
            snapshot: TatwoLoopsTerminationSnapshot()).requiresConfirmation)
        // No running work: window close passes through without any card.
        TatwoInterruptGate.activityProvider = { false }
        // One-shot bypass after the Island "重開" confirmation: the hand-off terminate does not ask again.
        TatwoInterruptGate.bypassNextTerminate = true
        precondition(!TatwoInterruptGate.decision(kind: .appTerminate, snapshot: TatwoLoopsTerminationSnapshot()).requiresConfirmation)
        precondition(TatwoInterruptGate.decision(kind: .appTerminate, snapshot: TatwoLoopsTerminationSnapshot()).requiresConfirmation)
        precondition(TatwoInterruptConfirmationPresenter.confirm(kind: .windowClose, window: nil) && shared.current == nil)
        precondition(TatwoInterruptConfirmationPresenter.confirm(kind: .escapeClose, window: nil) && shared.current == nil)
        var taskBlocking: Bool?
        Task { @MainActor in
            later { shared.resolve(.allow, id: shared.current!.id) }
            taskBlocking = shared.confirmBlocking(title: "inside MainActor Task", detail: "")
        }
        pump { taskBlocking != nil }
        precondition(taskBlocking == true)
        print("all presenter overloads / nested denial / quit gate passed")

        var wrapperResult: IslandNotice.Decision?
        shared.info(title: "unrelated", detail: "", duration: 1)
        Task { @MainActor in
            wrapperResult = await ComputerUseConsentPrompt.shared.ask(title: "compat", detail: "", allowLabel: "允許", timeout: 1)
        }
        enqueued = false
        DispatchQueue.main.async { enqueued = true }
        pump { enqueued }
        ComputerUseConsentPrompt.shared.resolve(.cancel)
        pump { wrapperResult != nil }
        precondition(wrapperResult == .cancel && shared.current?.kind == .info)
        shared.resolve(.cancel, id: shared.current!.id)
        var cancelled: IslandNotice.Decision?
        let task = Task { @MainActor in cancelled = await shared.ask(title: "cancel", detail: "", allowLabel: "允許", timeout: 1) }
        pump { shared.current != nil }
        task.cancel()
        pump { cancelled != nil }
        precondition(cancelled == .cancel && shared.current == nil)
        print("compatibility cancellation ownership / Task cancellation passed")
        if let destination = ProcessInfo.processInfo.environment["W54_ISLAND_UI_EVIDENCE_DIR"] {
            let root = URL(fileURLWithPath: destination)
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSApplication.shared.setActivationPolicy(.accessory)
            for (name, kind, title, detail) in [("ask", IslandNotice.Kind.ask, "example.com 想用麥克風", "允許這個網站使用麥克風？"),
                ("confirm", .confirm, "網頁想執行工具", "example.com・set_note・可能修改或送出資料，只允許這一次？"),
                ("info", .info, "已下載 fixture-report.pdf", "在下載項目裡；6 秒後自動收起")] {
                let request = IslandNotice.Request(id: UUID(), kind: kind, title: title, detail: detail,
                    allowLabel: "允許", cancelLabel: "取消", deadline: Date().addingTimeInterval(20))
                let host = NSHostingView(rootView: ComputerUseConsentCard(request: request))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 346, height: 130),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderBack(nil)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
                window.close()
            }
        }
    }
}
`);
  run('swiftc', ['-swift-version', '6', '-parse-as-library', '-num-threads', '2', noticePath, compatPath, fixture, writeBrowserVisualTokens(dir), '-o', binary]);
  const output = run(binary, []);
  for (const expected of ['FIFO / stale click', 'async / queued / blocking', 'injected fallback', 'all presenter overloads', 'compatibility cancellation']) {
    assert.ok(output.includes(expected), output);
  }
});

test('shell renders shared content and every interrupt caller preserves the Bool guard', () => {
  const shell = read('App/Sources/Tatwo2/Shell/TatwoIslandShell.swift');
  assert.match(shell, /IslandNoticeContent\(isExpanded: state.isExpanded\)/);
  assert.match(shell, /IslandNotice.shared.hostAvailable = true/);
  assert.match(shell, /if event.keyCode == 53[\s\S]*IslandNotice.shared.resolve\(.cancel, id: request.id\)\s*return nil/);
  const compat = read('App/Sources/Tatwo2/New/ComputerUseConsentPrompt.swift');
  assert.match(compat, /@ObservedObject private var prompt = IslandNotice.shared/);
  assert.match(compat, /request.kind != .info/);
  assert.match(compat, /frame\(width: LiquidGlassTokens.islandBlankWidth, height: LiquidGlassTokens.islandBlankHeight\)/);
  assert.match(compat, /IslandNotice.shared.info\(title:/);
  const app = read('App/Sources/Tatwo2/Shell/AppShell.swift');
  assert.match(app, /NSApp.reply\(toApplicationShouldTerminate: confirmed\)/);
  assert.match(app, /guard TatwoInterruptConfirmationPresenter.confirm\(kind: .escapeClose/);
  assert.match(app, /guard TatwoInterruptConfirmationPresenter.confirm\(kind: .windowClose/);
  for (const path of ['Chat/ChatPage+Composer.swift', 'CLI/CLILoopDetailPane.swift']) {
    assert.match(read(`App/Sources/Tatwo2/${path}`), /guard TatwoInterruptConfirmationPresenter.confirm\(kind: .composerStop\)/);
  }
});

test('window close asks only while work is running; app terminate and composer stop always ask', () => {
  const stubs = readFileSync(new URL('../App/Sources/Tatwo2/Facade/OS1Stubs.swift', import.meta.url), 'utf8');
  assert.match(stubs, /static var activityProvider: \(\) -> Bool/);
  assert.match(stubs, /case \.appTerminate:\n\s*if bypassNextTerminate \{ bypassNextTerminate = false; return \.init\(requiresConfirmation: false\) \}\n\s*return \.init\(requiresConfirmation: true\)\n\s*case \.composerStop: return \.init\(requiresConfirmation: true\)/);
  assert.match(stubs, /case \.windowClose, \.escapeClose: return \.init\(requiresConfirmation: activityProvider\(\)\)/);
  assert.match(stubs, /guard TatwoInterruptGate\.decision\(kind: kind, snapshot: \.init\(\)\)\.requiresConfirmation else \{ return true \}/);
  const page = readFileSync(new URL('../App/Sources/Tatwo2/Chat/ChatPage.swift', import.meta.url), 'utf8');
  assert.match(page, /TatwoInterruptGate\.activityProvider = \{ \[weak model\] in\s*model\?\.hasRunningWork \?\? false/);
});
