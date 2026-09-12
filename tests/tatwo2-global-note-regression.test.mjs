import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import test from 'node:test';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = name => readFileSync(path.join(repo, name), 'utf8');
const hash = value => createHash('sha256').update(value).digest('hex');

test('native note store and panel preserve edits, selection and search', {
  skip: process.platform !== 'darwin',
  timeout: 90_000,
}, async () => {
  const run = (command, args, options = {}) => {
    const result = spawnSync(command, args, {
      cwd: repo, encoding: 'utf8', timeout: 60_000, maxBuffer: 1024 * 1024,
      ...options,
    });
    assert.equal(result.status, 0, `${command}: ${result.error || ''}\n${result.stdout}\n${result.stderr}`);
    return result;
  };
  const pressure = run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']).stdout.trim();
  // Previously measured ~274 MiB for this one serial fixture, not an App build.
  assert.equal(pressure, '1', `defer fixture at pressure=${pressure}`);
  const output = path.join(repo, 'output/lightweight-repair');
  mkdirSync(output, { recursive: true });
  const scratch = mkdtempSync(path.join(output, 'note-regression.'));
  const lockScript = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquired = run('/bin/bash', [lockScript, 'acquire', '--timeout', '20', '--pid', String(process.pid)]);
  const token = acquired.stdout.match(/^token=([0-9a-f]+)$/m)?.[1];
  assert.ok(token, 'build lock ownership returned');
  try {
    const store = read('App/Sources/Tatwo2/Facade/GlobalNoteStore.swift');
    const panel = read('App/Sources/Tatwo2/New/GlobalNotePanel.swift');
    const modelEnd = panel.indexOf('struct GlobalNotePanel: View');
    assert.ok(modelEnd > 0);
    const statusView = panel.split('\n').find(line => line.includes('if !model.statusMessage.isEmpty'));
    assert.ok(statusView, 'compile the actual existing status-slot expression');
    // Exact production store and panel model; inject only an isolated file
    // root and preferences suite. No user notes, defaults or model calls.
    const source = `
import Foundation
import SwiftUI
enum OSUpstreamBinding {
    static func osRoot() -> String { fatalError("test must inject its note root") }
}
${store}
${panel.slice(0, modelEnd)}
@MainActor struct NoteStatusPreview: View {
    @ObservedObject var model: GlobalNotePanelModel
    var body: some View {
        VStack(alignment: .leading) {
            Text("既有筆記狀態欄・人工資料預覽").font(.caption).foregroundStyle(.secondary)
            ${statusView}
        }.padding(12).frame(width: 380, height: 110, alignment: .leading)
            .background(Color(NSColor.windowBackgroundColor))
    }
}
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private struct TestFailure: Error { let message: String }
@main struct NoteRegression {
    @MainActor static func main() async {
        GlobalNoteStore.runTestIfRequested()
        do { try await verify() }
        catch { print("NOTEREGRESSION FAIL: \\(error)"); exit(1) }
    }
    @MainActor static func verify() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("library")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let a = GlobalNoteStore(root: root.path), b = GlobalNoteStore(root: root.path)
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw TestFailure(message: name) }
            checks += 1; print("PASS: " + name)
        }
        try await a.perform { s in try s.prepare(); try s.save("note.md", text: "base", expected: "") }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let secondEntered = Flag()
        let first = Task.detached {
            try await a.perform { s in
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure(message: "release timeout") }
                try s.save("note.md", text: "first writer", expected: "base")
            }
        }
        let didEnter = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
        try check(didEnter, "first transaction entered")
        let second = Task.detached {
            do {
                try await b.perform { s in secondEntered.set(); try s.save("note.md", text: "second writer", expected: "base") }
                return false
            } catch GlobalNoteStore.Failure.conflict { return true }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let overlapped = secondEntered.get()
        release.signal()
        // Always join both tasks before evaluating the race result.
        let firstResult = await first.result, secondResult = await second.result
        try check(!overlapped, "separate stores cannot overlap file transactions")
        try firstResult.get()
        try check(try secondResult.get(), "stale second writer reports conflict")
        try check(try await a.perform { try $0.read("note.md") } == "first writer", "first writer remains intact")
        let defaults = UserDefaults(suiteName: "note-regression-" + UUID().uuidString)!
        let model = GlobalNotePanelModel(store: a, defaults: defaults)
        await model.load()
        await model.mutate { s in try s.create("folder", folder: true); try s.create("folder/first.md", folder: false); try s.create("other.md", folder: false) }
        await model.open("folder/first.md")
        model.text = "needle content"
        try check(await model.save(), "editor content saves")
        model.query = "needle"; model.search()
        for _ in 0..<100 { if !model.hits.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try check(model.hits.contains { $0.path == "folder/first.md" }, "search sees saved text")
        await model.move("folder/first.md", to: "folder/renamed.md", folder: false)
        try check(model.path == "folder/renamed.md" && model.text == "needle content", "rename keeps selected document and text")
        try check(defaults.string(forKey: "tatwo2.note.lastFile") == model.path, "rename persists new selection")
        try check(model.hits.isEmpty, "mutation clears obsolete search targets immediately")
        for _ in 0..<100 { if !model.hits.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try check(model.hits.contains { $0.path == "folder/renamed.md" }
            && !model.hits.contains { $0.path == "folder/first.md" }, "search refreshes after rename")
        await model.move("folder", to: "renamed-folder", folder: true)
        try check(model.path == "renamed-folder/renamed.md" && model.text == "needle content", "folder rename follows selected child")
        await model.move("other.md", to: "other-renamed.md", folder: false)
        try check(model.path == "renamed-folder/renamed.md", "renaming other file does not steal selection")
        await model.mutate { try $0.trash("renamed-folder/renamed.md", folder: false) }
        try check(model.path == "note.md" && model.text == "first writer", "trash selected note opens default without stale text")
        try check(defaults.string(forKey: "tatwo2.note.lastFile") == "note.md", "trash persists valid selection")
        await model.open("other-renamed.md")
        try await b.perform { try $0.save("other-renamed.md", text: "external change", expected: "") }
        model.text = "unsaved local edit"
        try check(!(await model.save()) && model.text == "unsaved local edit" && !model.error.isEmpty, "conflict preserves unsaved editor content")
        try check(try await a.perform { try $0.read("other-renamed.md") } == "external change", "conflict never overwrites external content")
        model.cancelSearch()
        let fallbackRoot = root.appendingPathComponent("fallback-test")
        try fm.createDirectory(at: fallbackRoot, withIntermediateDirectories: false)
        let old = fallbackRoot.appendingPathComponent("note.md"), obstacle = fallbackRoot.appendingPathComponent("note")
        try Data("retained".utf8).write(to: old)
        try Data("not a folder".utf8).write(to: obstacle)
        let fallback = GlobalNoteStore(root: fallbackRoot.path)
        try await fallback.perform { try $0.prepare() }
        let kept = fallbackRoot.appendingPathComponent("retained-original")
        try fm.moveItem(at: old, to: kept)
        try fm.createSymbolicLink(at: old, withDestinationURL: kept)
        var rejected = false
        do { _ = try await fallback.perform { try $0.read("note.md") } }
        catch GlobalNoteStore.Failure.invalidPath { rejected = true }
        try check(rejected, "fallback rechecks replacement symlinks before reading")
        try fm.moveItem(at: old, to: fallbackRoot.appendingPathComponent("retained-link"))
        try fm.moveItem(at: kept, to: old)
        try fm.moveItem(at: obstacle, to: fallbackRoot.appendingPathComponent("retained-obstacle"))
        try await fallback.perform { s in try s.prepare(); try s.save("note.md", text: "recovered", expected: "retained") }
        try check(try await fallback.perform { try $0.read("note.md") } == "recovered", "successful retry clears obsolete fallback mode")

        let corruptFile = root.appendingPathComponent("note/aaa-corrupt-needle.md")
        let corruptBytes = Data([0xff, 0xfe, 0xff])
        try corruptBytes.write(to: corruptFile)
        try await a.perform { s in
            try s.create("zzz-readable.md", folder: false)
            try s.save("zzz-readable.md", text: "line one\\nneedle after corrupt file", expected: "")
        }
        let searchModel = GlobalNotePanelModel(store: a, defaults: defaults)
        await searchModel.load()
        searchModel.query = "needle"; searchModel.search()
        for _ in 0..<100 {
            if searchModel.hits.contains(where: { $0.path == "zzz-readable.md" }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(searchModel.hits.contains { $0.path == "zzz-readable.md" && $0.line == 2 },
                  "corrupt note does not abort other content results")
        try check(searchModel.hits.contains { $0.path == "aaa-corrupt-needle.md" && $0.line == 0 },
                  "unreadable note can still match its filename")
        try check(try Data(contentsOf: corruptFile) == corruptBytes, "search never repairs or rewrites corrupt input")
        try check(searchModel.searchError == "有 1 份筆記無法讀取；其餘搜尋已完成。" && searchModel.error.isEmpty,
                  "partial results disclose unreadable count without claiming full coverage")
        searchModel.error = "存檔衝突，未覆蓋原檔。"
        try check(searchModel.statusMessage.contains(searchModel.error) && searchModel.statusMessage.contains(searchModel.searchError),
                  "search warning does not hide an editor failure")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: NoteStatusPreview(model: searchModel))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 80_000_000)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw TestFailure(message: "status bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("note-search-status.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        window.close()
        try check(host.bounds.width == 380 && host.bounds.height == 110, "render existing error slot with partial search and save failure")
        searchModel.query = ""; searchModel.search()
        try check(searchModel.hits.isEmpty && searchModel.searchError.isEmpty && !searchModel.error.isEmpty,
                  "clearing query immediately clears only search state")
        searchModel.query = "needle"; searchModel.search()
        try await Task.sleep(nanoseconds: 220_000_000)
        searchModel.query = "not-present"; searchModel.search()
        for _ in 0..<100 { if !searchModel.searchError.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try check(searchModel.hits.isEmpty && !searchModel.searchError.isEmpty,
                  "new query cannot show old query matches and still reports incomplete coverage")
        try fm.moveItem(at: corruptFile, to: root.appendingPathComponent("retained-corrupt-input"))
        try Data("repaired needle".utf8).write(to: corruptFile)
        searchModel.query = "needle"; searchModel.search()
        for _ in 0..<100 { if !searchModel.hits.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try check(searchModel.searchError.isEmpty && !searchModel.hits.isEmpty && !searchModel.error.isEmpty,
                  "successful re-search clears stale search warning but preserves editor failure")
        var skipped: [String] = []
        let unreadable = root.appendingPathComponent("note/000-no-permission.md")
        try Data("needle not readable".utf8).write(to: unreadable)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        let permissionResults: [GlobalNoteStore.Hit]
        do {
            permissionResults = try await a.perform { s in
                try s.search("needle", cancelled: { false }, onUnreadable: { skipped.append($0) })
            }
        } catch {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
            throw error
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        try check(skipped == ["000-no-permission.md"] && permissionResults.contains { $0.path == "zzz-readable.md" },
                  "permission-denied file is reported and healthy results survive")
        let cancelledRoot = root.appendingPathComponent("missing-root")
        var cancelledBeforeList = false
        do {
            _ = try await GlobalNoteStore(root: cancelledRoot.path).perform { try $0.search("needle", cancelled: { true }) }
        } catch is CancellationError { cancelledBeforeList = true }
        try check(cancelledBeforeList, "cancelled search stops before enumerating even a missing library")
        var missingRootFailed = false
        do {
            _ = try await GlobalNoteStore(root: cancelledRoot.path).perform { try $0.search("needle", cancelled: { false }) }
        } catch { missingRootFailed = !(error is CancellationError) }
        try check(missingRootFailed, "missing library is a real failure rather than empty success")
        let missingModel = GlobalNotePanelModel(store: GlobalNoteStore(root: cancelledRoot.path), defaults: defaults)
        missingModel.hits = searchModel.hits
        missingModel.error = "unsaved editor error"
        missingModel.query = "needle"; missingModel.search()
        try check(missingModel.hits.isEmpty, "starting a search removes previous targets immediately")
        for _ in 0..<100 { if !missingModel.searchError.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try check(!missingModel.searchError.isEmpty && missingModel.error == "unsaved editor error",
                  "fatal search error coexists with editor failure")
        missingModel.query = ""; missingModel.search()
        try check(missingModel.searchError.isEmpty && missingModel.error == "unsaved editor error",
                  "clear also removes a stale fatal search error without hiding editor failure")
        searchModel.query = "needle"; searchModel.search()
        searchModel.cancelSearch()
        try await Task.sleep(nanoseconds: 220_000_000)
        try check(searchModel.hits.isEmpty && searchModel.searchError.isEmpty, "cancelled debounce cannot publish results or warnings")
        searchModel.cancelSearch()
        try corruptBytes.write(to: root.appendingPathComponent("note/zzz-cancel-corrupt.md"))
        var cancelledAfterSkip = false
        do {
            _ = try await a.perform { s in
                var cancelled = false
                return try s.search("needle", cancelled: { cancelled }, onUnreadable: { _ in cancelled = true })
            }
        } catch is CancellationError { cancelledAfterSkip = true }
        try check(cancelledAfterSkip, "cancellation after a failed read is not swallowed as partial success")
        print("NOTEREGRESSION RESULT checks=\\(checks) failures=0")
    }
}
`;
    writeFileSync(path.join(scratch, 'NoteRegression.swift'), source);
    const compiler = run('/usr/bin/xcrun', ['--find', 'swiftc']).stdout.trim();
    const sdk = run('/usr/bin/xcrun', ['--sdk', 'macosx', '--show-sdk-path']).stdout.trim();
    const binary = path.join(scratch, 'note-regression');
    const env = { ...process.env, HOME: scratch, CFFIXED_USER_HOME: scratch, TMPDIR: scratch,
      TATWO2_NOTETEST: '0', TATWO_ULTRAWORK_EXPORT_GLOBAL_NOTE: '' };
    const compiled = run('/usr/bin/time', ['-l', compiler, '-j', '2', '-swift-version', '5', '-parse-as-library',
      '-sdk', sdk, '-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx14.0`,
      '-module-cache-path', path.join(output, 'minimap-swift-cache'),
      path.join(scratch, 'NoteRegression.swift'), '-o', binary], { env });
    writeFileSync(path.join(scratch, 'compile.log'), compiled.stdout + compiled.stderr);
    writeFileSync(path.join(scratch, 'preflight.json'), JSON.stringify({ pressure }, null, 2));
    const result = run(binary, [scratch], { env });
    writeFileSync(path.join(scratch, 'result.log'), result.stdout + result.stderr);
    assert.match(result.stdout, /NOTEREGRESSION RESULT checks=35 failures=0/);
    const legacy = run(binary, [scratch], { env: { ...env, TATWO2_NOTETEST: '1' } });
    writeFileSync(path.join(scratch, 'existing-store-tests.log'), legacy.stdout + legacy.stderr);
    assert.match(legacy.stdout, /NOTETEST PASS\n/);
    assert.doesNotMatch(legacy.stdout, /NOTETEST FAIL/);
    writeFileSync(path.join(scratch, 'receipt.json'), JSON.stringify({
      at: new Date().toISOString(), storeSHA256: hash(store), panelSHA256: hash(panel),
      fixtureSHA256: hash(source), testSHA256: hash(read('tests/tatwo2-global-note-regression.test.mjs')),
      statusPNG: hash(readFileSync(path.join(scratch, 'note-search-status.png'))),
      scope: 'Actual store and panel model, isolated artificial files/preferences; actual status-slot expression only, not full App or formal UI acceptance.',
    }, null, 2));
    console.log(result.stdout.trim());
    console.log(legacy.stdout.trim());
    console.log(`Evidence: ${scratch}`);
  } finally {
    run('/bin/bash', [lockScript, 'release', '--token', token, '--pid', String(process.pid)]);
  }
});
