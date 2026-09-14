import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL('../App/Sources/Tatwo2/' + p, import.meta.url), 'utf8');
test('+add is local; shared rows support toggle, reorder, rename and explicit builder', () => {
 const view = read('Space/SpaceSetupPreviewView.swift');
 const add = view.match(/Button\("\+add"\) \{([\s\S]*?)\}/)?.[1];
 assert.match(add ?? '', /domain.addWorkSpace\(\)/);
 assert.doesNotMatch(add, /openBuilder|onOpenBuilder/);
 for (const token of ['domain.toggle(tab)', 'domain.moveTab(tab', 'domain.renameWorkSpace', 'TextField(', 'owner.tabs.first', 'Button("開搭建對話")']) assert.ok(view.includes(token), token);
 assert.match(view, /\.onSubmit\(commit\)/);
 assert.match(view, /\.onChange\(of: focused\)/);
 const controller = read('Space/SpaceWorkspaceController.swift');
 const builder = controller.slice(controller.indexOf('    func openBuilder()'), controller.indexOf('    func openInterface('));
 assert.match(builder, /domain\.openBuilder\(\)/);
 assert.match(builder, /domain\.presentsBuilder = true/);
 assert.doesNotMatch(builder, /mode\s*=/);
 assert.match(read('Chat/ChatPage.swift'), /\.modifier\(SpaceBuilderPresentation\(\)\)/);

});
test('visibleModes keeps custom IDs and gates Browser only', () => {
 const controller = read('Space/SpaceWorkspaceController.swift');
 assert.match(controller, /TATWO_BROWSER_WORKSPACE_PREVIEW/);
 assert.match(controller, /customTabs/);
 assert.doesNotMatch(controller, /rawValue\.lowercased\(\)/);
 assert.match(read('Chat/ChatPageConstants.swift'), /case custom\(String\)/);
});

import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
test('production Swift fixture migrates legacy three tabs and verifies custom lifecycle with Browser off/on', { timeout: 120000, skip: process.platform !== 'darwin' }, () => {
 const scratch = mkdtempSync(join(tmpdir(), 'w33-fixture-'));
 const controller = read('Space/SpaceWorkspaceController.swift');
 const projection = controller.slice(controller.indexOf('    var visibleModes:'), controller.indexOf('    func load(model:'));
 const constants = read('Chat/ChatPageConstants.swift');
 const mode = constants.slice(constants.indexOf('enum ChatRunMode:'), constants.indexOf('enum ChatCollaborationLevel:'));
 const fixture = readFileSync(new URL('fixtures/work-space-checks.swift', import.meta.url), 'utf8').replace('// INSERT projection', projection);
 const source = [read('Space/SpaceWorkspaceDocument.swift'), read('Space/SpaceSetupPreviewState.swift'), mode, fixture].join('\n');
 writeFileSync(join(scratch, 'fixture.swift'), source);
 const build = spawnSync('swiftc', ['-parse-as-library', join(scratch, 'fixture.swift'), '-o', join(scratch, 'fixture')], {encoding:'utf8', timeout: 90000});
 assert.equal(build.status, 0, build.stderr);
 for (const [enabled, preview] of [[undefined, undefined], ['1', undefined], ['0', undefined], [undefined, '1'], ['1', '1']]) {
   const env = {...process.env};
   delete env.TATWO_BROWSER_WORKSPACE_PREVIEW;
   delete env.TATWO_SPACE_SETUP_UI_PREVIEW;
   if (preview !== undefined) env.TATWO_SPACE_SETUP_UI_PREVIEW = preview;
   if (enabled !== undefined) env.TATWO_BROWSER_WORKSPACE_PREVIEW = enabled;
   const run = spawnSync(join(scratch, 'fixture'), [fileURLToPath(new URL('fixtures/work-space-legacy.json', import.meta.url))], {env, encoding:'utf8', timeout:10000});
   assert.equal(run.status, 0, run.stderr);
   process.stdout.write(run.stdout);
 }
});
