#!/bin/bash
# Host-only packaging. MacBook receives this runtime; it does not need Homebrew or a compiler.
set -euo pipefail
[[ $# == 1 && -d "$1/Contents/Resources" ]] || { echo "usage: bundle-cli-runtime.sh existing.app" >&2; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "$1" <<'PY'
from pathlib import Path
import hashlib, json, shutil, subprocess, sys

repo, app = map(Path, sys.argv[1:])
runtime = app / "Contents/Resources/runtime"
binary = runtime / "bin/tmux"
lib = runtime / "lib"
licenses = runtime / "licenses/cli"
for directory in [binary.parent, lib, licenses]:
    directory.mkdir(parents=True, exist_ok=True)

def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()

source = Path(run("/usr/bin/which", "tmux")).resolve()
assert run(str(source), "-V") == "tmux 3.6a", "reference frozen: do not silently change tmux"
origins = {}

def stage(origin, target):
    origins[target.name] = hashlib.sha256(origin.read_bytes()).hexdigest()
    shutil.copyfile(origin, target)
    target.chmod(0o755)

stage(source, binary)
pending = [(source, binary)]
seen = set()
while pending:
    original, target = pending.pop()
    for line in run("/usr/bin/otool", "-L", str(original)).splitlines()[1:]:
        dep = line.strip().split(" (compatibility")[0]
        if dep == str(original) or dep.startswith(("/usr/lib/", "/System/Library/")):
            continue
        assert dep.startswith("/opt/homebrew/"), f"unknown non-system runtime dependency: {dep}"
        destination = lib / Path(dep).name
        relative = "@loader_path/" + ("../lib/" if target == binary else "") + destination.name
        run("/usr/bin/install_name_tool", "-change", dep, relative, str(target))
        if destination.name not in seen:
            seen.add(destination.name)
            stage(Path(dep), destination)
            run("/usr/bin/install_name_tool", "-id", "@loader_path/" + destination.name, str(destination))
            pending.append((Path(dep), destination))

license_sources = {
    "tmux-COPYING": source.parent.parent / "COPYING",
    "utf8proc-LICENSE.md": Path("/opt/homebrew/opt/utf8proc/LICENSE.md"),
    "ncurses-COPYING": Path("/opt/homebrew/opt/ncurses/COPYING"),
    "libevent-LICENSE": Path("/opt/homebrew/opt/libevent/LICENSE"),
    "SwiftTerm-LICENSE": repo / ".build-sol/checkouts/SwiftTerm/LICENSE",
}
for name, path in license_sources.items():
    assert path.is_file(), f"missing license: {name}"
    shutil.copyfile(path, licenses / name)
for target in [binary] + [lib / name for name in sorted(seen)]:
    dependencies = run("/usr/bin/otool", "-L", str(target))
    assert "/opt/homebrew/" not in dependencies, "runtime is not relocatable"
    run("/usr/bin/codesign", "--force", "--sign", "-", str(target))
assert run(str(binary), "-V") == "tmux 3.6a"
wrapper = runtime / "bin/grok-isolated"
shutil.copyfile(repo / "scripts/tatwo2-grok-cli.sh", wrapper)
wrapper.chmod(0o755)
manifest = {
    "tmux": "3.6a", "SwiftTerm": "1.19.0", "originalSHA256": origins,
    "bundledSHA256": {
        str(path.relative_to(runtime)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [binary, wrapper] + [lib / name for name in sorted(seen)] +
        sorted(licenses.iterdir())
    },
}
(runtime / "cli-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("CLI runtime: tmux 3.6a, relocatable dylibs, licenses, isolated Grok launcher")
PY
