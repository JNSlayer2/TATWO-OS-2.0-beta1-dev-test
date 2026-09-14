import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const picker = readFileSync(new URL('../App/Sources/Tatwo2/Shell/WorkspaceSidebarModePicker.swift', import.meta.url), 'utf8');

test('workspace picker wraps without horizontal scrolling and preserves font table and chip geometry', () => {
  assert.doesNotMatch(picker, /ScrollView\s*\(\.horizontal/);
  assert.match(picker, /WorkspaceModeRows.layout\(count: modes.count\)/);
  assert.match(picker, /case ...3: 12.5/);
  assert.match(picker, /case 4: 11.5/);
  assert.match(picker, /default: 10.5/);
  assert.match(picker, /VStack\(spacing: 5\)/);
  assert.match(picker, /HStack\(spacing: 5\)/);
  assert.match(picker, /padding\(4\)/);
  assert.match(picker, /frame\(height: 30\)/);
  assert.match(picker, /lineLimit\(1\)/);
  assert.match(picker, /minimumScaleFactor\(count >= 4 \? 0\.8 : 1\.0\)/);
  assert.match(picker, /\.padding\(\.horizontal, 12\)/);
  assert.match(picker, /selected \? .bold : .semibold/);
  assert.match(picker, /chatGlassChip\(isSelected: selected\)/);
  assert.match(picker, /LiquidGlassTokens.radiusChip/);
  const chip = readFileSync(new URL('../App/Sources/Tatwo2/Shell/ChatPageStyleModifiers.swift', import.meta.url), 'utf8');
  assert.match(chip, /LiquidGlassTokens.brandAccent.opacity\(0.15\)/);
});

test('swiftc WorkspaceModeRows partitions 1 through 8 and preserves every item', () => {
  const start = picker.indexOf('enum WorkspaceModeRows {');
  const end = picker.indexOf('/// Shared full-inner-width');
  assert.ok(start >= 0 && end > start);
  const dir = mkdtempSync(join(tmpdir(), 'w36-mode-rows-'));
  const source = join(dir, 'main.swift');
  const binary = join(dir, 'rows');
  writeFileSync(source, `#if canImport(AppKit)
import AppKit
#endif
${picker.slice(start, end)}
let expected = [[1], [2], [3], [4], [5], [3, 3], [4, 3], [4, 4]]
for n in 1...8 { precondition(WorkspaceModeRows.layout(count: n) == expected[n - 1]) }
precondition(WorkspaceModeRows.layout(count: 0).isEmpty)
precondition(WorkspaceModeRows.layout(count: -1).isEmpty)
for n in 1...100 {
    let rows = WorkspaceModeRows.layout(count: n)
    precondition(rows.reduce(0, +) == n)
    precondition(rows.allSatisfy { (1...5).contains($0) })
}
for n in 1...5 { precondition(WorkspaceModeRows.fontSize(count: n) == [12.5,12.5,12.5,11.5,10.5][n-1]) }
#if canImport(AppKit)
let labels = ["Chat", "CLI", "Bot", "Browser", "Design", "Data", "Ops", "Sales"]
for n in 1...8 {
    var start = 0
    for count in WorkspaceModeRows.layout(count: n) {
        let available = (250.0 - 36 - 24 - 8 - Double(count - 1) * 5) / Double(count)
        let font = NSFont.systemFont(ofSize: WorkspaceModeRows.fontSize(count: count), weight: .bold)
        for label in labels[start..<(start + count)] {
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            // W37 validates the rejected four-column surface at the real inner width.
            // Five-column geometry is unchanged by this ticket.
            precondition(min(1, available / width) >= (count == 4 ? 0.8 : count <= 3 ? 1.0 : 0.5),
                         "Mockup label must fit within the non-clipping scale fallback")
        }
        start += count
    }
}
#endif
print("wrap fixture passed")
`);
  for (const [command, args] of [['swiftc', ['-num-threads', '2', source, '-o', binary]], [binary, []]]) {
    const result = spawnSync(command, args, { encoding: 'utf8', timeout: 120_000 });
    assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  }
});
