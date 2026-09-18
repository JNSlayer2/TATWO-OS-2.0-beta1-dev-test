import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = file => fs.readFileSync(path.join(repo, file), 'utf8');
const source = name => read('App/Sources/Tatwo2/' + name);

// 1. 打包清單：技能進 App Resources，references/（私人封存）不進。
test('W96 App 打包公開技能的 SKILL.md 與 agents/，不帶 references/', () => {
  const manifest = read('Package.swift');
  const target = manifest.indexOf('path: "App/Sources/Tatwo2"');
  assert.ok(target > 0, 'Package.swift 找不到 Tatwo2 target');
  const tatwo2 = manifest.slice(target, manifest.indexOf('.executableTarget', target));
  assert.match(tatwo2, /\.copy\("\.\.\/\.\.\/\.\.\/skills\/tatwo-ultrawork\/SKILL\.md"\)/);
  assert.match(tatwo2, /\.copy\("\.\.\/\.\.\/\.\.\/skills\/tatwo-ultrawork\/agents"\)/);
  assert.doesNotMatch(manifest, /skills\/tatwo-ultrawork\/references/,
    'references/ 是私人封存，不得出現在打包清單');
  // 正本仍是 repo 的 skills/；打包指到正本，不另存一份會走樣的複本。
  assert.ok(fs.existsSync(path.join(repo, 'skills/tatwo-ultrawork/SKILL.md')));
  assert.ok(fs.existsSync(path.join(repo, 'skills/tatwo-ultrawork/agents/openai.yaml')));
  assert.ok(!fs.existsSync(path.join(repo, 'App/Sources/Tatwo2/Resources/skills')),
    'Resources 下不要放第二份技能複本');
});

// 公開匯出白名單本來就含這個技能（W75 規則不動，這裡只擋回頭路）。
test('W96 公開匯出仍帶技能本體與 agents', () => {
  const exporter = read('scripts/public-export.sh');
  assert.ok(exporter.includes("'skills/tatwo-ultrawork/SKILL.md'"));
  assert.ok(exporter.includes("'skills/tatwo-ultrawork/agents/'"));
  assert.doesNotMatch(exporter, /skills\/tatwo-ultrawork\/references/);
});

// 2. 種檔機制沿用 OS 上游的受管檔判定，不複製貼上第二套。
//    共用的 ManagedFile 留在 OSUpstreamRefresh.swift：既有的 standalone swiftc 探針
//    （os-upstream-update／plugins-liveness／w29b）只編譯那份檔案清單，不動它們也要能編。
test('W96 受管檔機制是共用的，不是複製一份', () => {
  const managed = source('Facade/ManagedSkills.swift');
  const upstream = source('Facade/OSUpstreamRefresh.swift');
  assert.equal(upstream.split('enum ManagedFile').length - 1, 1, 'ManagedFile 只能有一個定義');
  for (const suffix of ['.installed.sha256', '.update-available.md', '.kept-custom.sha256']) {
    assert.ok(upstream.includes('"\\(stem)' + suffix + '"'), `ManagedFile 要定義 ${suffix} 檔名慣例`);
    assert.ok(!managed.includes(suffix), `ManagedSkills 不該再拼一次 ${suffix}`);
  }
  // OS 上游的既有檔名不因抽共用而改名。
  for (const name of ['os-upstream.installed.sha256', 'os-upstream.update-available.md',
    'os-upstream.kept-custom.sha256']) {
    assert.ok(upstream.includes(name), name);
  }
  assert.ok(!managed.includes('SHA256.hash('), 'ManagedSkills 的雜湊要走 ManagedFile.sha256');
  assert.equal(upstream.split('SHA256.hash(').length - 1, 1, '雜湊只在 ManagedFile 算一次');
  for (const call of ['ManagedFile.writeManaged(', 'ManagedFile.clearNotice(', 'ManagedFile.trimmedText(',
    'ManagedFile.sha256(']) {
    assert.ok(upstream.includes(call), `OSUpstreamRefresh 要複用 ${call}`);
    assert.ok(managed.includes(call), `ManagedSkills 要複用 ${call}`);
  }
  assert.ok(managed.includes('ManagedFile.markerURL('), 'ManagedSkills 走共用的檔名慣例');
  // 種進 PluginsSource 掃描的第一個技能根，而不是另開一個新位置。
  assert.ok(managed.includes('Library/Application Support/tatwo2/skills'));
  assert.ok(source('Facade/PluginsSource.swift').includes('Library/Application Support/tatwo2/skills'));
  // 首次啟動與每次更新都要種：掛在 App 啟動流程上。
  assert.match(source('Shell/AppShell.swift'), /ManagedSkills\.applyOnLaunch\(\)/);
  // 手改一律保留：只有標記與現況相符才自動更新。
  assert.ok(managed.includes('ManagedFile.trimmedText(at: marker) == current'),
    '只有標記相符才自動更新');
});

