#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const skill = fs.readFileSync(path.join(root, 'SKILL.md'), 'utf8');
const lines = skill.split(/\r?\n/).length;
const failures = [];
if (lines >= 500) failures.push(`SKILL.md has ${lines} lines; expected fewer than 500`);
for (const rel of ['references/public-contract.md', 'references/security-boundary.md']) {
  const target = path.join(root, rel);
  if (!fs.existsSync(target)) failures.push(`missing ${rel}`);
  else if (!fs.readFileSync(target, 'utf8').trim()) failures.push(`empty ${rel}`);
  if (!skill.includes(rel)) failures.push(`SKILL.md does not reference ${rel}`);
}
for (const pattern of [/\/Users\//, /\/Volumes\//, /@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/]) {
  if (pattern.test(skill)) failures.push(`private marker matched ${pattern}`);
}
if (failures.length) {
  process.stderr.write(`${failures.join('\n')}\n`);
  process.exit(1);
}
process.stdout.write(`TATWO ULTRAWORK PUBLIC SKILL SELFTEST PASS (${lines} lines)\n`);
