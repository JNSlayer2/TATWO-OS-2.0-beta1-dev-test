"""Build-time layer hashing/packaging. Installer needs only macOS built-ins."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import zipfile
import shutil


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def manifest(contents):
    paths = Path(__file__).with_suffix(".txt").read_text().splitlines()
    assert paths and len(paths) == len(set(paths)), "empty/duplicate runtime paths"
    for path in paths:
        assert path.startswith(("Resources/", "Frameworks/"))
        assert all(p not in ("", ".", "..") for p in path.split("/"))
        assert not any(path.startswith(other + "/") for other in paths if other != path)
        assert all(not (contents / Path(*Path(path).parts[:i])).is_symlink()
                   for i in range(len(Path(path).parts))), "symlink runtime ancestor"
    entries = []

    def visit(path):
        info = path.lstat()
        relative = path.relative_to(contents).as_posix()
        if stat.S_ISLNK(info.st_mode):
            entries.append([relative, "link", os.readlink(path)])
        elif stat.S_ISREG(info.st_mode):
            entries.append([relative, "file", stat.S_IMODE(info.st_mode), digest(path)])
        else:
            assert stat.S_ISDIR(info.st_mode), "unsupported runtime entry"
            entries.append([relative, "dir", stat.S_IMODE(info.st_mode)])
            for child in path.iterdir():
                visit(child)

    for path in paths:
        visit(contents / path)
    # C/UTF-8 byte order; JSON lines frame names/targets safely even with whitespace/newlines.
    records = "".join(json.dumps(e, ensure_ascii=True, separators=(",", ":")) + "\n"
                      for e in sorted(entries, key=lambda e: e[0].encode("utf-8")))
    return {"sha": hashlib.sha256(records.encode()).hexdigest(), "paths": paths}


def ditto(*args):
    subprocess.run(["ditto", *map(str, args)], check=True)


def archive(source, destination, parent=False):
    if parent:
        ditto("-c", "-k", "--norsrc", "--keepParent", source, destination)
    else:
        # Content-addressed ZIP: no wall-clock timestamps, xattrs, or traversal order.
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for p in sorted(source.rglob('*'), key=lambda p: p.relative_to(source).as_posix().encode()):
                mode = p.lstat().st_mode
                directory = stat.S_ISDIR(mode)
                entry = zipfile.ZipInfo(p.relative_to(source).as_posix() + ('/' if directory else ''),
                                        date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (mode << 16) | (0x10 if directory else 0)
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry._compresslevel = 9
                if directory or p.is_symlink():
                    z.writestr(entry, b'' if directory else os.readlink(p).encode())
                else:
                    with p.open('rb') as src, z.open(entry, 'w', force_zip64=True) as dst:
                        shutil.copyfileobj(src, dst, 1048576)
    destination.with_suffix(".zip.sha256").write_text(f"{digest(destination)}  {destination.name}\n")


def main():
    mode, app, *args = sys.argv[1:]
    app = Path(app).absolute()
    contents = app / "Contents"
    expected = manifest(contents)
    metadata = contents / "Resources/runtime-layer.json"
    if mode == "prepare":
        assert not args
        metadata.write_text(json.dumps(expected, separators=(",", ":")) + "\n")
    elif mode == "split":
        out = Path(args[0]).absolute()
        assert json.loads(metadata.read_text()) == expected, "runtime changed after manifest/signing"
        out.mkdir(parents=True, exist_ok=True)
        app_zip = out / "TATWO-OS-app.zip"
        runtime_zip = out / f"TATWO-OS-runtime-{expected['sha'][:12]}.zip"
        assert not any(p.exists() for p in (app_zip, runtime_zip,
                       app_zip.with_suffix(".zip.sha256"), runtime_zip.with_suffix(".zip.sha256")))
        # Keep working artifacts for inspection/rollback; never delete source/repo artifacts.
        work = Path(tempfile.mkdtemp(prefix=".runtime-layer-", dir=out))
        staged = work / "TATWO OS.app"
        runtime = work / "runtime"
        ditto(app, staged)
        for path in expected["paths"]:
            target = runtime / path
            target.parent.mkdir(parents=True, exist_ok=True)
            (staged / "Contents" / path).rename(target)
        archive(staged, app_zip, parent=True)
        archive(runtime, runtime_zip)
        print(runtime_zip)
    else:
        raise ValueError("usage: runtime-layer.sh prepare APP | split APP OUT")


if __name__ == "__main__":
    main()
