#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const skip = new Set(['.git']);
// Decode every non-resource file as UTF-8, including Swift, shell, TOML,
// plist and strings. Unknown extensions must not provide a scan bypass.
const binaryExtensions = new Set(['.png', '.icns', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.pdf', '.woff', '.woff2', '.ttf']);
const genericUsers = new Set(['example', 'demo', 'test', 'user', 'octocat', 'runner', 'ci', 'root', 'admin', 'fixture', 'sample']);
const exampleHost = value => /^(?:example(?:\.|$)|localhost$)|\.example$/i.test(value.replace(/\.$/, ''));
const octet = String.raw`(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)`;
// Capture values, not field syntax, so each occurrence uses the same exact-value allowlist.
const privacyRules = [
  ['macos username', /\/Users\/([A-Za-z0-9_][A-Za-z0-9_.-]*)|\b(?:user|username|userName|USER|USERNAME|name)["']?\s*:\s*["']([A-Za-z0-9_][A-Za-z0-9_.-]*)["']|^\s*(?:-\s*)?(?:user|username|name):\s*([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*(?:#.*)?$/g,
    match => match[1] ?? match[2] ?? match[3], value => genericUsers.has(value.toLowerCase())],
  ['private ip', new RegExp(String.raw`(?<![\w.])(?:10\.${octet}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.${octet}\.${octet}(?![\w.]|\.\d)`, 'g')],
  ['personal hostname', /(?<![\w.-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:tatwo214\.com|local)\.?(?![\w.-])/gi,
    match => match[0], exampleHost],
  // Host-like literals, SSH arguments and shell defaults. Overlapping model/tool
  // identifiers require reviewed exact-value exceptions, never a blanket skip.
  ['ssh host alias', /(?:["'`]\s*|:-|(?:\bssh|\bHost)\s+|(?:SSH_HOST|PRIMARY_HOST)\s*=\s*)([a-z0-9][a-z0-9.-]*(?:mac-mini|macbook|-codex|m4-)[a-z0-9.-]*|mac-mini[a-z0-9.-]*|macbook[a-z0-9.-]*|m4-[a-z0-9.-]*)(?=["'`\s}:]|$)/gi,
    match => match[1], exampleHost],
];
const forbidden = [
  ['private volume label', /Layer2[ ]ai|33\u8766/i],
  ['private user path', /\/Users\/layer[2]/i],
  ['private volume path', /\/Volumes\/(?:Codex[D]ata|Tatwo[2])/i],
  ['private account', /benny469[0]|wife1833[3]/i],
  ['private Discord ID', /147277873033327834[1]/],
  ['private data directory', /openclaw[-]data/i],
  ['private key', /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/],
  ['provider token', /\b(?:gh[op]_[A-Za-z0-9_]+|github[_]pat_[A-Za-z0-9_]+|sk[-][A-Za-z0-9_-]+)\b/],
  ['email address', /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i],
];
const findings = [];
const allowed = [];
const allowances = new Map();
const pending = [];

function occurrences(line, rule) {
  const [label, pattern, value = match => match[0], harmless = () => false] = rule;
  if (label === 'private key') return pattern.test(line) ? [line] : [];
  return [...line.matchAll(new RegExp(pattern.source, [...new Set(pattern.flags + 'g')].join('')))]
    .map(value).filter(value => !harmless(value));
}

function loadAllowances() {
  // Policy comes from this scanner's sibling, never from the tree being scanned.
  const policy = fileURLToPath(new URL('./public-safety-allow.txt', import.meta.url));
  const labels = new Set(['email address', 'provider token', 'private key', ...privacyRules.map(([label]) => label)]);
  fs.readFileSync(policy, 'utf8').split(/\r?\n/).forEach((line, index) => {
    if (!line.trim() || line.trimStart().startsWith('#')) return;
    const fields = line.split('|');
    const [file, label, reason] = fields.slice(0, 3).map(field => field.trim());
    // Preserve whitespace inside regex alternatives (notably exact key-header lines).
    const harmless = fields.slice(3).join('|').trim();
    if (fields.length < 4 || !harmless.startsWith("^") || !harmless.endsWith("$") || !file || !labels.has(label) || !reason
      || path.isAbsolute(file) || file.includes('\\') || /[*?[\]\x00-\x1f]/.test(file)
      || file.split('/').some(part => !part || part === '.' || part === '..')
      || allowances.has(`${file}|${label}`)) {
      throw new Error(`invalid allowlist entry at line ${index + 1}`);
    }
    let pattern;
    try { pattern = new RegExp(`^(?:${harmless})$`); }
    catch { throw new Error(`invalid allowlist entry at line ${index + 1}`); }
    allowances.set(`${file}|${label}`, { reason, pattern });
  });
}

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (skip.has(entry.name)) continue;
    const file = path.join(dir, entry.name);
    const rel = path.relative(root, file);
    const stat = fs.lstatSync(file);
    const fail = (line, label) => findings.push(`FAIL: ${rel}:${line}: ${label}`);
    for (const [label, pattern] of forbidden) {
      pattern.lastIndex = 0;
      if (pattern.test(rel)) fail(0, label);
    }
    for (const rule of privacyRules) {
      if (occurrences(rel, rule).length) fail(0, rule[0]);
    }
    if (/(^|\/)(?:\.env(?:\..*)?|receipts|sessions|attachments|browser-profile|DerivedData|\.claude|\.codex)(?:\/|$)/i.test(rel)) fail(0, 'sensitive path rejected');
    if ((stat.mode & 0o002) !== 0) fail(0, 'world-writable file rejected');
    if (stat.isSymbolicLink()) { fail(0, 'symlink rejected'); continue; }
    if (stat.isDirectory()) { walk(file); continue; }
    if (!stat.isFile()) { fail(0, 'special file rejected'); continue; }
    pending.push({ file, rel });
  }
}

async function inspect({ file, rel }) {
    const fail = (line, label) => findings.push(`FAIL: ${rel}:${line}: ${label}`);
    const ext = path.extname(file).toLowerCase();
    const data = await fs.promises.readFile(file);
    // Only actual binary resources may skip text inspection; renamed source is scanned.
    let source;
    try { source = new TextDecoder('utf-8', { fatal: true }).decode(data); }
    catch { source = null; }
    if (source === null || data.includes(0)) {
      if (binaryExtensions.has(ext)) console.log(`SKIP BINARY: ${rel}`);
      else fail(0, 'unexpected binary content');
      return;
    }
    source.split(/\r?\n/).forEach((line, index) => {
      for (const rule of [...forbidden, ...privacyRules]) {
        const [label] = rule;
        const values = occurrences(line, rule);
        if (!values.length) continue;
        const allowance = allowances.get(`${rel}|${label}`);
        // Every occurrence must be harmless; a fixture on the same line cannot hide another value.
        if (allowance && values.length > 0 && values.every(value => allowance.pattern.test(value))) allowed.push(`ALLOW: ${rel}:${index + 1}: ${label} (${allowance.reason})`);
        else fail(index + 1, label);
      }
    });
}
try {
  loadAllowances();
  walk(root);
  // Bounded I/O avoids serial cold reads on disk images, without unbounded fan-out.
  let next = 0;
  await Promise.all(Array.from({ length: 8 }, async () => {
    while (next < pending.length) {
      const item = pending[next++];
      try { await inspect(item); }
      catch { findings.push(`FAIL: ${item.rel}:0: unreadable file`); }
    }
  }));
} catch (error) {
  findings.push(`FAIL: .:0: unreadable tree or invalid allowlist${error.message.startsWith('invalid allowlist entry') ? ` (${error.message})` : ''}`);
}
if (allowed.length) process.stdout.write(`${allowed.sort().join('\n')}\n`);
if (findings.length) {
  process.stderr.write(`PUBLIC SAFETY SCAN FAIL\n${findings.sort().join('\n')}\n`);
  // Let piped ALLOW/FAIL output drain before terminating.
  process.exitCode = 1;
} else {
  process.stdout.write('PUBLIC SAFETY SCAN PASS\n');
}
