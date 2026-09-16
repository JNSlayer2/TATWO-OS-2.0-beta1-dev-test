import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { testScratch } from './test-scratch.mjs';
import { omniboxVisualTokens } from './browser-visual-fixture.mjs';

export function runOmniboxNativeChecks() {
  assert.equal(process.platform, 'darwin');
  const repo = fileURLToPath(new URL('../../', import.meta.url));
  const evidence = process.env.W67_OMNIBOX_UI_EVIDENCE_DIR ?? testScratch('w67-omnibox-native-');
  mkdirSync(evidence, { recursive: true });
  const run = (command, args) => {
    const result = spawnSync(command, args, { cwd: repo, encoding: 'utf8', timeout: 150_000, maxBuffer: 4 * 1024 * 1024 });
    if (command === path.join(evidence, 'native-checks')) {
      writeFileSync(path.join(evidence, 'native.stdout.log'), result.stdout ?? '');
      writeFileSync(path.join(evidence, 'native.stderr.log'), result.stderr ?? '');
      writeFileSync(path.join(evidence, 'native.status.json'), JSON.stringify({ status: result.status, signal: result.signal }) + '\n');
    }
    assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
    return result.stdout;
  };
  const lock = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquired = run('bash', [lock, 'acquire', '--pid', String(process.pid), '--timeout', '1']);
  const token = acquired.match(/^token=([0-9a-f]+)$/m)?.[1];
  assert.ok(token);
  try {
    const toolbar = readFileSync(path.join(repo, 'App/Sources/Tatwo2/Browser/EmbeddedBrowserToolbar.swift'), 'utf8').split('struct EmbeddedBrowserToolbar: View')[1];
    const source = `import SwiftUI\nimport AppKit\nextension LiquidGlassTokens {\n${omniboxVisualTokens}\n}\n`
      + 'struct EmbeddedBrowserToolbar: View' + toolbar;
    const extracted = path.join(evidence, 'Toolbar.swift');
    writeFileSync(extracted, source);
    const inputs = [
      'App/Sources/Tatwo2/Browser/BrowserOmniboxMetrics.swift',
      'App/Sources/Tatwo2/Browser/BrowserOmniboxInteraction.swift',
      'App/Sources/Tatwo2/Browser/BrowserOmniboxGlass.swift',
      'tests/helpers/omnibox-native-fixture.swift',
    ];
    const binary = path.join(evidence, 'native-checks');
    run('xcrun', ['swiftc', '-j', '2', '-swift-version', '5', '-parse-as-library',
      ...inputs.map(name => path.join(repo, name)), extracted, '-o', binary]);
    const result = run(binary, [evidence]);
    assert.match(result, /W67 NATIVE RESULT checks=\d+ failures=0/);
    writeFileSync(path.join(evidence, 'result.log'), result);
    const sha = value => createHash('sha256').update(value).digest('hex');
    const screenshots = ['light', 'dark'].flatMap(theme => ['collapsed', 'expanded']
      .map(state => `${theme}-700-workspace-${state}.png`));
    writeFileSync(path.join(evidence, 'receipt.json'), JSON.stringify({
      timestamp: new Date().toISOString(), runID: path.basename(evidence),
      sourceHashes: Object.fromEntries([...inputs, 'App/Sources/Tatwo2/Browser/EmbeddedBrowserToolbar.swift',
        'App/Sources/Tatwo2/Visual/LiquidGlassTokens.swift'].map(name => [name, sha(readFileSync(path.join(repo, name)))])),
      screenshots: screenshots.map(name => ({ path: name, sha256: sha(readFileSync(path.join(evidence, name))),
        surface: 'EmbeddedBrowserToolbar', viewport: [700, 400] })),
      scope: 'Production toolbar + material + dismissal monitor; synthetic native page and trailing controls. Not full App/CEF or Codex baseline acceptance.',
      result,
    }, null, 2) + '\n');
    console.log(result);
  } finally {
    run('bash', [lock, 'release', '--pid', String(process.pid), '--token', token]);
  }
}
