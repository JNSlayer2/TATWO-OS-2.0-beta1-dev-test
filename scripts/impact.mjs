#!/usr/bin/env node
// One-shot textual impact scan. No index, daemon, parser or third-party modules.
import { spawn } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const impactLanguages = ['swift', 'objc', 'js', 'auto'];
export const impactLimitations = '純文字 word-boundary 比對；定義處只用單行啟發式，不解析語法，不追繼承與 protocol 一致性。註解／字串也會命中；多行宣告、別名、隱含 enum case／selector 呼叫可能漏掉。auto 只掃 Swift、ObjC、JS/TS 家族副檔名，不跟隨符號連結。';
const extensions = {
  swift: ['.swift'],
  objc: ['.m', '.mm', '.h'],
  js: ['.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx'],
};
const excluded = new Set(['dist', 'evidence', 'node_modules', '.git']);

export function validateImpactInput(symbol, lang = 'auto', limit = 200) {
  if (typeof symbol !== 'string' || symbol.length < 1 || symbol.length > 120
    || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(symbol)) throw new Error('impact_invalid_symbol');
  if (!impactLanguages.includes(lang)) throw new Error('impact_invalid_lang');
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) throw new Error('impact_invalid_limit');
}

function isDefinition(text, symbol) {
  // Deliberately conservative line heuristics, NOT syntax or scope resolution.
  if (/^\s*(?:\/\/|\/\*|\*|\*\/)/.test(text)) return false;
  return [
    `\\b(?:class|struct|enum|protocol|actor|typealias|associatedtype|func|function|var|let|const|type|interface)\\s+${symbol}\\b`,
    `^\\s*(?:indirect\\s+)?case\\s+${symbol}\\b`,
    `^\\s*@(?:interface|implementation|protocol)\\s+${symbol}\\b`,
    `^\\s*[-+]\\s*\\([^)]*\\)\\s*${symbol}\\b`,
    `^\\s*@property\\b[^;=]*\\b${symbol}\\s*;`,
    `\\b(?:NS_ENUM|NS_OPTIONS)\\s*\\([^,]+,\\s*${symbol}\\b`,
  ].some(pattern => new RegExp(pattern).test(text));
}

// Both backends emit filename NUL line-number ":" text newline. Unlike splitting
// at ":", this also handles filenames containing colons, spaces and newlines.
function search(command, files, patterns, { root, deadline, spawnImpl, onMatch }) {
  return new Promise((resolve, reject) => {
    const flags = command === 'rg'
      ? ['--no-config', '--hidden', '--no-ignore', '--sort', 'path', '-n', '-H', '--null', '--no-heading', '--color', 'never', '-F', '-w']
      : ['-rnHI', '--null', '-F', '-w'];
    const args = [...flags, ...patterns.flatMap(p => ['-e', p]), '--', ...files];
    const child = spawnImpl(command, args, {
      cwd: root, shell: false, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let buffer = '', failure = null;
    const stop = reason => { failure = reason; child.kill('SIGKILL'); };
    const timer = setTimeout(() => stop('timeout'), Math.max(1, deadline - Date.now()));
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      buffer += chunk;
      while (true) {
        const zero = buffer.indexOf('\0');
        const end = zero < 0 ? -1 : buffer.indexOf('\n', zero);
        if (end < 0) break;
        const file = buffer.slice(0, zero);
        const record = buffer.slice(zero + 1, end);
        buffer = buffer.slice(end + 1);
        const match = /^(\d+):(.*)\r?$/s.exec(record);
        if (!match || !files.includes(file)) { stop('invalid_search_output'); break; }
        if (record.length > 1024 * 1024) { stop('search_record_too_large'); break; }
        onMatch({ file, line: Number(match[1]), text: match[2].replace(/\r$/, '') });
      }
      // Bound even an unterminated/minified line; do not silently omit it.
      if (buffer.length > 1024 * 1024) stop('search_record_too_large');
    });
    child.stderr.resume(); // Drain without retaining potentially unbounded diagnostics.
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      resolve(failure || (code === 0 || code === 1
        ? (buffer.length ? 'incomplete_search_output' : null) : `search_exit_${code ?? signal}`));
    });
  });
}

