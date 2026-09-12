#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import https from 'node:https';
import { spawn } from 'node:child_process';

const findings = [];

function redactEmail(email) {
  if (!email || !email.includes('@')) return email ? '***' : null;
  const [local, domain] = email.split('@');
  return `${local.slice(0, 2)}******@${domain.slice(0, 1)}****`;
}

function getJSON(url, headers) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, { method: 'GET', headers, timeout: 8000 }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`HTTP ${res.statusCode}`));
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch (error) {
          reject(error);
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end();
  });
}

function runClaudeAuthStatus() {
  const executable = ['/opt/homebrew/bin/claude', '/usr/local/bin/claude']
    .find((candidate) => fs.existsSync(candidate));
  if (!executable) {
    return Promise.resolve({ available: false, source: 'CLI', message: '找不到 Claude CLI' });
  }
  return new Promise((resolve) => {
    const child = spawn(executable, ['auth', 'status', '--json'], {
      cwd: os.homedir(),
      env: {
        ...process.env,
        HOME: os.homedir(),
        PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
      },
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      resolve({ available: true, source: 'CLI timeout', timedOut: true, loggedIn: null, message: 'Claude auth 逾時；狀態未判定' });
    }, 8000);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => {
      clearTimeout(timer);
      resolve({ available: true, source: 'CLI', loggedIn: false, message: error.message });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        resolve({ available: true, source: 'CLI', loggedIn: false, exitCode: code, message: stderr.trim() || 'Claude auth 失敗' });
        return;
      }
      try {
        const parsed = JSON.parse(stdout);
        resolve({
          available: true,
          source: 'CLI auth',
          loggedIn: parsed.loggedIn === true,
          authMethod: parsed.authMethod ?? null,
          apiProvider: parsed.apiProvider ?? null,
          email: redactEmail(parsed.email ?? ''),
          subscriptionType: parsed.subscriptionType ?? null,
          quotaPercentPolicy: 'never-display-fake-percent'
        });
      } catch (error) {
        resolve({ available: true, source: 'CLI', loggedIn: false, message: 'Claude auth JSON 解析失敗' });
      }
    });
  });
}

async function probeCodex() {
  const authPath = `${os.homedir()}/.codex/auth.json`;
  if (!fs.existsSync(authPath)) {
    findings.push({
      id: 'codex.auth.present',
      expected: 'Codex live quota proof requires readable ~/.codex/auth.json; otherwise mark unverified instead of passing green',
      evidence: 'missing ~/.codex/auth.json'
    });
    return { available: false, source: '~/.codex/auth.json', message: 'Codex auth missing' };
  }
  const auth = JSON.parse(fs.readFileSync(authPath, 'utf8'));
  const accessToken = auth?.tokens?.access_token;
  const accountID = auth?.tokens?.account_id;
  if (!accessToken || !accountID) {
    findings.push({
      id: 'codex.auth.token_account.present',
      expected: 'Codex live quota proof requires access_token and account_id; otherwise mark unverified instead of passing green',
      evidence: { hasAccessToken: Boolean(accessToken), hasAccountID: Boolean(accountID) }
    });
    return { available: false, source: '~/.codex/auth.json', message: 'Codex auth token/account missing' };
  }
  const headers = {
    Authorization: `Bearer ${accessToken}`,
    'ChatGPT-Account-ID': accountID,
    'OpenAI-Beta': 'codex-1',
    originator: 'Codex Desktop',
    Accept: 'application/json'
  };
  const usage = await getJSON('https://chatgpt.com/backend-api/wham/usage', headers);
  const resetCredits = await getJSON('https://chatgpt.com/backend-api/wham/rate-limit-reset-credits', headers);
  const primaryUsed = usage?.rate_limit?.primary_window?.used_percent;
  const secondaryUsed = usage?.rate_limit?.secondary_window?.used_percent;
  const credits = Array.isArray(resetCredits?.credits) ? resetCredits.credits : [];
  const availableCredits = credits
    .filter((credit) => credit.status === 'available' && credit.reset_type === 'codex_rate_limits')
    .map((credit) => credit.expires_at)
    .filter(Boolean)
    .sort();
  const resetCreditsAvailable = availableCredits.length > 0
    ? availableCredits.length
    : (resetCredits?.available_count ?? 0);
  if (!Number.isFinite(primaryUsed) || !Number.isFinite(secondaryUsed)) {
    findings.push({ id: 'codex.usage.percent.present', expected: 'Codex usage endpoint returns both windows', evidence: { primaryUsed, secondaryUsed } });
  }
  if ((resetCredits?.available_count ?? availableCredits.length) !== availableCredits.length) {
    findings.push({
      id: 'codex.reset_credit.count_matches_expiry_rows',
      expected: 'Reset-credit endpoint available_count should match available codex reset credits with expiry dates',
      evidence: { available_count: resetCredits?.available_count, expiryCount: availableCredits.length }
    });
  }
  return {
    available: true,
    source: 'chatgpt wham live endpoints',
    email: redactEmail(usage?.email ?? ''),
    planType: usage?.plan_type ?? null,
    primaryRemainingPercent: Number.isFinite(primaryUsed) ? 100 - primaryUsed : null,
    secondaryRemainingPercent: Number.isFinite(secondaryUsed) ? 100 - secondaryUsed : null,
    primaryResetAt: usage?.rate_limit?.primary_window?.reset_at ?? null,
    secondaryResetAt: usage?.rate_limit?.secondary_window?.reset_at ?? null,
    resetCreditsAvailable,
    resetCreditExpiryDates: availableCredits.map((value) => value.slice(0, 10))
  };
}

let codex;
try {
  codex = await probeCodex();
} catch (error) {
  codex = { available: false, source: 'chatgpt wham live endpoints', message: error.message };
  findings.push({ id: 'codex.live_probe.failed', expected: 'Codex live probe should be readable when auth exists', evidence: error.message });
}

const claude = await runClaudeAuthStatus();
const ok = findings.length === 0;
console.log(JSON.stringify({
  schema: 'TatwoLiveQuotaRuntimeCheckV1',
  ok,
  checkedAt: new Date().toISOString(),
  codex,
  claude,
  policy: {
    codexResetCreditsAreCodexOnly: true,
    claudeBridgeIsNotQuotaSource: true,
    noSecretsPrinted: true
  },
  findings
}, null, 2));
process.exit(ok ? 0 : 1);
