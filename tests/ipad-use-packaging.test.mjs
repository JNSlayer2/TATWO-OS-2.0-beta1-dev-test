import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('..', import.meta.url));
const source = path.join(root, 'Device/iPadUseDevice');
const script = path.join(root, 'scripts/stage-ipad-use-device.sh');
const required = [
  'project.yml',
  'TatwoIPadDeviceTests/Info.plist',
  'TatwoIPadDeviceTests/TatwoIPadDeviceTests.swift',
  'TatwoIPadDevice.xcodeproj/project.pbxproj',
  'TatwoIPadDevice.xcodeproj/project.xcworkspace/contents.xcworkspacedata',
  'TatwoIPadDevice.xcodeproj/xcshareddata/xcschemes/TatwoIPadDevice.xcscheme',
];
const output = path.join(root, 'output/lightweight-repair');
mkdirSync(output, { recursive: true });
// Retain these small, source-only fixtures; no user artifacts are deleted.
const run = mkdtempSync(path.join(output, 'ipad-packaging-'));
function fixture(name, omitted) {
  const directory = path.join(run, name);
  mkdirSync(directory);
  for (const file of required.filter(file => file !== omitted)) {
    mkdirSync(path.dirname(path.join(directory, file)), { recursive: true });
    copyFileSync(path.join(source, file), path.join(directory, file));
  }
  return directory;
}
function stage(input, destination) {
  return spawnSync('/bin/bash', [script, input, destination], { encoding: 'utf8' });
}
function files(directory, prefix = '') {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const relative = path.join(prefix, entry.name);
    return entry.isDirectory() ? files(path.join(directory, entry.name), relative) : [relative];
  }).sort();
}

test('both packaging entrypoints invoke the same explicit source staging', () => {
  for (const entry of ['build-app.sh', 'tatwo-install-local-app.sh']) {
    const text = readFileSync(path.join(root, 'scripts', entry), 'utf8');
    assert.match(text, /bash "[^"\n]*\/scripts\/stage-ipad-use-device\.sh"/);
    assert.doesNotMatch(text, /cp -R [^\n]*Device\/iPadUseDevice/);
    execFileSync('/bin/bash', ['-n', path.join(root, 'scripts', entry)]);
  }
  execFileSync('/bin/bash', ['-n', script]);
});

test('staging preserves all six required inputs and excludes local or unknown files', () => {
  const input = fixture('complete');
  for (const relative of ['signing.mobileprovision', 'DerivedData/result.xcresult/data',
    'TatwoIPadDevice.xcodeproj/xcuserdata/local.xcuserstate',
    'TatwoIPadDeviceTests/DeviceSigning.xcconfig', 'future-unknown.txt']) {
    mkdirSync(path.dirname(path.join(input, relative)), { recursive: true });
    writeFileSync(path.join(input, relative), 'synthetic excluded fixture');
  }
  const destination = path.join(run, 'complete-output');
  const result = stage(input, destination);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(files(destination), [...required].sort());
  for (const file of required) {
    assert.deepEqual(readFileSync(path.join(destination, file)), readFileSync(path.join(source, file)));
  }
});

test('installer stages device files from its frozen source workspace, not the live checkout', () => {
  const workspace = path.join(run, 'frozen-workspace');
  mkdirSync(path.join(workspace, 'Device'), { recursive: true });
  fixture('frozen-workspace/Device/iPadUseDevice');
  mkdirSync(path.join(workspace, 'scripts'));
  copyFileSync(script, path.join(workspace, 'scripts/stage-ipad-use-device.sh'));
  const bin = path.join(run, 'fake-build');
  mkdirSync(path.join(bin, 'Fixture.bundle'), { recursive: true });
  writeFileSync(path.join(bin, 'Fixture.bundle/fixture'), 'compiled resource fixture');
  const app = path.join(run, 'fake-app');
  mkdirSync(path.join(app, 'Contents/Resources'), { recursive: true });
  const installer = readFileSync(path.join(root, 'scripts/tatwo-install-local-app.sh'), 'utf8');
  const functionSource = installer.match(/^stage_resources\(\) \{[\s\S]*?^\}/m)?.[0];
  assert.ok(functionSource);
  const result = spawnSync('/bin/bash', ['-c',
    `set -euo pipefail\nsay() { :; }\nfail() { echo "$*" >&2; }\n${functionSource}\nstage_resources`],
  { encoding: 'utf8', env: { ...process.env, ROOT_DIR: path.join(run, 'unavailable-live-checkout'),
    SOURCE_WORKSPACE: workspace, STAGED_BUNDLE: app, BUILD_BIN_PATH: bin, RESOURCE_BUNDLE_GLOB: '*.bundle' } });
  assert.equal(result.status, 0, result.stderr);
  const staged = path.join(app, 'Contents/Resources/iPadUseDevice');
  assert.deepEqual(files(staged), [...required].sort());
  for (const file of required) {
    assert.deepEqual(readFileSync(path.join(staged, file)), readFileSync(path.join(source, file)));
  }
});

