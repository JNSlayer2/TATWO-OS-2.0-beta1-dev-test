import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const appSource = path.join(repo, 'App/Sources/Tatwo2');
let fixture;
function buildFixture() {
  if (fixture) return fixture;
  const root = testScratch('packaged-resources-');
  const app = path.join(root, 'Relocated OS.app');
  const contents = path.join(app, 'Contents');
  fs.mkdirSync(path.join(contents, 'MacOS'), { recursive: true });
  fs.mkdirSync(path.join(contents, 'Resources'), { recursive: true });
  fs.writeFileSync(path.join(contents, 'Info.plist'), `<?xml version="1.0"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIdentifier</key><string>test.tatwo.resources</string>
<key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  const source = fs.readFileSync(path.join(appSource, 'Shell/TatwoM3PrototypeViews.swift'), 'utf8');
  const loader = source.slice(source.indexOf('enum ProviderSVGIconLoader {'), source.indexOf('\nstruct QuotaProviderDetail:'));
  // SwiftPM's generated accessor searches app root, then the original build
  // machine's absolute path. This path is deliberately absent, as on a tester's Mac.
  const legacy = `extension Bundle {
    static let module: Bundle = {
      let mainPath = Bundle.main.bundleURL.appendingPathComponent("TatwoUltrawork_Tatwo2.bundle").path
      let buildPath = ${JSON.stringify(path.join(root, 'absent-build/TatwoUltrawork_Tatwo2.bundle'))}
      guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else {
        fatalError("could not load resource bundle")
      }
      return bundle
    }()
  }`;
  const main = path.join(root, 'main.swift');
  fs.writeFileSync(main, `import AppKit\n${legacy}\n${loader}
let expected = CommandLine.arguments[1] == "present"
for id in ["codex-gpt", "claude", "grok"] {
  guard (ProviderSVGIconLoader.image(for: id) != nil) == expected else { exit(2) }
}
print("RESOURCE PROBE PASS")
`);
  const resolver = path.join(appSource, 'Facade/TatwoResources.swift');
  const binary = path.join(contents, 'MacOS/probe');
  execFileSync('swiftc', ['-swift-version', '5', ...(fs.existsSync(resolver) ? [resolver] : []),
    main, '-o', binary], { timeout: 120_000, encoding: 'utf8' });
  fixture = { root, contents, binary };
  return fixture;
}

test('relocated packaged model-login icons load without the developer build tree', { skip: process.platform !== 'darwin' }, () => {
  const { contents, binary } = buildFixture();
  const bundle = path.join(contents, 'Resources/TatwoUltrawork_Tatwo2.bundle');
  fs.cpSync(path.join(appSource, 'Resources/ProviderIcons'), bundle, { recursive: true });
  const result = spawnSync(binary, ['present'], { encoding: 'utf8', timeout: 15_000 });
  assert.equal(result.status, 0, `signal=${result.signal}\n${result.stderr}`);
  assert.match(result.stdout, /RESOURCE PROBE PASS/);
});

test('missing resource bundle shows provider initials instead of terminating the app', { skip: process.platform !== 'darwin' }, () => {
  const { root, contents, binary } = buildFixture();
  const bundle = path.join(contents, 'Resources/TatwoUltrawork_Tatwo2.bundle');
  if (fs.existsSync(bundle)) fs.renameSync(bundle, path.join(root, 'saved.bundle'));
  const result = spawnSync(binary, ['missing'], { encoding: 'utf8', timeout: 15_000 });
  assert.equal(result.status, 0, `signal=${result.signal}\n${result.stderr}`);
  assert.match(result.stdout, /RESOURCE PROBE PASS/);
});

test('all shipped App resource readers avoid SwiftPM fatal build-path fallback', () => {
  for (const relative of fs.readdirSync(appSource, { recursive: true })) {
    if (!relative.endsWith('.swift')) continue;
    assert.doesNotMatch(fs.readFileSync(path.join(appSource, relative), 'utf8'), /Bundle\.module\b/, relative);
  }
});
