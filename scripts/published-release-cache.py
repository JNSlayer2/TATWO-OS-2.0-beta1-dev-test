"""Reuse published bytes only after checking fresh GitHub server digests."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess


def materialize(metadata, tag, cache, output, names=None):
    if (metadata.get("tag_name") != tag or metadata.get("draft") is not False
            or metadata.get("prerelease") is not False):
        raise ValueError("cache requires the exact published stable release")
    assets = metadata.get("assets")
    if not isinstance(assets, list) or not assets:
        raise ValueError("release has no assets")
    by_name = {}
    for asset in assets:
        name = asset.get("name", "")
        if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name)
                or name in by_name):
            raise ValueError("unsafe or duplicate asset name")
        by_name[name] = asset
    selected = list(by_name) if names is None else list(names)
    if not selected or len(set(selected)) != len(selected):
        raise ValueError("invalid asset selection")
    cache, output = Path(cache).absolute(), Path(output).absolute()
    if cache.resolve() != cache or not cache.is_dir():
        raise ValueError("cache must be a real directory")
    if output.resolve() != output or not output.is_dir() or any(output.iterdir()):
        raise ValueError("output must be a fresh empty directory")
    for directory, forbidden in [(cache, 0o022), (output, 0o077)]:
        info = directory.stat()
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & forbidden:
            raise ValueError("cache must be owner-controlled; output must be private")
    checked = []
    for name in selected:
        asset = by_name.get(name, {})
        digest, size = asset.get("digest", ""), asset.get("size")
        if (asset.get("state") != "uploaded" or type(size) is not int or size <= 0
                or not isinstance(digest, str)
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
            raise ValueError("missing uploaded asset, size or server SHA256")
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        with os.fdopen(os.open(cache / name, flags), "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size != size:
                raise ValueError("cache asset must be a regular file of the published size")
            actual, count = hashlib.sha256(), 0
            # Exclusive creation prevents overwriting any existing work. Failed
            # copies remain diagnostic evidence; the caller exits before gates.
            with (output / name).open("xb") as destination:
                while chunk := source.read(1024 * 1024):
                    if count + len(chunk) > size:
                        raise ValueError("cached asset grew while copying")
                    destination.write(chunk)
                    actual.update(chunk)
                    count += len(chunk)
                destination.flush()
                os.fsync(destination.fileno())
        if count != size or "sha256:" + actual.hexdigest() != digest:
            raise ValueError("cached bytes do not match the published server digest")
        checked.append({"name": name, "size": count, "digest": digest})
    return {"tag": tag, "releaseID": metadata.get("id"), "assets": checked,
            "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "tag", "cache", "output", "receipt"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--asset", action="append")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.error("invalid repository")
    if not re.fullmatch(r"v[0-9]+(?:\.[0-9]+){2,3}", args.tag):
        parser.error("invalid tag")
    metadata = json.loads(subprocess.check_output(
        ["gh", "api", f"repos/{args.repo}/releases/tags/{args.tag}"],
        text=True, timeout=90))
    receipt = materialize(metadata, args.tag, args.cache, args.output, args.asset)
    receipt["repository"] = args.repo
    with Path(args.receipt).open("x") as stream:
        json.dump(receipt, stream, indent=2)
    print(f"Published cache verified: {args.tag}, {len(receipt['assets'])} assets")


if __name__ == "__main__":
    main()
