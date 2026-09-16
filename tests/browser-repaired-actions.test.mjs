import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = path => readFileSync(join(root, path), 'utf8');
const app = 'App/Sources/Tatwo2/Browser/';
const native = source('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');

test('real shortcut model migrates legacy defaults, preserves custom maps and routes standard keys', {skip: process.platform !== 'darwin', timeout: 120000}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'tatwo-repaired-actions-'));
  const main = join(dir, 'Checks.swift');
  writeFileSync(main, String.raw`
import Foundation
@main struct Checks {
 static func main() throws {
    let defaults = BrowserShortcutMap.defaults
    for (key, action): (String, BrowserAction) in [("t", .newTab), ("w", .closeTab),
        ("l", .focusAddressBar), ("f", .findInPage), ("r", .reload), ("p", .printPage),
        ("[", .back), ("]", .forward), ("=", .zoomIn), ("-", .zoomOut), ("0", .zoomReset)] {
        precondition(defaults.invocation(for: .init(key: key, modifiers: ["command"]))?.action == action)
    }
    precondition(defaults.invocation(for: .init(key: "t", modifiers: ["shift", "command"]))?.action == .reopenClosedTab)
    precondition(defaults.invocation(for: .init(key: "p", modifiers: ["shift", "command"]))?.action == .printPDF)
    precondition(defaults.invocation(for: .init(key: "+", modifiers: ["shift", "command"]))?.action == .zoomIn)
    precondition(defaults.invocation(for: .init(key: "tab", modifiers: ["control"]))?.action == .nextTab)
    precondition(defaults.invocation(for: .init(key: "tab", modifiers: ["shift", "control"]))?.action == .previousTab)
    for n in 1...9 {
        let invocation = defaults.invocation(for: .init(key: String(n), modifiers: ["command"]))!
        precondition(invocation.action == .tabNumber && invocation.number == n)
        precondition(BrowserShortcutInvocation(message: invocation.message) == invocation)
    }
    precondition(defaults.invocation(for: .init(key: "f", modifiers: [])) == nil)
    precondition(defaults.invocation(for: .init(key: "q", modifiers: ["command"])) == nil)
    precondition(defaults.validationError(for: .init(key: "l", modifiers: ["command"]), action: .focusAddressBar) == nil)
    precondition(defaults.validationError(for: .init(key: "w", modifiers: ["command"]), action: .closeTab) == nil)
    precondition(defaults.validationError(for: .init(key: "q", modifiers: ["command"]), action: .closeTab) == "已被 OS 使用")
    precondition(defaults.validationError(for: .init(key: "f", modifiers: ["command"]), action: .closeTab) == "與『頁內搜尋』相同")

    // Decode the exact old serialized representation, not a new initializer.
    let legacy = Data(#"{"shortcuts":{"bindings":["newTab",{"key":"t","modifiers":["command"]}]}}"#.utf8)
    let migrated = try JSONDecoder().decode(BrowserGeneralSettings.self, from: legacy)
    precondition(migrated.shortcuts == defaults)
    let customOld = Data(#"{"shortcuts":{"bindings":["findInPage",{"key":"g","modifiers":["command"]}]}}"#.utf8)
    let custom = try JSONDecoder().decode(BrowserGeneralSettings.self, from: customOld).shortcuts
    precondition(custom.bindings.count == 1 && custom.invocation(for: .init(key: "g", modifiers: ["command"]))?.action == .findInPage)
    precondition(custom.invocation(for: .init(key: "f", modifiers: ["command"])) == nil)
    let emptyOld = try JSONDecoder().decode(BrowserGeneralSettings.self, from: Data(#"{"shortcuts":{"bindings":[]}}"#.utf8))
    precondition(emptyOld.shortcuts.bindings.isEmpty)
    let currentOnlyT = BrowserShortcutMap(bindings: [.newTab: .init(key: "t", modifiers: ["command"])])
    let settingsURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("settings.json")
    try BrowserGeneralSettings.saveShortcuts(currentOnlyT, to: settingsURL)
    precondition(BrowserGeneralSettings.load(from: settingsURL).shortcuts == currentOnlyT)
    try BrowserGeneralSettings.saveShortcuts(custom, to: settingsURL)
    precondition(BrowserGeneralSettings.load(from: settingsURL).shortcuts == custom)

    for message in ["binding:newTab:0", "binding:newTab:2", "binding:tabNumber:10", "binding:unknown:1", "menu:openPDF"] {
        precondition(BrowserShortcutInvocation(message: message) == nil)
    }
    for (message, action): (String, BrowserNativeMenuAction) in [("menu:printPage", .printPage), ("menu:printPDF", .printPDF), ("menu:openPDF", .openPDF)] {
        precondition(BrowserNativeMenuAction(rawValue: message) == action)
    }
    let login = BrowserExternalLoginPolicy.websiteOrigin("https://accounts.example.com:8443/callback?code=private#token")!
    precondition(login.absoluteString == "https://accounts.example.com:8443/")
    for raw in ["file:///private/data", "javascript:alert(1)", "about:blank", "https://user:password@example.com/callback", "https:///", "/relative"] {
        precondition(BrowserExternalLoginPolicy.websiteOrigin(raw) == nil)
    }
    precondition(BrowserExternalLoginPolicy.websiteOrigin("http://localhost:8766/login?code=secret")?.absoluteString == "http://localhost:8766/")
    print("shortcut migration, native routes and safe website handoff passed")
 }
}
`);
  const binary = join(dir, 'checks');
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    app + 'BrowserShortcuts.swift', app + 'BrowserGeneralSettings.swift', app + 'BrowserExternalLoginPolicy.swift', main, '-o', binary],
    {cwd: root, encoding: 'utf8', timeout: 90000});
  assert.equal(compile.status, 0, compile.stderr);
  const run = spawnSync(binary, [dir], {encoding: 'utf8', timeout: 10000});
  assert.equal(run.status, 0, run.stdout + run.stderr);
});

