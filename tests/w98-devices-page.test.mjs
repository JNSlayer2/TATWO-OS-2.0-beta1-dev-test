// W98：設備頁整理的靜態斷言（寫法沿用 w91b 的 wiring 測試）。
// 只看原始碼：入口搬去側欄、設備列收納、文案白話，而且信任那幾檔一行都沒動。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';

const app = resolve('App/Sources/Tatwo2');
const source = name => readFileSync(join(app, name), 'utf8');
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
// W98 分支的基準（spec 與施工單都以它為準）。
const base = 'b7dbe873';

const devicesCard = 'New/DevicesCard.swift';
const sidebar = 'Chat/ChatPage+Sidebar.swift';
const legacySections = 'New/RemoteDevicesSidebarSections.swift';
const uiFiles = [devicesCard, sidebar, legacySections];

test('W98 設備頁：「遙控它」換成「遠端設備專案」，只負責把人帶去側欄項目', () => {
  const card = source(devicesCard);
  assert.doesNotMatch(card, /遙控它/);
  assert.match(card, /Button\("遠端設備專案"\)/);
  assert.match(card, /model\.requestSidebarProjectsExpanded\(\)/);
  assert.match(card, /_ = model\.enterRemoteMode\(device\)/);
  // 展開狀態只在畫面裡，不落地。
  assert.match(card, /@State private var expandedDevices: Set<String> = \[\]/);
  assert.doesNotMatch(card, /UserDefaults|AppStorage/);
});

