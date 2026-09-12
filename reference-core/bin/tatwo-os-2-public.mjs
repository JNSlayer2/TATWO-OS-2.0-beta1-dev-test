#!/usr/bin/env node
import fs from 'node:fs';
import { mergeReports, previewRooms } from '../src/core.mjs';

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}

const [command, file] = process.argv.slice(2);
if (!['preview', 'merge'].includes(command) || !file) {
  fail('usage: tatwo-os-2-public <preview|merge> <json-file>');
} else {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1_000_000) throw new Error('input_file_rejected');
    let input;
    try { input = JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch { throw new Error('input_not_valid_json'); }
    const result = command === 'preview' ? previewRooms(input) : mergeReports(input);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (error) {
    fail(String(error?.message || error));
  }
}
