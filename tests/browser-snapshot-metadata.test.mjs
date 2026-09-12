import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const source = fs.readFileSync(path.join(repo, 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
const safeURL = source.slice(source.indexOf('NSURLComponents *SafeURLComponents('), source.indexOf('NSString *CanonicalHost('));
const snapshotCode = source.slice(source.indexOf('NSString *SnapshotOrigin('), source.indexOf('\nstruct BrowserState;', source.indexOf('NSString *SnapshotOrigin(')));
assert.ok(safeURL.includes('@catch') && snapshotCode.includes('BuildVisibleSnapshotJSON'));
const root = fs.mkdtempSync(path.join(repo, 'output/lightweight-repair/snapshot-metadata.'));
const program = path.join(root, 'snapshot');
fs.writeFileSync(path.join(root, 'snapshot.mm'), `
#import <AppKit/AppKit.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <set>
${safeURL}
${snapshotCode}
int main() { @autoreleasepool {
  NSData *data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
  NSDictionary *input = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSString *error = nil;
  NSString *output = BuildVisibleSnapshotJSON(input, @"https://example.com/form",
      7, NSMakeSize(800, 600), &error);
  if (output == nil) { fprintf(stderr, "%s", error.UTF8String); return 1; }
  printf("%s", output.UTF8String);
  return 0;
} }
`);
// Reuse the global build lock. This small Foundation-only binary does not
// initialize Chromium, load websites, or touch persistent browser profiles.
execFileSync('/bin/bash', ['-c', `
set -euo pipefail
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 120 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -framework AppKit "$1" -o "$2"
`, 'snapshot-test', path.join(root, 'snapshot.mm'), program], { cwd: repo, timeout: 150000, stdio: 'pipe' });

function fixture() {
  const strings = [];
  function string(value) {
    let i = strings.indexOf(value);
    if (i < 0) { i = strings.length; strings.push(value); }
    return i;
  }
  const nodes = { nodeName: [], parentIndex: [], attributes: [], backendNodeId: [] };
  const layout = { nodeIndex: [], bounds: [], styles: [], text: [], paintOrders: [], blendedBackgroundColors: [], textColorOpacities: [] };
  const textBoxes = { layoutIndex: [], bounds: [] };
  const document = { documentURL: string('https://example.com/form'), title: string('Fixture form'), nodes, layout, textBoxes, scrollOffsetX: 0, scrollOffsetY: 0 };
  function add(name, { parent = -1, attrs = {}, text = '', visible = true, backend, lowContrast = false } = {}) {
    const id = nodes.nodeName.length;
    nodes.nodeName.push(string(name));
    nodes.parentIndex.push(parent);
    nodes.attributes.push(Object.entries(attrs).flatMap(([k, v]) => [string(k), string(v)]));
    nodes.backendNodeId.push(backend === undefined ? 100 + id : backend);
    if (visible) {
      const row = layout.nodeIndex.length;
      layout.nodeIndex.push(id);
      layout.bounds.push([10, 10, 200, 40]);
      layout.styles.push(['block', 'visible', 'visible', '1', '16px', lowContrast ? 'rgb(250, 250, 250)' : 'rgb(0, 0, 0)', 'rgb(255, 255, 255)', 'auto', 'none'].map(string));
      layout.text.push(string(text));
      layout.paintOrders.push(1);
      layout.blendedBackgroundColors.push(string('rgb(255, 255, 255)'));
      layout.textColorOpacities.push(1);
      if (text) { textBoxes.layoutIndex.push(row); textBoxes.bounds.push([10, 10, 200, 40]); }
    }
    return id;
  }
  const doc = add('#document', { visible: false });
  const body = add('BODY', { parent: doc });
  const form = add('FORM', { parent: body, attrs: { action: '/submit', method: 'post' } });
  return { add, body, form, input: { strings, documents: [document] } };
}
function read(f) {
  return JSON.parse(execFileSync(program, [], { input: JSON.stringify(f.input), encoding: 'utf8', timeout: 5000 }));
}
function fields(snapshot) { return snapshot.forms.flatMap(form => form.fields); }

test('actual snapshot function identifies unlabelled native and role buttons from visible children', () => {
  const f = fixture();
  const button = f.add('BUTTON', { parent: f.form });
  const span = f.add('SPAN', { parent: button });
  f.add('#text', { parent: span, text: 'Submit order' });
  const role = f.add('DIV', { parent: f.body, attrs: { role: 'button' } });
  f.add('#text', { parent: role, text: 'Sign in' });
  const result = read(f);
  assert.equal(result.title, 'Fixture form');
  assert.deepEqual(result.controls.map(c => c.label), ['Submit order', 'Sign in']);
  assert.equal(fields(result)[0].type, 'submit');
  assert.equal(result.controls[0].elementID, `cef-${100 + button}`);
});
test('label-for and wrapping labels describe fields without exporting their values', () => {
  const f = fixture();
  const label = f.add('LABEL', { parent: f.form, attrs: { for: 'cust' } });
  f.add('#text', { parent: label, text: 'Customer name' });
  f.add('INPUT', { parent: f.form, attrs: { id: 'cust', value: 'SECRET_VALUE' }, text: 'SECRET_VALUE' });
  const wrapper = f.add('LABEL', { parent: f.form });
  f.add('#text', { parent: wrapper, text: 'Comments' });
  const area = f.add('TEXTAREA', { parent: wrapper });
  f.add('#text', { parent: area, text: 'SECRET_TEXTAREA' });
  const result = read(f);
  assert.deepEqual(fields(result).map(x => x.label), ['Customer name', 'Comments']);
  assert.doesNotMatch(JSON.stringify(result), /SECRET_VALUE|SECRET_TEXTAREA/);
});
test('missing, zero, fractional and oversized backend IDs never become actionable node-index selectors', () => {
  const f = fixture();
  for (const backend of [null, 0, -1, 1.5, 2147483648, '200']) f.add('INPUT', { parent: f.form, backend });
  const result = read(f);
  assert.equal(fields(result).length, 0);
  assert.ok(result.riskFlags.includes('elementIdentityUnavailable'));
});
test('hidden and low-contrast label text is not reused as actionable labels', () => {
  const f = fixture();
  const button = f.add('BUTTON', { parent: f.form });
  f.add('#text', { parent: button, text: 'LOW_CONTRAST_LABEL', lowContrast: true });
  const label = f.add('LABEL', { parent: f.form, attrs: { hidden: '', for: 'cust' } });
  f.add('#text', { parent: label, text: 'HIDDEN_LABEL' });
  f.add('INPUT', { parent: f.form, attrs: { id: 'cust' } });
  const result = read(f);
  assert.ok(fields(result).every(x => x.label === ''));
  assert.ok(result.controls.every(x => x.label === ''));
});
test('sensitive associated labels and disabled controls remain explicit', () => {
  const f = fixture();
  const label = f.add('LABEL', { parent: f.form, attrs: { for: 'cc' } });
  f.add('#text', { parent: label, text: 'Credit card number' });
  f.add('INPUT', { parent: f.form, attrs: { id: 'cc' } });
  f.add('BUTTON', { parent: f.form, attrs: { 'aria-label': 'Not ready', disabled: '' } });
  const result = read(f);
  assert.equal(fields(result)[0].sensitive, true);
  assert.equal(result.controls[0].disabled, true);
});
test('links gain visible child labels without forwarding query strings or credentials', () => {
  const f = fixture();
  const a = f.add('A', { parent: f.body, attrs: { href: '/login?private=DO_NOT_EXPORT#fragment' } });
  f.add('#text', { parent: a, text: 'Sign in' });
  const result = read(f);
  assert.equal(result.links[0].label, 'Sign in');
  assert.equal(result.links[0].destinationPath, '/login');
  assert.doesNotMatch(JSON.stringify(result.links), /DO_NOT_EXPORT|fragment/);
});
test('editable subtree text cannot be used as a parent control caption', () => {
  const f = fixture();
  const button = f.add('DIV', { parent: f.body, attrs: { role: 'button' } });
  const editor = f.add('DIV', { parent: button, attrs: { contenteditable: 'true' } });
  f.add('#text', { parent: editor, text: 'SECRET_EDITABLE' });
  const result = read(f);
  assert.doesNotMatch(JSON.stringify(result), /SECRET_EDITABLE/);
});
test('field counts and Unicode labels are bounded without breaking JSON', () => {
  const f = fixture();
  for (let i = 0; i < 530; i++) f.add('INPUT', { parent: f.form, attrs: { 'aria-label': '🐱'.repeat(300) } });
  const result = read(f);
  assert.equal(fields(result).length, 512);
  assert.ok(fields(result).every(x => x.label.length <= 162 && !x.label.includes('\uFFFD')));
  assert.ok(result.riskFlags.includes('truncated'));
});
test('occluded controls are not offered as click targets', () => {
  const f = fixture();
  f.add('BUTTON', { parent: f.form, attrs: { 'aria-label': 'Behind overlay' } });
  f.add('DIV', { parent: f.body });
  const orders = f.input.documents[0].layout.paintOrders;
  orders[orders.length - 1] = 50;
  assert.equal(read(f).controls.length, 0);
});
test('missing paint-order evidence does not invent clickable controls', () => {
  const f = fixture();
  f.add('BUTTON', { parent: f.form, attrs: { 'aria-label': 'Unverified' } });
  f.input.documents[0].layout.paintOrders = [];
  const result = read(f);
  assert.equal(result.controls.length, 0);
  assert.ok(result.riskFlags.includes('occlusionUnverified'));
});

function recolor(f, foreground, background, opacity = 1) {
  const {strings, documents: [doc]} = f.input;
  const intern = value => { let i = strings.indexOf(value); if(i < 0){i=strings.length;strings.push(value);} return i; };
  doc.layout.styles.forEach(styles => { styles[5]=intern(foreground); styles[6]=intern(background); });
  doc.layout.blendedBackgroundColors.fill(intern(background));
  doc.layout.textColorOpacities.fill(opacity);
}
function transparentLabelFixture() {
  const f=fixture(); const label=f.add('LABEL',{parent:f.form});
  f.add('#text',{parent:label,text:'Customer name'}); f.add('INPUT',{parent:label}); return f;
}
test('transparent CSS canvas keeps black labels readable on the actual white document canvas', () => {
  const f=transparentLabelFixture(); recolor(f,'rgb(0, 0, 0)','rgba(0, 0, 0, 0)');
  const result=read(f); assert.equal(fields(result)[0].label,'Customer name');
  assert.equal(result.blocks[0].quarantined,false);
});
test('white text on transparent white canvas stays quarantined, not falsely admitted against transparent black', () => {
  const f=transparentLabelFixture(); recolor(f,'rgb(255, 255, 255)','rgba(0, 0, 0, 0)');
  const result=read(f); assert.equal(fields(result)[0].label,''); assert.equal(result.blocks[0].quarantined,true);
});
test('background alpha and text opacity both affect contrast while opaque dark CSS is retained', () => {
  const f=transparentLabelFixture(); recolor(f,'rgb(0, 0, 0)','rgba(0, 0, 0, 0.5)');
  assert.equal(fields(read(f))[0].label,'Customer name');
  recolor(f,'rgb(0, 0, 0)','rgba(0, 0, 0, 0)',0.01);
  assert.equal(read(f).blocks[0].quarantined,true);
  recolor(f,'rgb(255, 255, 255)','rgb(0, 0, 0)');
  assert.equal(fields(read(f))[0].label,'Customer name');
});
