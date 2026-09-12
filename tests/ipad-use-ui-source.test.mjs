import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../App/Sources/Tatwo2/New/IPadUseSettingsView.swift', import.meta.url), 'utf8');
const settings = readFileSync(new URL('../App/Sources/Tatwo2/Shell/ChatPageSettings.swift', import.meta.url), 'utf8');
const controller = readFileSync(new URL('../App/Sources/Tatwo2/New/IPadUseController.swift', import.meta.url), 'utf8');

test('stop verification is machine-readable and harmless validation errors preserve consent', () => {
  assert.match(controller, /"deviceStopPending": stopping/);
  assert.match(controller, /"deviceStopUnconfirmed": stopUnconfirmed/);
  assert.match(controller, /private static let port = 8117/);
  assert.match(controller, /TATWO_IPAD_USE_TOKEN/);
  assert.match(controller, /"ipad_invalid_touch", "ipad_invalid_point", "ipad_unknown_operation"/);
  assert.match(controller, /"ipad_foreground_changed"\]\.contains\(error.description\)/);
  assert.doesNotMatch(controller, /SIGKILL/);
  assert.deepEqual(controller.match(/Darwin\.kill\([^\n]+/g), ['Darwin.kill(pid_t(pid), 0) == 0 || errno != ESRCH']);
});

test('read-only screenshot timeout preserves consent without a fixed authorization timeout', () => {
  assert.match(controller, /private static let requestTimeout: Double = 30/);
  assert.match(controller, /private static let resourceTimeout: Double = 45/);
  assert.match(controller, /method == "ipad_screenshot", Self\.isTimeout\(error\)/);
  assert.match(controller, /ipad_screenshot_timeout_retry_safe/);
  assert.doesNotMatch(controller, /expiresAt|scheduleExpiry|expiryTask|refreshAuthorizationExpiry|addingTimeInterval\(300\)/);
  assert.match(controller, /"-test-timeouts-enabled", "NO"/);
  assert.match(controller, /"-collect-test-diagnostics", "never"/);
  assert.match(controller, /guard generation == attempt else \{\s+throw IPadUseError\(description: "ipad_operation_cancelled"\)/);
});

test('chat plus menu connects through existing controller without a settings round trip', () => {
  const chat = readFileSync(new URL('../App/Sources/Tatwo2/Chat/ChatPage+Composer.swift', import.meta.url), 'utf8');
  const adapter = readFileSync(new URL('../App/Sources/Tatwo2/New/IPadChatConnectionView.swift', import.meta.url), 'utf8');
  assert.match(chat, /Label\("連接 iPad…", systemImage: "ipad"\)/);
  assert.match(chat, /IPadChatConnectionView\(/);
  assert.match(adapter, /IPadUseController.shared/);
  assert.match(adapter, /owner == threadID/);
  assert.match(adapter, /shownDevice.id == id, shownOwner == owner/);
  assert.match(adapter, /connectAndAuthorize\(device, threadID: owner\)/);
  assert.doesNotMatch(adapter, /Timer|while |UserDefaults|URLSession|Process\(/);
});

test('iPad USE stays reachable through Plugin > Pocket with the original consent thread', () => {
  const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
  assert.match(settings, /case \.plugin:\s+PluginSettingsView\(model: model\)/);
  assert.doesNotMatch(settings, /case ipadUse/);
  assert.match(read('App/Sources/Tatwo2/New/PluginSettingsView.swift'),
    /pocketThreadID: model\.selectedThreadID/);
  assert.match(read('App/Sources/Tatwo2/Pages/PluginsPage.swift'),
    /PocketSettingsView\(threadID: pocketThreadID\)/);
  const pocket = read('App/Sources/Tatwo2/New/PocketSettingsView.swift');
  assert.match(pocket, /if plugin == \.iPadUse/);
  assert.match(pocket, /Button\("開啟 iPad USE 設定"\)/);
  assert.match(pocket, /IPadUseSettingsView\(threadID: threadID\)/);
});

test('UI delegates control and never embeds private configuration', () => {
  assert.doesNotMatch(source, /URLSession|Process\(|FileManager|UserDefaults|@AppStorage|SecItem|Keychain|https?:\/\/|\/Users\/|\/Volumes\//);
  assert.match(source, /IPadUseController.shared/);
  assert.doesNotMatch(source, /模擬控制中|示範已配對/);
  assert.doesNotMatch(source, /助手/);
});

test('pressure capability does not advertise touch synthesis as Pencil support', () => {
  assert.match(source, /AI → iPad 真實 Pencil 壓感/);
  assert.match(source, /目前 TATWO iPad USE 不支援/);
  assert.doesNotMatch(source, /WebDriverAgent|\bWDA\b|webdriver/i);
  assert.match(source, /手指觸控與模擬 pressure 不等於 Apple Pencil/);
});

test('one-confirmation authorization binds the consent thread', () => {
  assert.match(source, /連接並授權/);
  assert.match(source, /controller\.connectAndAuthorize\(quickDevice, threadID: consentThreadID\)/);
  assert.match(source, /consentThreadID == threadID/);
  assert.doesNotMatch(source, /Toggle\(/);
  assert.match(source, /立即停止/);
  assert.match(source, /confirmationDialog/);
  assert.match(source, /重新授權目前討論串/);
  assert.doesNotMatch(source, /controller\.authorized \|\| controller\.busy/);
  assert.match(controller, /guard connected, !busy else \{ return \}/);
  assert.match(controller, /"authorizationExpired": false/);
});

test('simplified pairing and cloud screenshot disclosure are present', () => {
  assert.match(source, /1 · 連接與信任/);
  assert.match(source, /2 · TATWO iPad use/);
  assert.match(source, /一次完成連接與目前討論串授權/);
  assert.match(source, /使用雲端 AI 時/);
  assert.match(source, /TATWO 不接收帳號密碼/);
});

test('device consent is app-neutral and neither host nor device force-opens Procreate', () => {
  const device = readFileSync(new URL('../Device/iPadUseDevice/TatwoIPadDeviceTests/TatwoIPadDeviceTests.swift', import.meta.url), 'utf8');
  const tools = readFileSync(new URL('../Engines/os-mcp/server.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(source + controller + device, /au\.com\.savageinteractive|Procreate|procreate/);
  assert.match(device, /case \("POST", "\/v1\/app"\)/);
  assert.match(device, /expectedBundleIdentifier/);
  assert.match(device, /ipad_foreground_changed/);
  assert.match(tools, /ipad_open_app/);
  assert.doesNotMatch(device.split('case ("POST", "/v1/session"):')[1].split('case ("POST", "/v1/app"):')[0], /\.activate\(/);
});

test('crash recovery can only stop a locally-owned previous service, never restore consent', () => {
  const recovery = controller.split('private func recoverPreviousSession(')[1].split('static func recoveryOwnerIsActive')[0];
  assert.match(recovery, /recoveryOwnerIsActive\(pid: ownerPID\)/);
  assert.match(recovery, /requestJSON\("POST", path: "v1\/stop"/);
  assert.doesNotMatch(recovery, /authorized = true|v1\/session|v1\/touch/);
  assert.match(controller, /process\?\.isRunning == true \{ process\?\.terminate\(\) \}/);
  assert.match(controller, /\$0\.id == device\.id && \$0\.address == device\.address/);
});
