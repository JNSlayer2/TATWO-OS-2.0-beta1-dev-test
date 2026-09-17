#!/usr/bin/env python3
"""Pinned official helper: verify original asset digest, then sign inside-out.

No packaging command is run by W80b tests. prepare/finalize are explicit build steps.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request

VERSION = "v0.50.5.0"
REPO = "garrytan/gbrain"
ASSET = "gbrain-darwin-arm64"
DIGEST = "sha256:a53f991cec693f7d88b96953c965bde111d6a546c5771f82ef5ca2f9346f7f99"
API = f"https://api.github.com/repos/{REPO}/releases/tags/{VERSION}"


def sha256(file):
    digest = hashlib.sha256()
    with Path(file).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, dest):
    request = urllib.request.Request(url, headers={"User-Agent": "TATWO-build"})
    temp = dest.with_suffix(dest.suffix + ".partial")
    with urllib.request.urlopen(request, timeout=120) as response, temp.open("wb") as output:
        shutil.copyfileobj(response, output)
    temp.replace(dest)


def prepare(app, cache):
    cache.mkdir(parents=True, exist_ok=True)
    metadata = cache / "release.json"
    # Resolve official metadata on every build; offline/stale metadata is not proof.
    download(API, metadata)
    release = json.loads(metadata.read_text())
    if release.get("tag_name") != VERSION:
        raise RuntimeError("release version mismatch")
    asset = next(a for a in release["assets"] if a["name"] == ASSET)
    if asset.get("digest") != DIGEST:
        raise RuntimeError("official digest differs from pinned digest")
    binary = cache / ASSET
    if not binary.exists() or "sha256:" + sha256(binary) != DIGEST:
        download(asset["browser_download_url"], binary)
    if "sha256:" + sha256(binary) != DIGEST or binary.stat().st_size != asset["size"]:
        raise RuntimeError("asset digest/size mismatch")
    license_file = cache / "LICENSE"
    download(f"https://raw.githubusercontent.com/{REPO}/{VERSION}/LICENSE", license_file)
    if "MIT License" not in license_file.read_text():
        raise RuntimeError("missing upstream MIT license")
    helper = app / "Contents/Helpers/gbrain"
    licenses = app / "Contents/Resources/gbrain"
    helper.parent.mkdir(parents=True, exist_ok=True)
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(binary, helper)
    helper.chmod(0o755)
    shutil.copyfile(license_file, licenses / "LICENSE")
    manifest = {"repository": REPO, "version": VERSION, "asset": ASSET,
                "assetID": asset["id"], "officialDigest": asset["digest"],
                "originalSHA256": sha256(binary), "size": asset["size"],
                "helper": "Contents/Helpers/gbrain", "signedSHA256": None}
    (licenses / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def finalize(app, identity):
    helper = app / "Contents/Helpers/gbrain"
    manifest_file = app / "Contents/Resources/gbrain/manifest.json"
    manifest = json.loads(manifest_file.read_text())
    if manifest["officialDigest"] != DIGEST or "sha256:" + sha256(helper) != DIGEST:
        raise RuntimeError("helper changed before signing")
    # Bun's upstream runtime/JIT entitlements survive, but signing identity is ours.
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none",
                    "--preserve-metadata=entitlements,flags,runtime", str(helper)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(helper)], check=True)
    manifest["signedSHA256"] = sha256(helper)
    manifest_file.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    mode, bundle = sys.argv[1:3]
    if mode == "prepare":
        base = os.environ.get("TATWO2_DOWNLOAD_CACHE") or os.environ.get("TMPDIR")
        if not base:
            raise RuntimeError("set TMPDIR or TATWO2_DOWNLOAD_CACHE on external staging volume")
        prepare(Path(bundle), Path(base) / "tatwo-gbrain-downloads" / VERSION)
    elif mode == "finalize":
        finalize(Path(bundle), sys.argv[3])
    else:
        raise SystemExit("expected prepare or finalize")
