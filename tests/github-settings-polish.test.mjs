import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
const card = read('New/UpdateAvailableCard.swift');
const accounts = read('New/GitHubAccountsCard.swift');
const checker = read('Facade/GitHubReleaseUpdateChecker.swift');
const feedback = read('Facade/FeedbackService.swift');

test('update card always shows installed bundle version/build and the available version arrow', () => {
  assert.ok(card.includes('目前版本 v\\(currentVersion)（build \\(currentBuild)）'));
  assert.match(card, /CFBundleShortVersionString/);
  assert.match(card, /CFBundleVersion/);
  assert.ok(card.indexOf('Text("目前版本') < card.indexOf('if let release'));
  assert.ok(card.includes('目前 v\\(currentVersion) → 可更新到'));
  assert.match(card, /release\.tag_name\.hasPrefix\("v"\)/);
  assert.match(card, /if let release = checker\.availableRelease \{/);
});

test('latest is only claimed after a successful comparison; errors remain visible even after later', () => {
  assert.match(checker, /@Published private\(set\) var lastCheckedAt: Date\?/);
  assert.match(checker, /guard !isChecking else \{ return \}[\s\S]*defer \{ lastCheckedAt = Date\(\); isChecking = false \}/);
  assert.match(card, /checker\.status == "目前沒有較新的正式版本", let checkedAt = checker\.lastCheckedAt/);
  assert.ok(card.includes('· 已是最新（上次檢查 \\(Self.checkTime.string(from: checkedAt))）'));
  assert.match(card, /formatter\.dateFormat = "HH:mm"/);
  assert.match(card, /else if !checker\.status\.isEmpty && checker\.status != "有新版" \{\s*Text\(checker\.status\)/);
  assert.ok(card.indexOf('Text(checker.status)') < card.indexOf('!checker.dismissed'));
});

test('repository is selectable fixed text, with no UI writes and compatible defaults reads', () => {
  assert.match(accounts, /Text\(FeedbackSettings\.defaultRepository\)\s*\.textSelection\(\.enabled\)/);
  assert.doesNotMatch(accounts, /@AppStorage|feedbackRepository|格式 owner\/repo|TextField\("owner\/repo"/);
  assert.ok(accounts.includes('問題回報與更新檢查都走這個公開倉庫。'));
  assert.match(feedback, /repositoryKey = "tatwo2\.feedback\.repository"/);
  assert.match(feedback, /defaults\.string\(forKey: repositoryKey\)/);
  assert.match(checker, /defaults\.string\(forKey: "tatwo2\.feedback\.repository"\)/);
});

test('account actions live in one ellipsis menu and preserve default-account switching', () => {
  const menu = accounts.slice(accounts.indexOf('Menu {'), accounts.indexOf('// 資料夾對映'));
  assert.match(menu, /Button\("檢查連線"\) \{ model\.verifyGitHubAccount\(account\.username\) \}/);
  assert.match(menu, /account\.mcpAlwaysOn \? "常駐 MCP（開）" : "常駐 MCP（關）"/);
  assert.match(menu, /model\.toggleGitHubMCPAlwaysOn\(account\.username\)/);
  assert.match(menu, /Button\("移除帳號…", role: \.destructive\) \{ pendingRemoval = account\.username \}/);
  assert.match(menu, /if !account\.isDefault[\s\S]*model\.setDefaultGitHubAccount/);
  assert.match(menu, /Image\(systemName: "ellipsis\.circle"\)/);
  assert.match(menu, /\.accessibilityLabel/);
  assert.doesNotMatch(menu, /model\.removeGitHubAccount/);
  assert.doesNotMatch(accounts, /Toggle\(|Button\("檢查"\)|Button\("設為預設"\)[^\n]*\n\s*\.buttonStyle/);
});

test('account removal requires a cancellable confirmation, not the menu click', () => {
  assert.match(accounts, /@State private var pendingRemoval: String\?/);
  const alert = accounts.slice(accounts.indexOf('.alert('), accounts.indexOf('// 沿用 EngineLoginCard'));
  assert.match(alert, /get: \{ pendingRemoval != nil \}/);
  assert.match(alert, /set: \{ if !\$0 \{ pendingRemoval = nil \} \}/);
  assert.match(alert, /Button\("取消", role: \.cancel\) \{ pendingRemoval = nil \}/);
  assert.match(alert, /Button\("移除", role: \.destructive\)[\s\S]*guard let username = pendingRemoval[\s\S]*model\.removeGitHubAccount\(username\)[\s\S]*pendingRemoval = nil/);
  assert.equal((accounts.match(/model\.removeGitHubAccount\(/g) ?? []).length, 1);
});

test('permissions describe actual scopes instead of claiming ungranted access', () => {
  assert.match(accounts, /Text\(Self\.permissions\(account\.scopes\)\)/);
  assert.match(accounts, /guard !scopes\.isEmpty else \{ return "權限尚未確認" \}/);
  for (const pair of ['"repo": "讀寫 repo"', '"read:org": "讀組織"', '"gist": "gist"', '"workflow": "workflow"']) {
    assert.ok(accounts.includes(pair));
  }
  assert.match(accounts, /scopes\.map \{ labels\[\$0\] \?\? \$0 \}/);
  assert.ok(accounts.includes('讓 AI 在每條對話都能直接用這個帳號查 GitHub'));
  assert.match(accounts, /LiquidGlassTokens\.brandAccent/);
});

test('folder section uses plain language, supports folder drops, and retains removable rows', () => {
  assert.ok(accounts.includes('哪些資料夾用這個帳號'));
  assert.ok(accounts.includes('拖入或輸入資料夾路徑，例如 ~/Projects/example'));
  assert.match(accounts, /Button\("加入"\)[\s\S]*model\.addGitHubFolderMapping/);
  assert.match(accounts, /ForEach\(account\.folderMappings, id: \\\.self\)/);
  assert.match(accounts, /Button\("移除"\) \{ model\.removeGitHubFolderMapping/);
  assert.match(accounts, /\.dropDestination\(for: URL\.self\)/);
  assert.match(accounts, /urls\.count == 1[\s\S]*url\.isFileURL[\s\S]*\.isDirectoryKey/);
  assert.doesNotMatch(accounts, /加入對映|綁定項目|MCP 常駐/);
});

test('footer has the exact two requested secondary-text lines', () => {
  assert.ok(accounts.includes('OS 怎麼選帳號：網址裡有帳號名就用那個；沒有就看資料夾對映；都沒有就用預設帳號。'));
  assert.match(accounts, /Text\("這些都可以在 chat 直接請 AI 幫你設定。"\)\s*\}\s*\.font\(\.footnote\)\s*\.foregroundStyle\(\.secondary\)/);
  assert.doesNotMatch(accounts, /規則：網址帶帳號名|OS 不插手/);
});
