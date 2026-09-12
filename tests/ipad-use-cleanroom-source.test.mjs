import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const deviceRoot = path.join(root, 'Device', 'iPadUseDevice');

function files(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const target = path.join(directory, entry.name);
    return entry.isDirectory() ? files(target) : [target];
  });
}

test('built-in device is TATWO clean-room source using Apple frameworks only', () => {
  const inspected = files(deviceRoot).filter(file => statSync(file).size < 2_000_000);
  const source = inspected.map(file => readFileSync(file, 'utf8')).join('\n');
  assert.doesNotMatch(source, /WebDriverAgent|\bWDA\b|webdriver|appium/i);
  assert.match(source, /ai\.tatwo\.ipaduse\.device/);
  assert.match(source, /TATWO iPad use/);
  assert.match(source, /import XCTest/);
  assert.match(source, /import Network/);
  assert.doesNotMatch(source, /DEVELOPMENT_TEAM:\s*[A-Z0-9]{10}/);
  assert.doesNotMatch(source, /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/i);
});

test('App packaging embeds the clean-room project', () => {
  const build = readFileSync(path.join(root, 'scripts', 'build-app.sh'), 'utf8');
  const install = readFileSync(path.join(root, 'scripts', 'tatwo-install-local-app.sh'), 'utf8');
  assert.match(build, /Device\/iPadUseDevice/);
  assert.match(build, /if \[\[ "\$OUT" != \/\* \]\]/);
  assert.match(install, /Device\/iPadUseDevice/);
});

test('controller discovers signing locally and reuses the exact Xcode certificate', () => {
  const controller = readFileSync(path.join(root, 'App', 'Sources', 'Tatwo2', 'New', 'IPadUseController.swift'), 'utf8');
  assert.match(controller, /Provisioning Profiles/);
  assert.match(controller, /--extract-certificates/);
  assert.match(controller, /DEVELOPMENT_TEAM=\\\(team\)/);
  assert.doesNotMatch(controller, /DeviceSigning\.xcconfig/);
  assert.doesNotMatch(controller, /DEVELOPMENT_TEAM=[A-Z0-9]{10}/);
  assert.doesNotMatch(controller, /id=[0-9A-F]{8}-[0-9A-F-]{20,}/i);
});
