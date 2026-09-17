import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = file => readFileSync(join(repo, file), 'utf8');
const resource = 'App/Sources/Tatwo2/Resources/os.md';
const template = read(resource);
const archive = 'archive/governance-legacy-20260917/';

test('W75 public v4 template preserves §0–§11 and does not transfer private authorization', () => {
  assert.match(template, /^# TATWO OS 憲法（v4 公開安裝範本/);
  assert.deepEqual([...template.matchAll(/^## (\d+)\. /gm)].map(match => Number(match[1])),
    Array.from({ length: 12 }, (_, index) => index));
  assert.ok(template.includes('~/AI/TATWO OS/os.md'));
  assert.match(template, /不是另一份生效正本/);
  assert.match(template, /特定設備或開發批次的授權不隨公開範本移轉/);
  assert.doesNotMatch(template, /\/Volumes\/|\/Users\/|\bmini\b|\bMacBook\b|rooms\/logs\/|w70-w83-authorization/i);
  assert.match(template, /主設備\/|主設備／副設備/);
  const skill = read('skills/tatwo-ultrawork/SKILL.md');
  assert.ok(skill.includes('上游規矩是入口憲法 `~/AI/TATWO OS/os.md`'));
  assert.ok(skill.includes('本技能 §2 表必須與它一致'));
});

test('W75 public root retains the release train and both summaries defer to the entrance', () => {
  const root = read('os.md');
  assert.match(root, /由主設備派發；安裝時由 App 內建範本建立/);
  for (const term of ['vX.Y.Z.NNN', 'NNN 從 001 遞增']) assert.ok(root.includes(term));
  assert.match(root, /同 commit 重打包/);
  assert.match(root, /pre-release/);
  assert.match(root, /下一列車從 `X.Y.\(Z\+1\).001`/);
  const summary = read('docs/os-upstream.md');
  assert.equal(summary, read('App/Sources/Tatwo2/Resources/os-upstream.md'));
  assert.match(summary, /^本檔為依入口憲法產生的引擎摘要（W79 起由 App 產生）；衝突時以憲法為準。/);
  assert.match(summary, /跟你自家的預設指令衝突時，以入口憲法為準/);
});

test('W75 archives are byte-preserving moves and the active readers have migrated', () => {
  const originals = {
    'docs/os1-root/README-TATWO-OS導覽.md': '0ede687582304ac61487a6a2a92f65422c0e47c184ac85b70e6f2941ed1d8e94',
    'docs/os1-root/TODO.md': '25858e4f857cbb990e674493bebdc6097c1bf7723d28df52869b26e08e82bd3c',
    'docs/os1-root/issue.md': 'e63ea0af78654284d964fe9d191b53845dd31f511aad2bc191366fbad8191b4b',
    'docs/os1-root/os.md': 'acfa9ab57c8a0978207aa5304c5652a8f78cbdb2376f2965e265cc249c90e2c8',
    'docs/os1-root/skillet.md': 'ba6993ede2014278a77a1f291feeccc63e68f54737df3b4358c14401603249c6',
    'docs/tatwo/WORK_OS.md': '35a056f14dbd6a1752b92c31aaf4d34bc7209d1e7b34ab06612d963799ca832b',
    'docs/tatwo/SKILLET_AND_HOT_SYNC.md': 'b6dc0801c026879409ebfa28458ba48888e226db344f97da75ec4565f35149b1',
    'App/Sources/Tatwo2/Resources/os-architecture-standard.md': '4a0fd5f41c498a7ddb488f8c6be4ad79c5a37b8ea4fa6be66d7994566ef4b16d',
  };
  for (const [file, sha] of Object.entries(originals)) {
    assert.equal(existsSync(join(repo, file)), false, file);
    assert.equal(createHash('sha256').update(readFileSync(join(repo, archive, file))).digest('hex'), sha, file);
  }
  assert.doesNotMatch(read('scripts/tatwo-agent-authority-doctor.sh'), /repo\/docs\/tatwo\/WORK_OS\.md/);
  assert.ok(read('scripts/tatwo-skillet-live-audit.mjs').includes(archive + 'docs/tatwo/SKILLET_AND_HOT_SYNC.md'));
  const target = read('Package.swift').split('path: "App/Sources/Tatwo2",')[1].split('.executableTarget(')[0];
  assert.doesNotMatch(target, /os-architecture-standard/);
  assert.match(target, /\.copy\("Resources\/os\.md"\)/);
});

test('W75 production Swift loader projects v4 and rejects legacy, malformed or incomplete documents',
  { skip: process.platform !== 'darwin', timeout: 180_000 }, () => {
    const root = testScratch('w75-loader-');
    // Compile the unchanged production model/loader prefix; the remaining file is SwiftUI cards.
    const production = read('App/Sources/Tatwo2/Pages/UltraPageManifest.swift')
      .split('\nstruct UltraArchitectureManifestSourceCard: View')[0];
    writeFileSync(join(root, 'Loader.swift'), production);
    writeFileSync(join(root, 'Probe.swift'), String.raw`
import Foundation
extension Bundle { static var module: Bundle { .main } }
@main struct W75Probe {
    static func main() throws {
        let input = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let state = UltraArchitectureManifestLoader.projectConstitution(input)
        let result: [String: Any] = [
            "loaded": state.manifest != nil,
            "ids": state.manifest?.sections.map(\.id) ?? [],
            "sha256": state.manifest?.sourceSHA256 ?? "",
            "raw": state.text ?? "",
            "resource": UltraArchitectureManifestLoader.resourceName
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
    }
}
`);
    const binary = join(root, 'probe');
    execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
      join(root, 'Loader.swift'), join(root, 'Probe.swift'), '-o', binary],
    { encoding: 'utf8', timeout: 120_000 });
    const probe = text => {
      const input = join(root, 'input.md');
      writeFileSync(input, text);
      return JSON.parse(execFileSync(binary, [input], { encoding: 'utf8', timeout: 10_000 }));
    };
    const valid = probe(template);
    assert.equal(valid.loaded, true);
    assert.equal(valid.resource, 'os');
    assert.deepEqual(valid.ids, Array.from({ length: 12 }, (_, index) => String(index)));
    assert.equal(valid.raw, template);
    assert.equal(valid.sha256, createHash('sha256').update(template).digest('hex'));
    for (const invalid of [
      '', '{}', template.replace('（v4', '（v3'), template.replace('## 5. ', '## 4. '),
      template.slice(0, template.indexOf('## 11. ')), template + '\n## 12. Extra\nbody\n',
      template.replace('## 5. ', '## broken '),
    ]) assert.equal(probe(invalid).loaded, false);
  });