for (const [index, missing] of required.entries()) {
  test(`missing required input rejects before staging: ${missing}`, () => {
    const input = fixture(`missing-${index}`, missing);
    const destination = path.join(run, `missing-output-${index}`);
    assert.notEqual(stage(input, destination).status, 0);
    assert.equal(existsSync(destination), false);
  });
}

test('a source symlink cannot pull an external file into the package', () => {
  const input = fixture('symlink', required[0]);
  symlinkSync(path.join(source, required[0]), path.join(input, required[0]));
  const destination = path.join(run, 'symlink-output');
  assert.notEqual(stage(input, destination).status, 0);
  assert.equal(existsSync(destination), false);
});

test('an existing destination is preserved, never merged with stale contents', () => {
  const destination = path.join(run, 'existing');
  mkdirSync(destination);
  writeFileSync(path.join(destination, 'sentinel'), 'keep');
  assert.notEqual(stage(source, destination).status, 0);
  assert.deepEqual(files(destination), ['sentinel']);
  assert.equal(readFileSync(path.join(destination, 'sentinel'), 'utf8'), 'keep');
});

test('a symlinked source subdirectory is rejected before any output', () => {
  const input = path.join(run, 'symlink-directory');
  mkdirSync(input);
  symlinkSync(path.join(source, 'TatwoIPadDeviceTests'), path.join(input, 'TatwoIPadDeviceTests'));
  for (const file of required.filter(file => !file.startsWith('TatwoIPadDeviceTests/'))) {
    mkdirSync(path.dirname(path.join(input, file)), { recursive: true });
    copyFileSync(path.join(source, file), path.join(input, file));
  }
  const destination = path.join(run, 'symlink-directory-output');
  assert.notEqual(stage(input, destination).status, 0);
  assert.equal(existsSync(destination), false);
});

test('an empty required source is rejected before any output', () => {
  const input = fixture('empty-file');
  writeFileSync(path.join(input, required[3]), '');
  const destination = path.join(run, 'empty-file-output');
  assert.notEqual(stage(input, destination).status, 0);
  assert.equal(existsSync(destination), false);
});

test('Git includes required project sources while retaining project-private exclusions', () => {
  for (const relative of required) {
    const result = spawnSync('git', ['check-ignore', '--no-index', '-q',
      `Device/iPadUseDevice/${relative}`], { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 1, `${relative}: ${result.stderr}`);
  }
  for (const relative of ['private.mobileprovision', 'xcuserdata/person.xcuserstate',
    'project.xcworkspace/xcuserdata/person.xcuserstate',
    'xcshareddata/xcschemes/private.xcscheme']) {
    const result = spawnSync('git', ['check-ignore', '--no-index', '-q',
      `Device/iPadUseDevice/TatwoIPadDevice.xcodeproj/${relative}`], { cwd: root });
    assert.equal(result.status, 0, relative);
  }
});

test('checked-in project parses and targets iPad in both build configurations', () => {
  const projectPath = path.join(source, required[3]);
  const project = JSON.parse(execFileSync('/usr/bin/plutil',
    ['-convert', 'json', '-o', '-', projectPath], { encoding: 'utf8' }));
  const configurations = Object.values(project.objects).filter(value => value.isa === 'XCBuildConfiguration');
  assert.equal(configurations.length, 4);
  for (const configuration of configurations) {
    assert.equal(String(configuration.buildSettings.TARGETED_DEVICE_FAMILY), '2');
  }
  assert.match(readFileSync(path.join(source, 'project.yml'), 'utf8'),
    /DEVELOPMENT_TEAM: ""\s+TARGETED_DEVICE_FAMILY: "2"/);
});

console.log(`IPAD_PACKAGING_FIXTURES ${run}`);