export async function codeImpact(symbol, {
  root = process.cwd(), lang = 'auto', limit = 200, spawnImpl = spawn, timeoutMs = 20_000,
} = {}) {
  // Validate BEFORE traversal and BEFORE even an executable availability probe.
  validateImpactInput(symbol, lang, limit);
  root = path.resolve(root);
  const deadline = Date.now() + timeoutMs;
  const allowed = new Set(lang === 'auto' ? Object.values(extensions).flat() : extensions[lang]);
  const sources = [], testFiles = [], errors = [];
  let enumerationComplete = true;
  const recordError = (stage, code) => { if (errors.length < 10) errors.push({ stage, code }); };
  async function walk(relative = '') {
    if (Date.now() >= deadline) { enumerationComplete = false; return; }
    let entries;
    try { entries = await readdir(path.join(root, relative), { withFileTypes: true }); }
    catch (error) { enumerationComplete = false; recordError('enumeration', error.code); return; }
    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (Date.now() >= deadline) { enumerationComplete = false; break; }
      if (excluded.has(entry.name) || entry.name.startsWith('.build')) continue;
      const file = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        await walk(file);
      } else if (entry.isFile()) { // Never follow symlinks out of the selected root.
        if (allowed.has(path.extname(entry.name))) sources.push(file);
        if (/^tests\/[^/]+\.test\.mjs$/.test(file)) testFiles.push(file);
      }
    }
  }
  await walk();
  sources.sort();
  testFiles.sort();
  let backend = 'rg', usedBackend = null;
  async function scan(files, patterns, onMatch) {
    let scanned = 0;
    // Bounded argv sizes; output is consumed continuously, not maxBuffer-truncated.
    for (let i = 0; i < files.length; i += 32) {
      if (Date.now() >= deadline) { recordError('search', 'timeout'); break; }
      const batch = files.slice(i, i + 32);
      try {
        const options = { root, deadline, spawnImpl, onMatch };
        let failure;
        try { usedBackend = backend; failure = await search(backend, batch, patterns, options); }
        catch (error) {
          if (backend !== 'rg' || error.code !== 'ENOENT') throw error;
          backend = 'grep';
          usedBackend = backend;
          failure = await search(backend, batch, patterns, options);
        }
        if (failure) { recordError('search', failure); break; }
        scanned += batch.length;
      } catch (error) { recordError('search', error.code || 'spawn_failed'); break; }
    }
    return scanned;
  }
  let total = 0, definitionTotal = 0, referenceTotal = 0;
  const definitions = [], references = [], referenceCounts = new Map(), swiftNames = new Set();
  const scannedFiles = await scan(sources, [symbol], hit => {
    total += 1; // One matching LINE, not one token occurrence.
    if (hit.file.endsWith('.swift')) swiftNames.add(path.posix.basename(hit.file));
    if (isDefinition(hit.text, symbol)) {
      definitionTotal += 1;
      if (definitions.length < limit) definitions.push(hit);
    } else {
      referenceTotal += 1;
      referenceCounts.set(hit.file, (referenceCounts.get(hit.file) ?? 0) + 1);
      if (references.length < limit) references.push(hit);
    }
  });
  // Use ALL affected Swift filenames, not just the displayed/truncated hits.
  // Test matches remain independent of --lang (including --lang swift).
  const affectedTests = new Set(), patterns = [symbol, ...swiftNames];
  let scannedTestFiles = testFiles.length;
  for (let i = 0; i < patterns.length; i += 64) {
    const scanned = await scan(testFiles, patterns.slice(i, i + 64), hit => affectedTests.add(hit.file));
    scannedTestFiles = Math.min(scannedTestFiles, scanned);
    if (scanned !== testFiles.length) break;
  }
  const grouped = new Map();
  for (const { file, line, text } of references.slice(0, limit - definitions.length)) {
    if (!grouped.has(file)) grouped.set(file, { file, count: referenceCounts.get(file), matches: [] });
    grouped.get(file).matches.push({ line, text });
  }
  const complete = enumerationComplete && scannedFiles === sources.length
    && scannedTestFiles === testFiles.length && errors.length === 0;
  const truncated = total > limit || affectedTests.size > limit;
  const message = [
    total > limit ? (complete ? `已截斷，實際 ${total} 筆` : `已截斷，目前至少 ${total} 筆`) : '',
    affectedTests.size > limit ? `測試檔已截斷，目前 ${affectedTests.size} 檔` : '',
    complete ? '' : `未掃完；已完成掃描 ${scannedFiles}/${sources.length} 個已列舉來源檔，命中至少 ${total} 筆`,
  ].filter(Boolean).join('；') || `實際 ${total} 筆`;
  return {
    symbol, lang, root, backend: usedBackend, limit, total, totalExact: complete, truncated, complete, message,
    coverage: { enumerationComplete, candidateFiles: sources.length, scannedFiles,
      candidateTestFiles: testFiles.length, scannedTestFiles, timeoutMs },
    definitionTotal, referenceTotal, definitions, references: [...grouped.values()],
    affectedTestTotal: affectedTests.size, affectedTests: [...affectedTests].sort().slice(0, limit),
    limitations: impactLimitations, errors,
  };
}

