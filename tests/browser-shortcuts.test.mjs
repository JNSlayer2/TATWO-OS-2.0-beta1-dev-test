import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
const root = new URL('../', import.meta.url).pathname;
const b = 'App/Sources/Tatwo2/Browser/';
const read = p => readFileSync(join(root,p),'utf8');

test('W57e only map-derived browser shortcuts, ordered settings and recording UI', () => {
  for (const file of ['BrowserDailyNavigationControls.swift','BrowserWorkSpaceDesignView.swift']) {
    assert.doesNotMatch(read(b+file), /\.keyboardShortcut\("(?:w|l|r|\[|\]|f|\+|=|-|[0-9]|t)"/);
  }
  const settings = read('App/Sources/Tatwo2/Shell/ChatPageSettings.swift');
  assert.match(settings, /browserSettingsCard\("Browser work space"\)[\s\S]*?browserSettingsCard\("快捷鍵"\) \{ BrowserShortcutsSettingsView\(\) \}[\s\S]*?browserSettingsCard\("Session 瀏覽器"\)/);
  const ui = read(b+'BrowserShortcutsSettingsView.swift');
  for (const copy of ['預設只有 ⌘T 新分頁；其餘功能請自行指定','全部還原預設','未設定','設定…','Delete 清除']) assert.ok(ui.includes(copy),copy);
  assert.match(ui, /BrowserAction\.allCases/);
  assert.match(ui, /map\.validationError\(for: combo, action: action\)/);
  const model = read(b+'BrowserShortcuts.swift');
  for (const copy of ['已被 OS 使用', '與『']) assert.ok(model.includes(copy));
  const design = read(b+'BrowserWorkSpaceDesignView.swift');
  assert.match(design, /Button\("搜尋分頁…", action: openTabSearch\)/);
  assert.match(design, /case \.openImport: store\.requestImport\(\)/);
  assert.match(design, /func requestImport\(\) \{[\s\S]*?tatwo\.browser\.openImport/);
  assert.match(design, /Button\(store\.focusMode \? "離開專注模式" : "專注模式"\) \{ store\.focusMode\.toggle\(\) \}/);
  assert.match(ui, /firstResponder === self/);
  assert.doesNotMatch(ui, /addGlobalMonitor|addLocalMonitor/);
  assert.match(read(b+'BrowserDailyNavigationControls.swift'), /legacyCombo\(shortcutKind\)/);
  for (const file of ['BrowserWorkSpaceDesignView.swift','EmbeddedBrowserView.swift']) {
    assert.match(read(b+file), /BrowserAnnotationSheet\(tab: [^)]*\)\.background\(BrowserAnnotationShortcutDismiss\(\)\)/);
  }
});

test('W57e Swift defaults, round-trip, normalized conflicts, number-group reservations and tolerant settings', {skip:process.platform!=='darwin',timeout:120000}, () => {
  const dir = mkdtempSync(join(tmpdir(),'w57e-shortcuts-'));
  const source = join(dir,'Checks.swift'), binary = join(dir,'checks');
  writeFileSync(source, String.raw`
import Foundation
@main struct Checks {
 static func main() throws {
    let defaults = BrowserShortcutMap.defaults
    precondition(defaults.bindings.count == 1 && defaults.bindings[.newTab] == BrowserKeyCombo(key: "t", modifiers: ["command"]))
    for action in BrowserAction.allCases {
        precondition(action.title.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        precondition(["分頁", "導覽", "檢視", "工具"].contains(action.group))
    }
    let roundTrip = try JSONDecoder().decode(BrowserShortcutMap.self, from: JSONEncoder().encode(defaults))
    precondition(roundTrip == defaults)
    precondition(defaults.conflicts(with: BrowserKeyCombo(key: "T", modifiers: ["command", "command"])) == [.newTab])
    precondition(defaults.conflicts(with: BrowserKeyCombo(key: "t", modifiers: ["command"]), excluding: .newTab).isEmpty)
    precondition(BrowserKeyCombo(key: "t", modifiers: ["command", "shift"]).display == "⇧⌘T")
    precondition(BrowserKeyCombo(key: "TAB", modifiers: ["control"]).display == "⌃⇥")
    precondition(BrowserAction.closeTab.requiresTab && !BrowserAction.newTab.requiresTab)
    for key in ["q", "w", "h", "m", ",", "n", "s", "l"] { precondition(BrowserShortcutMap.isReserved(BrowserKeyCombo(key: key, modifiers: ["command"]))) }
    precondition(BrowserShortcutMap.isReserved(BrowserKeyCombo(key: "a", modifiers: ["shift", "command"])))
    precondition(!BrowserShortcutMap.isReserved(BrowserKeyCombo(key: "f", modifiers: ["command"])))
    var custom = BrowserShortcutMap(bindings: [.tabNumber: BrowserKeyCombo(key:"3",modifiers:["command", "option"])])
    precondition(custom.combos(for:.tabNumber).count == 9)
    for n in 1...9 { precondition(custom.conflicts(with: BrowserKeyCombo(key:String(n),modifiers:["option","command"])) == [.tabNumber]) }
    precondition(custom.validationError(for: BrowserKeyCombo(key:"8",modifiers:["command","option"]),action:.back) == "與『切到第 N 個分頁』相同")
    let single = BrowserShortcutMap(bindings:[.back: BrowserKeyCombo(key:"8",modifiers:["command","option"])])
    precondition(single.validationError(for: BrowserKeyCombo(key:"1",modifiers:["command","option"]),action:.tabNumber) == "與『返回』相同")
    precondition(single.validationError(for: BrowserKeyCombo(key:"w",modifiers:["command"]),action:.closeTab) == "已被 OS 使用")
    precondition(single.validationError(for: BrowserKeyCombo(key:"t",modifiers:[]),action:.newTab) != nil)
    precondition(single.validationError(for: BrowserKeyCombo(key:"t",modifiers:["command"]),action:.tabNumber) != nil)
    precondition(single.validationError(for: BrowserKeyCombo(key:"1",modifiers:["control"]),action:.tabNumber) == nil)
    custom.bindings[.back] = BrowserKeyCombo(key:"[",modifiers:["command"])
    let decoded = try JSONDecoder().decode(BrowserShortcutMap.self, from: JSONEncoder().encode(custom))
    precondition(decoded == custom)
    let missing = try JSONDecoder().decode(BrowserGeneralSettings.self, from: Data("{\"searchEngine\":\"bing\"}".utf8))
    precondition(missing.shortcuts == defaults && missing.searchEngine == .bing)
    let malformed = try JSONDecoder().decode(BrowserGeneralSettings.self, from: Data("{\"shortcuts\":false}".utf8))
    precondition(malformed.shortcuts == defaults)
    let empty = try JSONDecoder().decode(BrowserGeneralSettings.self, from: JSONEncoder().encode(BrowserGeneralSettings()))
    precondition(empty.shortcuts == defaults)
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("settings.json")
    var original = BrowserGeneralSettings(); original.searchEngine = .bing
    try original.save(to:url)
    let stale = BrowserGeneralSettings.load(from:url)
    try BrowserGeneralSettings.saveShortcuts(custom,to:url)
    try stale.save(to:url)
    precondition(BrowserGeneralSettings.load(from:url).shortcuts == custom)
    precondition(BrowserGeneralSettings.load(from:url).searchEngine == .bing)
    try BrowserGeneralSettings.savePasswordAssist(false,to:url)
    precondition(BrowserGeneralSettings.load(from:url).shortcuts == custom)
    try BrowserGeneralSettings.saveShortcuts(BrowserShortcutMap(bindings:[:]),to:url)
    precondition(BrowserGeneralSettings.load(from:url).shortcuts.bindings.isEmpty)
    try Data("broken".utf8).write(to:url)
    do { try BrowserGeneralSettings.saveShortcuts(defaults,to:url); preconditionFailure() } catch {}
    let preserved = try String(contentsOf:url,encoding:.utf8)
    precondition(preserved == "broken")
    precondition(BrowserShortcutMap.legacyCombo("find") == BrowserKeyCombo(key:"f",modifiers:["command"]))
    precondition(BrowserShortcutMap.legacyCombo("zoomIn") == nil) // missing Shift identity must fail closed
    print("W57e fixtures passed")
 }
}
`);
  const compile = spawnSync('swiftc',['-parse-as-library','-swift-version','6','-num-threads','2',b+'BrowserShortcuts.swift',b+'BrowserGeneralSettings.swift',source,'-o',binary],{cwd:root,encoding:'utf8',timeout:90000});
  assert.equal(compile.status,0,compile.stderr);
  const run = spawnSync(binary,[dir],{encoding:'utf8',timeout:15000});
  assert.equal(run.status,0,run.stdout+run.stderr);
});

test('W57e production native recorder handles capture, Esc, Delete and responder isolation', {skip:process.platform!=='darwin',timeout:90000}, () => {
  const dir = mkdtempSync(join(tmpdir(),'w57e-recorder-'));
  const source = join(dir,'Recorder.swift'), binary = join(dir,'recorder');
  const adapter = 'extension BrowserKeyCombo {' + read(b+'BrowserDailyNavigationControls.swift').split('extension BrowserKeyCombo {')[1];
  writeFileSync(source, [read(b+'BrowserShortcuts.swift'),read(b+'BrowserGeneralSettings.swift'),read(b+'BrowserSettingsMetrics.swift'),read(b+'BrowserShortcutsSettingsView.swift'),adapter,String.raw`
@main struct RecorderChecks {
 @MainActor static func main() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.borderless],backing:.buffered,defer:false)
    let capture = BrowserShortcutRecorder.Capture()
    window.contentView = capture
    precondition(window.makeFirstResponder(capture))
    var recorded: [BrowserKeyCombo?] = []
    var cancelled = 0
    capture.record = { recorded.append($0) }; capture.cancel = { cancelled += 1 }
    func event(_ key: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:key)!
    }
    precondition(capture.performKeyEquivalent(with:event(17,"T",[.command,.shift])))
    precondition(recorded.last! == BrowserKeyCombo(key:"t",modifiers:["command","shift"]))
    capture.keyDown(with:event(53,"\u{1b}")); precondition(cancelled == 1 && recorded.count == 1)
    capture.keyDown(with:event(51,"\u{7f}")); precondition(recorded.count == 2 && recorded.last! == nil)
    capture.keyDown(with:event(117,"\u{7f}")); precondition(recorded.count == 3 && recorded.last! == nil)
    capture.keyDown(with:event(48,"\t",[.control])); precondition(recorded.last! == BrowserKeyCombo(key:"tab",modifiers:["control"]))
    capture.keyDown(with:event(49," ",[.option])); precondition(recorded.last! == BrowserKeyCombo(key:"space",modifiers:["option"]))
    _ = window.makeFirstResponder(nil)
    precondition(!capture.performKeyEquivalent(with:event(17,"t",[.command])))
    print("W57e native recorder passed")
 }
}
`].join('\n'));
  const compile = spawnSync('swiftc',['-parse-as-library','-num-threads','2',source,'-o',binary],{cwd:root,encoding:'utf8',timeout:60000});
  assert.equal(compile.status,0,compile.stderr);
  const run = spawnSync(binary,[],{encoding:'utf8',timeout:15000});
  assert.equal(run.status,0,run.stdout+run.stderr);
});
