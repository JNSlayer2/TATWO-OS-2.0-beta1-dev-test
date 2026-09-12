#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = process.cwd();
const checker = path.join(root, 'scripts/tatwo-live-quota-runtime-check.mjs');
const findings = [];
const cases = [];

function makeTempHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'tatwo-quota-negative-'));
}

function runCase(id, prepare, expectedFindingID) {
  const home = makeTempHome();
  try {
    prepare(home);
    const result = spawnSync(process.execPath, [checker], {
      cwd: root,
      env: { ...process.env, HOME: home },
      encoding: 'utf8',
      timeout: 15000
    });
    let parsed = null;
    try {
      parsed = JSON.parse(result.stdout || '{}');
    } catch {
      findings.push({ id: `${id}.json`, expected: 'negative quota check returns JSON', evidence: result.stdout.slice(0, 160) });
    }
    const findingIDs = Array.isArray(parsed?.findings) ? parsed.findings.map((item) => item.id) : [];
    const passed = result.status === 1 && parsed?.ok === false && findingIDs.includes(expectedFindingID);
    cases.push({ id, passed, exitStatus: result.status, ok: parsed?.ok, findingIDs });
    if (!passed) {
      findings.push({
        id,
        expected: `missing/invalid Codex auth must fail closed with ${expectedFindingID}`,
        evidence: { exitStatus: result.status, ok: parsed?.ok, findingIDs }
      });
    }
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

runCase('missing_auth_json', () => {}, 'codex.auth.present');
runCase('missing_token_account', (home) => {
  fs.mkdirSync(path.join(home, '.codex'), { recursive: true });
  fs.writeFileSync(path.join(home, '.codex/auth.json'), JSON.stringify({ tokens: {} }), 'utf8');
}, 'codex.auth.token_account.present');

const ok = findings.length === 0;
console.log(JSON.stringify({
  schema: 'TatwoLiveQuotaNegativeCheckV1',
  ok,
  checkedAt: new Date().toISOString(),
  summary: { cases: cases.length, findings: findings.length },
  cases,
  findings
}, null, 2));
process.exit(ok ? 0 : 1);
