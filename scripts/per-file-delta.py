"""Post-signing manifests; publish a delta only after the real installer reassembles it."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1048576), b""):
            value.update(chunk)
        return value.hexdigest()


def record(path, relative):
    info = path.lstat()
    entry = dict(path=relative, mode=format(stat.S_IMODE(info.st_mode), "o"))
    if path.is_symlink():
        target = os.readlink(path)
        entry.update(symlink=target, sha256=hashlib.sha256(target.encode()).hexdigest(),
                     size=len(target.encode()))
    elif path.is_dir():
        entry.update(directory=True, sha256=hashlib.sha256(b"").hexdigest(), size=0)
    else:
        assert stat.S_ISREG(info.st_mode), "unsupported bundle entry"
        entry.update(sha256=digest(path), size=info.st_size)
    return entry


def manifest(app, tag, from_tag):
    entries = []
    def visit(path):
        entries.append(record(path, path.relative_to(app / "Contents").as_posix()))
        if path.is_dir() and not path.is_symlink():
            for child in sorted(path.iterdir(), key=lambda p: p.name.encode()):
                visit(child)
    visit(app / "Contents")
    return dict(schema=1, tag=tag, fromTag=from_tag, files=entries)


def checksum(path):
    path.with_name(path.name + ".sha256").write_text(f"{digest(path)}  {path.name}\n")


def main():
    app, out, tag, *previous = sys.argv[1:]
    app, out = Path(app).absolute(), Path(out).absolute()
    assert re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag)
    try:
        old = json.loads(Path(previous[0]).read_text()) if previous and previous[0] else None
        assert not old or (old["schema"] == 1 and isinstance(old["files"], list) and
                           re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", old["tag"]) and
                           tuple(map(int, old["tag"][1:].split("."))) < tuple(map(int, tag[1:].split("."))))
    except (ValueError, KeyError, TypeError, AssertionError) as error:
        print(f"略過 delta：上一版 manifest 無效 ({type(error).__name__})")
        old = None
    from_tag = old["tag"] if old else ""
    out.mkdir(parents=True, exist_ok=True)
    new = manifest(app, tag, from_tag)
    meta = out / "TATWO-OS.manifest.json"
    assert not meta.exists(), "refuse to overwrite manifest"
    meta.write_text(json.dumps(new, ensure_ascii=True, separators=(",", ":")) + "\n")
    checksum(meta)
    if not old:
        print("略過 delta：沒有上一版 manifest")
        return
    # Retained, unadvertised work area. No delta attachment appears before verification.
    work = Path(tempfile.mkdtemp(prefix=".per-file-delta-", dir=out))
    payload, simulated = work / "payload", work / "old.app/Contents"
    payload.mkdir()
    simulated.mkdir(parents=True)
    prior = {e["path"]: e for e in old["files"]}
    for entry in new["files"]:
        path = entry["path"]
        source = app / "Contents" / path
        assert record(source, path) == entry, "bundle changed during packaging"
        if entry.get("directory"):
            continue
        # A simulated old file is allowed ONLY if its entire old record matches.
        target = (simulated if prior.get(path) == entry else payload) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        run("cp", "-Pp", source, target) if source.is_symlink() else run("ditto", source, target)
        assert record(target, path) == entry, "copy differs from manifest"
    candidate = work / "candidate.zip"
    run("ditto", "-c", "-k", "--norsrc", payload, candidate)
    installer = Path(__file__).resolve().parent.parent / "install.sh"
    tree = installer.read_text().split("# DELTA-TREE-BEGIN\n")[1].split("# DELTA-TREE-END")[0]
    assembled = work / "assembled.app"
    run("bash", "-c", "set -euo pipefail\n" + tree + '\ndelta_tree "$@"',
        "delta-check", meta, candidate, simulated.parent, assembled)
    assert manifest(assembled, tag, from_tag) == new, "offline reconstruction mismatch"
    archive = out / f"TATWO-OS-delta-{from_tag}-{tag}.zip"
    assert not archive.exists()
    candidate.rename(archive)
    checksum(archive)
    print(f"delta 離線逐檔驗證通過：{archive.name}")


if __name__ == "__main__":
    main()
