#!/bin/bash
# Local-only whitelist export. Never publishes, installs, or permanently deletes.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/.." && pwd -P)"
# Worktree layout defaults to its sibling beta1/export; portable clones use App Support.
DEFAULT_ROOT="${SOURCE%/worktrees/*}/beta1/export"
if [[ "$SOURCE" != */worktrees/* ]]; then
  DEFAULT_ROOT="$HOME/Library/Application Support/tatwo2/public-export"
fi
DEST="${1:-${TATWO_PUBLIC_EXPORT_ROOT:-$DEFAULT_ROOT}}"
[[ $# -le 1 ]] || { echo 'Usage: public-export.sh [output-directory]' >&2; exit 1; }
export SOURCE DEST
node --input-type=module <<'JS'
import fs from 'node:fs';
import path from 'node:path';
const source = fs.realpathSync(process.env.SOURCE);
const dest = path.resolve(process.env.DEST);
let existing = dest;
while (!fs.existsSync(existing)) existing = path.dirname(existing);
const resolved = path.resolve(fs.realpathSync(existing), path.relative(existing, dest));
if (resolved === source || resolved.startsWith(source + '/') || source.startsWith(resolved + '/') || resolved === path.parse(resolved).root || resolved === process.env.HOME) {
  throw new Error('Output must not overlap source, filesystem root, or home');
}
if (fs.existsSync(dest) && (!fs.lstatSync(dest).isDirectory() || fs.lstatSync(dest).isSymbolicLink())) throw new Error('Output must be a real directory');
JS
# Preserve any previous output in Trash before rsync --delete, even on scan failure.
if [[ -e "$DEST" ]]; then
  command -v trash >/dev/null || { echo 'trash is required to preserve previous output' >&2; exit 1; }
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  cat > "${DEST}.trash-${STAMP}.md" <<EOF
# Export replacement manifest
Original source: $DEST
Reason: caller requested a fresh whitelist export; previous tree preserved, not permanently removed.
Restore: locate the directory in macOS Trash and use Put Back after moving the new export aside.
Permanent removal requires approval by a different human or AI.
EOF
  trash "$DEST"
fi
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"
export DEST
# Enumerate ONLY named roots, then apply the explicitly prohibited artifact rules.
# NUL-delimited file lists preserve Unicode/space-containing filenames.
node --input-type=module <<'JS' | rsync -a --delete --from0 --files-from=- "$SOURCE/" "$DEST/"
import { execFileSync } from 'node:child_process';
const roots = ['App/', 'Apps/', 'Tools/', 'Packages/', 'Engines/', 'scripts/', 'tests/', 'public/', 'skills/tatwo-ultrawork/SKILL.md', 'skills/tatwo-ultrawork/agents/', 'Package.swift', 'Package.resolved', 'README.md', 'LICENSE', 'SECURITY.md', 'os.md', '.gitignore'];
roots.push('config/tatwo-sync-catalog-v1.json', 'config/tatwo-durable-surface-inventory-v1.json', 'config/sync-modules.v1.json');
const files = execFileSync('git', ['-C', process.env.SOURCE, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', ...roots], { maxBuffer: 64 * 1024 * 1024 }).toString().split('\0').filter(Boolean);
const banned = new Set(['docs', 'note.md', '經驗.md', 'CLAUDE.md', 'AGENTS.md', '.seedmux', '.tatwo2', '.review-tmp', 'output', 'goldens', 'shots', 'runtime-backups', '.git', 'node_modules', 'dist']);
for (const file of [...new Set(files)].sort()) {
  if (file.startsWith('App/Sources/Tatwo2/_archived/')) continue;
  if (file.split('/').some(part => banned.has(part) || part.startsWith('.build') || /\.sqlite/.test(part))) continue;
  process.stdout.write(file + '\0');
}
JS
[[ -f "$DEST/public/README.md" ]] || { echo 'Missing public/README.md' >&2; exit 1; }
cp "$DEST/public/README.md" "$DEST/README.md"
if [[ -f "$DEST/public/install.sh" ]]; then cp "$DEST/public/install.sh" "$DEST/install.sh"; fi
COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
SOURCE_STATE=clean
if [[ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=normal)" ]]; then SOURCE_STATE=dirty; fi
export COMMIT SOURCE_STATE
node --input-type=module <<'JS'
import fs from 'node:fs';
import path from 'node:path';
const root = process.env.DEST;
const files = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(file);
    else files.push(path.relative(root, file));
  }
}
walk(root);
files.push('EXPORT-MANIFEST.txt');
fs.writeFileSync(path.join(root, 'EXPORT-MANIFEST.txt'), `Source commit: ${process.env.COMMIT}\nSource worktree: ${process.env.SOURCE_STATE}\nFiles: ${files.length}\n${files.sort().join('\n')}\n`);
console.log(`EXPORTED FILES: ${files.length}`);
const manifest = fs.readFileSync(path.join(root, 'Package.swift'), 'utf8');
for (const match of manifest.matchAll(/\bpath:\s*"([^"]+)"/g)) {
  const target = match[1];
  if (!/^(?:App|Apps|Tools|Packages|Engines)\//.test(target) || target.split('/').includes('..') || !fs.statSync(path.join(root, target)).isDirectory()) throw new Error(`Missing or non-whitelist target path: ${target}`);
}
console.log('PACKAGE TARGET PATHS PASS');
JS
node "$SOURCE/scripts/public-safety-scan.mjs" "$DEST"