// 3. 設定 › Plugin 顯示來源。
test('W96 設定 › Plugin 顯示 App 內建（受管）／已手改（保留）', () => {
  const managed = source('Facade/ManagedSkills.swift');
  assert.ok(managed.includes('App 內建（受管）'));
  assert.ok(managed.includes('已手改（保留）'));
  const settings = source('New/PluginSettingsView.swift');
  assert.match(settings, /ManagedSkills\.sourceLabel\(forSkillManifestPath:/);
  assert.match(settings, /publicInstallHint: "來源：" \+ label/);
});

// 4. 乾淨安裝閘門列出新斷言。
test('W96 clean-install-gate 有技能種檔斷言', () => {
  const gate = read('scripts/clean-install-gate.sh');
  assert.ok(gate.includes('Application Support/tatwo2/skills/tatwo-ultrawork/SKILL.md'));
  assert.ok(gate.includes('SKILL.installed.sha256'));
  const dry = execFileSync('bash', [path.join(repo, 'scripts/clean-install-gate.sh'), '--dry-run'],
    { encoding: 'utf8' });
  assert.match(dry, /STEP 6b\/8 W96 技能出貨斷言/);
  assert.match(dry, /DRYRUN OK steps=9/);
});

// 5. 真 App 產物：bundle 帶技能、不帶 references；種檔三態由 App 內 SelfTest 跑。
test('W96 App bundle 帶技能本體與 agents，不帶 references', () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'TATWO2_TEST_BINARY is required; never skip acceptance');
  const resources = path.join(path.dirname(process.env.TATWO2_TEST_BINARY),
    'TatwoUltrawork_Tatwo2.bundle/Contents/Resources');
  assert.ok(fs.existsSync(resources), 'bundle 不存在：' + resources);
  assert.equal(fs.readFileSync(path.join(resources, 'SKILL.md'), 'utf8'),
    read('skills/tatwo-ultrawork/SKILL.md'), 'bundle 內的技能要與 repo 正本一致');
  assert.equal(fs.readFileSync(path.join(resources, 'agents/openai.yaml'), 'utf8'),
    read('skills/tatwo-ultrawork/agents/openai.yaml'));
  assert.ok(!fs.existsSync(path.join(resources, 'references')), 'references/ 不得出貨');
});

test('W96 種檔三態：全新安裝／未手改自動更新／手改保留', { timeout: 300_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'TATWO2_TEST_BINARY is required; never skip acceptance');
  const output = execFileSync(process.env.TATWO2_TEST_BINARY, [], {
    encoding: 'utf8', timeout: 240_000,
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: process.env.HOME,
           TATWO2_W96SKILLSTEST: '1' },
  });
  console.log(output.trim());
  for (const label of ['全新安裝種下 SKILL.md 與 agents', '種下後是 App 內建（受管）', '不種 references',
    '第二次啟動不動檔', '未手改就自動更新', '手改保留並留下提示', '手改後來源是已手改（保留）',
    '設定列來源標籤', '沒有種入前來源是 missing', '沒有內建資源就不動使用者目錄']) {
    assert.ok(output.includes('W96SKILLSTEST PASS ' + label), label);
  }
  assert.doesNotMatch(output, /W96SKILLSTEST FAIL/);
  assert.match(output, /W96SKILLSTEST ALL PASS/);
});
