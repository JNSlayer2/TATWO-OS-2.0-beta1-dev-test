#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const skip = new Set(['.git', 'node_modules', 'coverage']);
const textExtensions = new Set(['', '.md', '.mjs', '.js', '.json', '.yaml', '.yml', '.txt', '.gitignore']);
const forbidden = [
  ['/Users path', /\/Users\//],
  ['/Volumes path', /\/Volumes\//],
  ['/home path', /\/home\/[A-Za-z0-9._-]+\//],
  ['Windows user path', /[A-Za-z]:\\Users\\/i],
  ['private key', /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/],
  ['generic secret assignment', /\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*["'][^"']{8,}/i],
  ['provider token', /\b(?:sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{20,})\b/],
  ['email address', /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i],
  ['sensitive directory', /(?:^|\/)(?:receipts|sessions|attachments|browser-profile|DerivedData)(?:\/|$)/i],
];
const findings = [];

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (skip.has(entry.name)) continue;
    const file = path.join(dir, entry.name);
    const rel = path.relative(root, file);
    const stat = fs.lstatSync(file);
    if (!/^[\x20-\x7e]+$/.test(rel)) findings.push(`${rel}: non-ASCII path rejected`);
    if (/(^|\/)(?:\.env(?:\..*)?|receipts|sessions|attachments|browser-profile|DerivedData|\.claude|\.codex)(?:\/|$)/i.test(rel)) findings.push(`${rel}: sensitive path rejected`);
    if ((stat.mode & 0o002) !== 0) findings.push(`${rel}: world-writable file rejected`);
    if (stat.isSymbolicLink()) { findings.push(`${rel}: symlink rejected`); continue; }
    if (stat.isDirectory()) { walk(file); continue; }
    if (!stat.isFile()) continue;
    if (stat.size > 1_000_000) { findings.push(`${rel}: file exceeds 1 MB`); continue; }
    const ext = entry.name === '.gitignore' ? '.gitignore' : path.extname(entry.name);
    if (!textExtensions.has(ext)) { findings.push(`${rel}: non-text file rejected`); continue; }
    const data = fs.readFileSync(file);
    if (data.includes(0)) { findings.push(`${rel}: binary content rejected`); continue; }
    const source = data.toString('utf8');
    for (const [label, pattern] of forbidden) if (pattern.test(source)) findings.push(`${rel}: ${label}`);
  }
}
walk(root);
if (findings.length) {
  process.stderr.write(`PUBLIC SAFETY SCAN FAIL\n${findings.map(item => `- ${item}`).join('\n')}\n`);
  process.exit(1);
}
process.stdout.write('PUBLIC SAFETY SCAN PASS\n');
