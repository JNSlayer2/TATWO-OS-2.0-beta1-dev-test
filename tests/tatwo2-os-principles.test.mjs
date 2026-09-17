import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { isIP } from 'node:net';
import test from 'node:test';

const read = name => readFileSync(new URL(`../${name}`, import.meta.url), 'utf8');
const resources = 'App/Sources/Tatwo2/Resources';

test('shipped OS templates match the repository documents, not an older constitution', () => {
  // W75: os.md is a public installation template, while docs/os.md is only
  // a pointer to the device entrance. Byte equality would restore a second authority.
  const template = read(`${resources}/os.md`);
  assert.match(template, /^# TATWO OS 憲法（v4 公開安裝範本/m);
  assert.match(template, /公開安裝範本，不是另一份生效正本/);
  assert.match(template, /不用範本覆蓋既有憲法/);
  for (const heading of ['0. 效力', '1. 原則', '2. 設備', '3. 入口',
    '4. 身份組與角色分派', '5. 流程', '6. 記憶', '7. 技能與工具',
    '8. 鐵律', '9. 發行', '10. 記錄', '11. 版本']) {
    assert.ok(template.includes(`## ${heading}`), heading);
  }
  // A public template must not encode a private account, volume, IP or device UUID.
  assert.doesNotMatch(template, /\/Users\/|\/Volumes\/|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i);
  for (const [candidate] of template.matchAll(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g)) {
    // The documented release v2.0.5.001 is not an IP address.
    assert.equal(isIP(candidate), 0, candidate);
  }
  const pointer = read('docs/os.md').trim();
  assert.equal(pointer.split('\n').length, 1);
  assert.match(pointer, /憲法位於每台設備入口 `~\/AI\/TATWO OS\/os\.md`/);
  assert.match(pointer, /由主設備派發；本檔僅為指標/);
  assert.equal(read(`${resources}/os-upstream.md`), read('docs/os-upstream.md'));
});

test('both human and injected rules preserve lightweight, direct execution and safety', () => {
  for (const name of ['os.md', 'os-upstream.md']) {
    const text = read(`${resources}/${name}`);
    for (const term of ['輕量', '使用效率', '直觀', '準確', '穩定', '可拓展',
      '冗餘流程', '厚重程式設計', '死規矩', '不為派工而派工',
      '使用者授權', '隱私', '破壞性操作']) {
      // Markdown emphasis should not affect the human-readable requirement.
      assert.ok(text.replaceAll('的程式設計', '程式設計').includes(term), `${name}: ${term}`);
    }
    assert.doesNotMatch(text, /sub 只做規格寫死|只把規格寫死.*機械工/);
  }
});

test('plan remains discussion-only; execution no longer mandates a dispatch room', () => {
  const upstream = read(`${resources}/os-upstream.md`);
  const plan = upstream.split('\n').find(line => line.startsWith('- `/plan`'));
  const execution = upstream.split('\n').find(line => line.startsWith('- `/plg`'));
  assert.match(plan, /不改任何檔案/);
  assert.match(plan, /等使用者說「開始」/);
  assert.match(execution, /主導直接實作/);
  assert.match(execution, /必要時才/);
  assert.match(execution, /不強制派工/);
});
