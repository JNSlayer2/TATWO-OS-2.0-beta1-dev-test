import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
test('real AppKit composer does not publish stale or unlaid-out heights', { timeout: 120_000 }, t => {
  if (process.platform !== 'darwin') return t.skip('requires AppKit');
  const source = fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Chat/ChatPageAppKitBridges.swift'), 'utf8');
  const start = source.indexOf('enum ChatComposerSuggestionKey');
  assert.ok(start > 0);
  const scratch = fs.mkdtempSync(path.join(repo, 'output/lightweight-repair/composer-layout.'));
  const program = path.join(scratch, 'checks.swift');
  fs.writeFileSync(program, `
import AppKit
import SwiftUI
final class TatwoThemeStore: ObservableObject { static let shared = TatwoThemeStore() }
enum ChatTypography { static let composerPointSize: CGFloat = 14 }
enum ChatComposerSlashCatalog { static let commands = ["/討論串"] }
enum LiquidGlassTokens { static let brandAccent = Color.blue }
${source.slice(start)}
@MainActor func probe() {
    _ = NSApplication.shared
    var text = "", height: CGFloat = 24
    var passed = 0, failed = 0
    func check(_ name: String, _ value: Bool) {
        if value { passed += 1 } else { failed += 1 }
        print("COMPOSERLAYOUTTEST \\(value ? "PASS" : "FAIL") \\(name)")
    }
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    let coordinator = ChatComposerTextView.Coordinator(
        text: Binding(get: { text }, set: { text = $0 }),
        contentHeight: Binding(get: { height }, set: { height = $0 }),
        minimumHeight: 24, maximumHeight: 180, onSubmit: {}, onFocusChange: { _ in })
    let view = ChatComposerTextView.ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    _ = view.layoutManager
    view.font = .systemFont(ofSize: 14)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.delegate = coordinator
    // A long draft and its clear/send arrive within one SwiftUI update cycle.
    view.string = String(repeating: "一段中英 mixed text ", count: 40)
    coordinator.refreshContentHeight(for: view)
    view.string = ""
    coordinator.refreshContentHeight(for: view)
    drain()
    check("clear invalidates previously queued tall height", height == 24)
    height = 24
    view.setFrameSize(NSSize(width: 0, height: 24))
    view.string = "尚未完成 layout"
    coordinator.refreshContentHeight(for: view)
    drain()
    check("zero-width initial layout does not expand to maximum", height == 24)
    view.setFrameSize(NSSize(width: 240, height: 24))
    view.string = "第一行\\n第二行\\n第三行\\n"
    coordinator.refreshContentHeight(for: view)
    drain()
    let lm = view.layoutManager!
    check("trailing newline includes the caret line",
          height >= ceil(lm.extraLineFragmentRect.maxY))
    view.string = String(repeating: "寬度變化 mixed text ", count: 12)
    coordinator.refreshContentHeight(for: view)
    drain()
    check("long draft is clamped while document remains scrollable", height <= 180 && view.frame.height >= height)
    let selection = NSRange(location: 3, length: 4)
    view.setSelectedRange(selection)
    view.setFrameSize(NSSize(width: 1000, height: view.frame.height))
    drain()
    let wideHeight = height
    view.setFrameSize(NSSize(width: 180, height: view.frame.height))
    drain()
    check("native width changes reflow without a SwiftUI update", height > wideHeight)
    for width: CGFloat in [640, 180, 480, 240] {
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }
    drain()
    check("reflow preserves selected text", view.selectedRange() == selection)
    check("reflow does not edit the draft", view.string == String(repeating: "寬度變化 mixed text ", count: 12))
    view.string = "短句"
    coordinator.refreshContentHeight(for: view)
    drain()
    check("short text restores minimum height", height == 24)
    view.setMarkedText("注音組字", selectedRange: NSRange(location: 4, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
    let markedText = view.string
    let markedRange = view.markedRange()
    view.setFrameSize(NSSize(width: 180, height: view.frame.height))
    coordinator.refreshContentHeight(for: view)
    drain()
    check("reflow does not commit IME composition", view.hasMarkedText() && view.markedRange() == markedRange)
    check("reflow preserves composing text", view.string == markedText)
    view.unmarkText()
    print("COMPOSERLAYOUTTEST RESULT passed=\\(passed) failed=\\(failed) skipped=0")
    exit(failed == 0 ? 0 : 1)
}
MainActor.assumeIsolated { probe() }
`);
  const build = spawnSync('/bin/bash', ['-c', `
set -euo pipefail
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 90 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
nice -n 10 xcrun swiftc "$1" -o "$2"
`, 'composer-layout', program, path.join(scratch, 'checks')], {
    cwd: repo, encoding: 'utf8', timeout: 100_000, env: { ...process.env, TMPDIR: scratch },
  });
  assert.equal(build.status, 0, build.stderr || String(build.error));
  const run = spawnSync(path.join(scratch, 'checks'), [], { encoding: 'utf8', timeout: 10_000 });
  process.stdout.write(run.stdout);
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
