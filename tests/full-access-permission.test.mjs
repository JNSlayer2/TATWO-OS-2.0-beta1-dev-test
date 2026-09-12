import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
test('actual permission presets honor full access and explicit narrower scopes', {
  skip: process.platform !== 'darwin', timeout: 60000,
}, () => {
  const root = path.resolve(process.env.TATWO_BROWSER_RESOURCE_EVIDENCE ?? os.tmpdir());
  fs.mkdirSync(root, { recursive: true });
  const run = fs.mkdtempSync(path.join(root, 'permission-test-'));
  const source = ['TatwoCodexSandboxMode.swift', 'TatwoPermissionPreset.swift']
    .map(name => fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Chat', name), 'utf8')).join('\n');
  const body = `
var checks = 0
func check(_ ok: Bool, _ name: String) {
  checks += 1; print("\\(ok ? "PASS" : "FAIL") \\(name)"); if !ok { exit(1) }
}
typealias P = TatwoPermissionPreset
check(P.fullAccess.automaticallyApprovesTools, "full access does not ask again")
check(P.approveForMe.automaticallyApprovesTools, "approve for me preserved")
check(!P.askFirst.automaticallyApprovesTools, "ask first still asks")
check(!P.configFile.automaticallyApprovesTools, "config does not imply approval")
check(P.resolvedSidecarMode(user:.fullAccess,bot:nil,readOnly:false,legacyCodexAutoApprove:false) == "bypassPermissions", "ordinary full access reaches engine")
check(P.resolvedSidecarMode(user:.approveForMe,bot:nil,readOnly:false,legacyCodexAutoApprove:false) == "acceptEdits", "ordinary auto reaches engine")
check(P.resolvedSidecarMode(user:.askFirst,bot:nil,readOnly:false,legacyCodexAutoApprove:true) == "default", "explicit ask overrides legacy auto")
check(P.resolvedSidecarMode(user:.configFile,bot:nil,readOnly:false,legacyCodexAutoApprove:true) == nil, "config is not silently upgraded")
check(P.resolvedSidecarMode(user:nil,bot:nil,readOnly:false,legacyCodexAutoApprove:true) == "acceptEdits", "legacy auto preserved")
check(P.resolvedSidecarMode(user:nil,bot:nil,readOnly:false,legacyCodexAutoApprove:false) == nil, "legacy default preserved")
for user in P.allCases {
  check(P.resolvedSidecarMode(user:user,bot:.askFirst,readOnly:false,legacyCodexAutoApprove:true) == "default", "explicit bot ask wins")
  check(!(P.askFirst.automaticallyApprovesTools), "explicit bot ask cannot inherit full")
  for bot in P.allCases {
    check(P.resolvedSidecarMode(user:user,bot:bot,readOnly:true,legacyCodexAutoApprove:true) == "readOnly", "readonly cannot inherit broader access")
  }
}
print("PERMISSION RESULT checks=\\(checks) failures=0")
`;
  const file = path.join(run, 'fixture.swift');
  fs.writeFileSync(file, source + body);
  const result = spawnSync('swift', [file], { encoding: 'utf8', timeout: 45000 });
  fs.writeFileSync(path.join(run, 'result.log'), result.stdout + result.stderr);
  process.stdout.write(result.stdout);
  assert.equal(result.status, 0, result.stderr || String(result.error));
  assert.match(result.stdout, /PERMISSION RESULT checks=34 failures=0/);
  const model = fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Facade/ChatPageModel.swift'), 'utf8');
  const engine = fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Facade/ChatLiveEngine.swift'), 'utf8');
  assert.match(model, /engine.userPermissionPreset = permissionPreset/);
  assert.match(model, /localLive\?\.userPermissionPreset = permissionPreset/);
  assert.match(model, /UserDefaults.standard.set\(permissionPreset.rawValue/);
  assert.match(engine, /sidecarPermissionModes\[threadID\] == \(permissionMode \?\? "configured-default"\)/);
  assert.doesNotMatch(model, /if selectedRemote == nil \{ localLive\?\.userPermissionPreset/);
  assert.match(engine, /\(botPreset \?\? userPermissionPreset\)\?\.automaticallyApprovesTools/);
  assert.doesNotMatch(model, /Claude 想要執行/);
});