test('W98 側欄「專案」區：每台已配對設備一個「遠端設備（名稱）」項目', () => {
  const view = source(sidebar);
  assert.match(view, /Text\("遠端設備（\\\(device\.name\)）"/);
  assert.match(view, /_ = model\.enterRemoteMode\(device\)/);
  assert.match(view, /ForEach\(model\.devices\) \{ device in\s*\n\s*remoteDeviceProjectRow\(device\)/);
  // 圖示跟資料夾專案區別；離線灰化但仍可點。
  assert.match(view, /RemoteDevicePresentation\.icon\(device\)/);
  assert.match(view, /\.opacity\(isOnline \? 1 : 0\.55\)/);
  assert.match(source(devicesCard), /"macmini" : "desktopcomputer"/);
  // 遙控中的那台高亮。
  assert.match(view, /let isActive = model\.remoteMode\?\.id == device\.id/);
  // 「遠端設備專案」按鈕的訊號在側欄這邊接。
  assert.match(view, /onReceive\(model\.\$sidebarProjectsExpandRequest\)/);
  assert.match(view, /projectsSectionExpanded = true/);
});

test('W98b 項目可展開：chevron 只管收合、子層沿用舊段落的內容，專案區外不再重複列', () => {
  const view = source(sidebar);
  const legacy = source(legacySections);
  // (g) 子層資料仍從 remoteSidebarSections 依 device id 找同一台。
  assert.match(view, /model\.remoteSidebarSections\.first \{ \$0\.deviceID == device\.id \}/);
  assert.match(view, /if isExpanded, let section \{\s*\n\s*RemoteDeviceSectionContent\(model: model, section: section\)/);
  // chevron 只切換展開，不進遠端模式；列本身才進遠端模式。
  const chevron = view.slice(view.indexOf('struct RemoteDeviceProjectRow'), view.indexOf('_ = model.enterRemoteMode(device)',
    view.indexOf('struct RemoteDeviceProjectRow')));
  assert.match(chevron, /isExpanded\.toggle\(\)/);
  assert.ok(!chevron.includes('enterRemoteMode'), 'chevron 分支不該進遠端模式');
  // 預設收合、不持久化。
  assert.match(view, /@State private var isExpanded = false/);
  assert.doesNotMatch(view, /UserDefaults|AppStorage/);
  // (f) 舊段落只剩 fallback：沒有對應設備項目的工作階段才列。
  assert.match(legacy, /ForEach\(unmatchedSections\)/);
  assert.match(legacy, /!model\.devices\.contains \{ \$0\.id == section\.deviceID \}/);
  // 抽出來的子層文字一字不改。
  for (const copy of ['這台還沒有專案', '離線・\\(RemoteDevicesSidebarSections.seen(section.lastSeenAt))',
                      'RemoteThreadRowView(model: model, deviceID: section.deviceID, thread: thread)']) {
    assert.ok(legacy.includes(copy), `子層缺少 ${copy}`);
  }
});

test('W98 設備列照 Computer Use 的收納列：收合只露名稱、狀態、user@host', () => {
  const card = source(devicesCard);
  const computerUse = source('New/ComputerUseSettingsView.swift');
  for (const shape of [
    /rotationEffect\(\.degrees\(.*expanded.*\? 90 : 0\)\)/i,
    /\.font\(\.system\(size: 13, weight: \.semibold\)\)/,
    /\.font\(\.system\(size: 11\.5\)\)/,
    /accessibilityHint\(/,
  ]) {
    assert.match(computerUse, shape);
    assert.match(card, shape);
  }
  // 展開後才出現的東西，全在 isExpanded 之後。
  const expandedBlock = card.slice(card.indexOf('if isExpanded {'), card.indexOf('private func badge('));
  for (const detail of ['device.fingerprintSummary', 'DeviceEndpointsRow(device: device)',
                        '加入 \\(Self.stamp(device.addedAt))', 'Button("移除")', 'Button("遠端設備專案")']) {
    assert.ok(expandedBlock.includes(detail), `展開區缺少 ${detail}`);
  }
  assert.match(card, /badge\(isOnline \? "在線" : "離線"/);
  // 沒有可提供的更新就不顯示徽章。
  assert.match(card, /if !update\.hasSuffix\("無"\)/);
});

test('W98 文案：端點三種路白話、順序說明一行、指紋改隧道／簽章識別', () => {
  const card = source(devicesCard);
  for (const copy of ['區網 IP', '隧道', 'SSH 別名', '停用這條路（可還原）', '加一條連線路徑',
                      '區網＝同一 Wi-Fi 直連', '出門在外走 Cloudflare', '~/.ssh/config 的設定',
                      '依區網→隧道→別名順序嘗試']) {
    assert.ok(card.includes(copy), `缺少文案 ${copy}`);
  }
  for (const stale of ['刪除端點（封存）', '新增端點', '主機金鑰', '客戶端金鑰']) {
    for (const file of uiFiles) {
      assert.ok(!source(file).includes(stale), `${file} 還留著舊文案 ${stale}`);
    }
  }
  const summary = source('Facade/DeviceRegistry.swift');
  const shown = summary.slice(summary.indexOf('var fingerprintSummary: String {'));
  assert.ok(shown.includes('part("隧道識別"') && shown.includes('part("簽章識別"'), '指紋文案沒改成白話');
  assert.ok(!shown.includes('part("主機金鑰"') && !shown.includes('part("客戶端金鑰"'), '指紋還在用舊字');
  assert.ok(shown.includes('重新配對即可補齊'), '缺一把時沒有補齊提示');
});

test('W98 信任那幾檔零改動；DeviceRegistry 只動 fingerprintSummary 的字', () => {
  const frozen = ['Facade/DevicePairingHost.swift', 'Facade/DevicePairingClient.swift',
                  'Facade/DevicePairingCode.swift', 'Facade/DevicePairingStubs.swift',
                  'Facade/RemoteHostLink.swift', 'Facade/DeviceDispatch.swift'];
  for (const file of frozen) {
    const diff = git('diff', '--stat', base, '--', join('App/Sources/Tatwo2', file));
    assert.equal(diff.trim(), '', `${file} 相對 ${base} 有改動：\n${diff}`);
  }
  // DeviceRegistry：把 fingerprintSummary 那段切掉之後，前後必須跟基準一字不差。
  const path = 'App/Sources/Tatwo2/Facade/DeviceRegistry.swift';
  const marker = 'var fingerprintSummary: String {';
  const tail = 'private extension NSLock {';
  const slice = text => {
    const head = text.indexOf(marker);
    const rest = text.indexOf(tail);
    assert.ok(head > 0 && rest > head, 'DeviceRegistry 的結構被動過（找不到 fingerprintSummary／NSLock 段）');
    return [text.slice(0, head), text.slice(rest)];
  };
  const before = slice(git('show', `${base}:${path}`));
  const after = slice(readFileSync(path, 'utf8'));
  assert.equal(after[0], before[0], 'fingerprintSummary 以外的 DeviceRegistry 內容被改到了');
  assert.equal(after[1], before[1], 'fingerprintSummary 之後的 DeviceRegistry 內容被改到了');
  // ChatPageModel 只多了「請側欄展開專案區」這件事，遠端模式邏輯沒動。
  const model = git('diff', '-U0', base, '--', 'App/Sources/Tatwo2/Facade/ChatPageModel.swift')
    .split('\n').filter(line => /^[+-][^+-]/.test(line));
  assert.ok(model.every(line => line.startsWith('+')), `ChatPageModel 有刪改：\n${model.join('\n')}`);
  assert.ok(model.every(line => /sidebarProjectsExpandRequest|requestSidebarProjectsExpanded|W98/.test(line)),
            `ChatPageModel 多了無關的東西：\n${model.join('\n')}`);
});

test('W98 UI 檔不碰私鑰', () => {
  for (const file of uiFiles) {
    const text = source(file);
    for (const secret of [/privateKey/, /id_ed25519/, /-----BEGIN/]) {
      assert.doesNotMatch(text, secret, `${file} 出現 ${secret}`);
    }
  }
});
