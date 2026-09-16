import { writeBrowserVisualTokens } from './helpers/browser-visual-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => readFileSync(join(root, p), 'utf8');
const vaultPath = 'App/Sources/Tatwo2/Browser/BrowserPasswordVault.swift';
const viewPath = 'App/Sources/Tatwo2/Browser/BrowserPasswordsSettingsView.swift';

test('W50: secrets are device-only Keychain items, production authentication never falls back', () => {
  const vault = read(vaultPath);
  for (const required of [
    'kSecClassGenericPassword', '"TATWO OS Browser"', 'kSecAttrAccount as String: id.uuidString',
    'kSecAttrAccessibleWhenUnlockedThisDeviceOnly', 'kSecUseDataProtectionKeychain as String] = true',
    'kSecAttrSynchronizable as String: false', '.deviceOwnerAuthentication',
    'KeychainSecretStore(), authenticator: LocalAuthenticator()',
    'Library/Application Support/TATWO OS/Browser/passwords.json',
    'schemaVersion = 1', 'options: .atomic',
  ]) assert.ok(vault.includes(required), required);
  const metadata = vault.slice(vault.indexOf('struct BrowserCredential:'), vault.indexOf('protocol BrowserSecretStore'));
  assert.doesNotMatch(metadata, /var password|let password|passwordHash|secret:/);
  assert.doesNotMatch(vault, /\b(?:print|NSLog|debugPrint|os_log)\s*\(/);
  assert.match(vault, /context\.invalidate\(\)/);
  assert.match(vault, /withTaskCancellationHandler/);
});

test('W50: settings labels, Island confirmation, import notification and privacy lifetimes', () => {
  const view = read(viewPath);
  for (const label of ['密碼', '匯出 CSV', '從其他瀏覽器導入', '顯示', '拷貝', '刪除']) {
    assert.ok(view.includes(label), label);
  }
  assert.match(view, /await IslandNotice\.shared\.confirm/);
  assert.match(view, /guard confirmed, !Task\.isCancelled else \{ return \}/);
  assert.match(view, /tatwo\.browser\.openImport/);
  assert.match(view, /Task\.sleep\(for: \.seconds\(30\)\)/);
  assert.match(view, /\.onDisappear \{ concealAndCancel\(\) \}/);
  assert.match(view, /didResignActiveNotification/);
  assert.match(view, /vault\.revealPassword/);
  assert.match(view, /vault\.copyPassword/);
  assert.match(view, /vault\.exportCSV/);
  assert.match(view, /CSV 會包含未加密的密碼/);
  assert.match(view, /BrowserPasswordCSVFileWriter\.write\(data, to: url\)/);
  assert.match(view, /guard NSApplication\.shared\.isActive else \{ return \}/);
  assert.match(read(vaultPath), /clipboardLifetime: Duration = \.seconds\(60\)/);
  assert.match(read(vaultPath), /pasteboard\.changeCount == changeCount/);
  const settings = read('App/Sources/Tatwo2/Shell/ChatPageSettings.swift');
  assert.match(settings, /BrowserPasswordsSettingsView\(\)/);
});

test('W50: real Swift vault/planners and settings compile; behavioral/security fixture', {
  timeout: 150000, skip: process.platform !== 'darwin' ? 'macOS Security/AppKit fixture' : false,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w50-vault-'));
  try {
    // Use the real metadata declaration without importing the unrelated WebKit/runtime implementation.
    const profile = read('App/Sources/Tatwo2/Browser/EmbeddedBrowserProfile.swift');
    const start = profile.indexOf('struct EmbeddedBrowserPasswordFormMetadata:');
    const end = profile.indexOf('\nenum EmbeddedBrowserPasswordFormMetadataExtractor', start);
    assert.ok(start >= 0 && end > start);
    const metadata = join(dir, 'metadata.swift');
    writeFileSync(metadata, profile.slice(start, end));
    const binary = join(dir, 'fixture');
    const compile = spawnSync('swiftc', [
      '-parse-as-library', '-swift-version', '6', '-num-threads', '2',
      vaultPath, viewPath, 'App/Sources/Tatwo2/Browser/BrowserGeneralSettings.swift', 'App/Sources/Tatwo2/Browser/BrowserShortcuts.swift', metadata,
      'App/Sources/Tatwo2/Custody/TOTP.swift','App/Sources/Tatwo2/Custody/AIICloudImport.swift','App/Sources/Tatwo2/Custody/AIAccountEditView.swift',
      'App/Sources/Tatwo2/Browser/BrowserAIVault.swift', 'App/Sources/Tatwo2/Browser/BrowserAIVaultSettingsView.swift',
      'App/Sources/Tatwo2/Browser/Import/BrowserPasswordCSVImport.swift',
      'App/Sources/Tatwo2/Chat/TatwoPermissionPreset.swift', 'App/Sources/Tatwo2/Chat/TatwoCodexSandboxMode.swift',
      'App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift', 'App/Sources/Tatwo2/Browser/BrowserSettingsComponents.swift', writeBrowserVisualTokens(dir), 'tests/fixtures/browser-ai-vault-dependencies.swift',
      'tests/fixtures/browser-password-vault-checks.swift', '-o', binary,
    ], { cwd: root, encoding: 'utf8', timeout: 120000 });
    assert.equal(compile.status, 0, `${compile.error ?? ''}\n${compile.stdout}\n${compile.stderr}`);
    const run = spawnSync(binary, [dir], { encoding: 'utf8', timeout: 20000 });
    assert.equal(run.status, 0, `${run.error ?? ''}\n${run.stdout}\n${run.stderr}`);
    assert.match(run.stdout, /W50 vault fixture passed: \d+ checks/);
    console.log(run.stdout.trim());
    if (process.env.W50_VAULT_UI_EVIDENCE_DIR) {
      const render = spawnSync(binary, ['--render', process.env.W50_VAULT_UI_EVIDENCE_DIR], {
        encoding: 'utf8', timeout: 20000,
      });
      assert.equal(render.status, 0, render.stdout + render.stderr);
      console.log(render.stdout.trim());
    }
  } finally {
    // Only this fixture's freshly-created scratch directory; no user data or repo artifacts.
    rmSync(dir, { recursive: true, force: true });
  }
});

test('W50-fix: Keychain store falls back to the login keychain on errSecMissingEntitlement and reads both variants', () => {
  const vault = read('App/Sources/Tatwo2/Browser/BrowserPasswordVault.swift');
  assert.match(vault, /static let missingEntitlement: OSStatus = -34018/);
  assert.match(vault, /enum Variant: CaseIterable \{ case dataProtection, login \}/);
  assert.match(vault, /if last != Self\.missingEntitlement \{ break \}/);
  assert.match(vault, /for variant in Variant\.allCases \{\s*var key = query\(id, variant: variant\)/);
});
