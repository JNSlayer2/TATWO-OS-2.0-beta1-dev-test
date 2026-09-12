import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = name => readFileSync(new URL(`../${name}`, import.meta.url), 'utf8');
const resources = 'App/Sources/Tatwo2/Resources';

test('shipped OS templates match the repository documents, not an older constitution', () => {
  for (const name of ['os.md', 'os-upstream.md']) {
    assert.equal(read(`${resources}/${name}`), read(`docs/${name}`), name);
  }
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