export function formatImpact(result) {
  const lines = [`${result.symbol} — ${result.message}`, result.limitations,
    '① 定義處（單行啟發式）'];
  for (const hit of result.definitions) lines.push(`  ${hit.file}:${hit.line} ${hit.text}`);
  if (!result.definitions.length) lines.push('  （無）');
  lines.push(`② 直接引用點（${result.referenceTotal} 筆；每行算一筆）`);
  for (const group of result.references) {
    lines.push(`  ${group.file}（${group.count} 筆，顯示 ${group.matches.length} 筆）`);
    for (const hit of group.matches) lines.push(`    ${group.file}:${hit.line} ${hit.text}`);
  }
  if (!result.references.length) lines.push('  （無或未顯示）');
  lines.push(`③ 受影響的測試檔（${result.affectedTestTotal} 檔）`, ...result.affectedTests.map(f => `  ${f}`));
  if (!result.affectedTests.length) lines.push('  （無）');
  lines.push(`掃描：來源 ${result.coverage.scannedFiles}/${result.coverage.candidateFiles} 檔，測試 ${result.coverage.scannedTestFiles}/${result.coverage.candidateTestFiles} 檔；complete=${result.complete}`);
  return lines.join('\n');
}

async function main(argv) {
  const symbol = argv.shift();
  let lang = 'auto', limit = 200, json = false;
  while (argv.length) {
    const arg = argv.shift();
    if (arg === '--json') json = true;
    else if (arg === '--lang') lang = argv.shift();
    else if (arg === '--limit') limit = Number(argv.shift());
    else throw new Error('Usage: impact.mjs <symbol> [--lang swift|objc|js|auto] [--json] [--limit 1–200]');
    if (arg === '--lang' && lang === undefined) throw new Error('impact_invalid_lang');
  }
  const result = await codeImpact(symbol, { lang, limit });
  console.log(json ? JSON.stringify(result) : formatImpact(result));
  if (!result.complete) process.exitCode = 2;
}

// Compare real paths: on macOS /tmp is a symlink to /private/tmp, so path.resolve
// alone silently fails the check and main() never runs while still exiting 0.
const realOrResolved = p => { try { return realpathSync(p); } catch { return path.resolve(p); } };
if (process.argv[1]
  && realOrResolved(process.argv[1]) === realOrResolved(fileURLToPath(import.meta.url))) {
  main(process.argv.slice(2)).catch(error => {
    const message = error?.message || String(error);
    if (process.argv.includes('--json')) console.log(JSON.stringify({ error: message }));
    else console.error(message);
    process.exitCode = 1;
  });
}
