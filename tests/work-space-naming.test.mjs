import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
test('display copy distinguishes work space and bot space without renaming routing keys', () => {
  for (const file of ['Space/SpaceSetupPreviewView.swift', 'Bot/BotStudioPage.swift', 'Bot/BotStudioMainSlot.swift']) {
    const strings = read(file).split('\n').filter(l => /Text\(|Label\(|\.help\(|title:|accessibilityLabel|placeholder:/.test(l));
    for (const line of strings) {
      const copy = (line.match(/"(?:\\.|[^"\\])*"/g) ?? []).join(' ').replace(/work space|bot space|Work Space/g, '');
      assert.doesNotMatch(copy, /"[^"\n]*\b[Ss]pace\b/, line);
    }
  }
  assert.doesNotMatch(read('Space/SpaceSetupPreviewView.swift'), /工作介面/);
});
test('settings builder callback does not switch to Bot', () => {
  const callbacks = read('Shell/ChatPageSettings.swift').match(/onOpenBuilder: \{[\s\S]*?\}\)/g);
  assert.ok(callbacks?.length);
  callbacks.forEach(c => assert.doesNotMatch(c, /model.mode\s*=\s*\.bot/));
});