test('production native keyboard/menu branches consume only handled human input and dispatch every PDF action', {skip: process.platform !== 'darwin', timeout: 90000}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'tatwo-native-actions-'));
  const start = native.indexOf('    // Synthetic agent input cannot invoke native menus.');
  const end = native.indexOf('\n  }\n  void OnFindResult', start);
  const keyBody = native.slice(start, end);
  assert.ok(start >= 0 && end > start);
  const menuStart = native.indexOf('    if (command >= 26513 && command <= 26515)');
  const menuEnd = native.indexOf('\n#pragma mark - W57d End', menuStart);
  assert.ok(menuStart >= 0 && menuEnd > menuStart);
  writeFileSync(join(dir, 'fixture.mm'), String.raw`
#import <AppKit/AppKit.h>
#include <cassert>
@interface Owner : NSView
@property(nonatomic) BOOL human;
@property(nonatomic) int exits;
@property(nonatomic,copy) BOOL (^onBrowserKeyEquivalent)(NSEvent *);
@property(nonatomic,copy) void (^onDailyShortcut)(NSString *);
- (void)exitContentFullscreen;
@end
@implementation Owner
- (void)exitContentFullscreen { self.exits += 1; }
@end
struct Policy { bool human; };
Policy ActorRequestPolicy(Owner *owner) { return {bool(owner.human)}; }
struct Host { bool fullscreen=false; bool IsFullscreen() { return fullscreen; } };
struct Browser { Host host; int stops=0; Host *GetHost() { return &host; } void StopLoad() { ++stops; } };
constexpr int KEYEVENT_RAWKEYDOWN=0;
constexpr int EVENTFLAG_COMMAND_DOWN=1;
struct Key { int windows_key_code=70; int modifiers=EVENTFLAG_COMMAND_DOWN; int type=KEYEVENT_RAWKEYDOWN; bool focus_on_editable_field=false; };
bool keyDispatchRaw(Owner *owner_, Browser *browser, const Key &event, void *os_event, bool *is_keyboard_shortcut) {
` + keyBody + String.raw`
}
bool keyDispatch(Owner *owner, Browser *browser, const Key &event, NSEvent *native, bool *marked) {
 return keyDispatchRaw(owner, browser, event, (__bridge void *)native, marked);
}
bool menuDispatch(Owner *owner_, int command) {
` + native.slice(menuStart, menuEnd) + String.raw`
 return false;
}
int main() { @autoreleasepool {
 Owner *owner = [[Owner alloc] initWithFrame:NSZeroRect]; owner.human=YES;
 Browser browser; Key key;
 NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil characters:@"f" charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
 __block int calls=0; __block BOOL handled=NO;
 owner.onBrowserKeyEquivalent = ^BOOL(NSEvent *e) { ++calls; return handled; };
 bool marked=false;
 assert(!keyDispatch(owner,&browser,key,event,&marked)); assert(calls==1 && !marked);
 handled=YES; assert(keyDispatch(owner,&browser,key,event,&marked)); assert(marked && calls==2);
 assert(!keyDispatch(owner,&browser,key,nil,&marked)); assert(calls==2);
 owner.human=NO; assert(!keyDispatch(owner,&browser,key,event,&marked)); assert(calls==2);
 owner.human=YES;
 NSEvent *flags = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:55];
 assert(!keyDispatch(owner,&browser,key,flags,&marked)); assert(calls==2);
 NSEvent *mouse = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
 assert(!keyDispatch(owner,&browser,key,mouse,&marked)); assert(calls==2);
 owner.human=YES; key.windows_key_code=27; key.modifiers=0; browser.host.fullscreen=true;
 assert(keyDispatch(owner,&browser,key,event,&marked)); assert(owner.exits==1);
 browser.host.fullscreen=false;
 __block NSString *message=nil; owner.onDailyShortcut=^(NSString *s) { message=s; };
 assert(keyDispatch(owner,&browser,key,event,&marked)); assert([message isEqualToString:@"escape"]);
 // Menu dispatch does not invoke or depend on the keyboard callback.
 owner.onBrowserKeyEquivalent=nil;
 assert(menuDispatch(owner,26513)); assert([message isEqualToString:@"menu:printPage"]);
 assert(menuDispatch(owner,26514)); assert([message isEqualToString:@"menu:printPDF"]);
 assert(menuDispatch(owner,26515)); assert([message isEqualToString:@"menu:openPDF"]);
 assert(!menuDispatch(owner,42));
 owner.human=NO; message=nil; assert(menuDispatch(owner,26515)); assert(message==nil);
 } return 0;
}
`);
  const build = spawnSync('xcrun', ['clang++', '-std=c++20', '-fobjc-arc', '-fblocks', '-framework', 'AppKit',
    join(dir, 'fixture.mm'), '-o', join(dir, 'fixture')], {encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(dir, 'fixture'), [], {encoding: 'utf8', timeout: 10000});
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
