#!/usr/bin/env python3
"""TatwoOsImageV1 — room live OS image, not git rebuild.

Version identity is the digest of the running artifacts (App bits +
gateway code + OS skillet.md). Git commit is a recipe, not a product.

author_model notes:
- Grok drafted the consumer/publisher split
- Fable-5 required: room publish (no live scrape), one version leg,
  N-1 rollback, honest data-plane naming, no fake iCloud
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "TatwoOsImageManifestV1"
DEFAULT_APP = Path("/Applications/Tatwo Ultrawork.app")
DEFAULT_GATEWAY_LOCAL = Path(
    os.path.expanduser(
        "~/Library/Application Support/Tatwo Ultrawork/skills-runtime/codex-app-model-gateway"
    )
)
DEFAULT_OS_SKILL_LOCAL = Path(
    os.path.expanduser(
        "~/Library/Application Support/Tatwo Ultrawork/skills-runtime/skillet"
    )
)
DEFAULT_GATEWAY_ROOM = Path.home() / "Library/Application Support/tatwo2/skills/codex-app-model-gateway"
DEFAULT_OS_SKILL_ROOM = Path.home() / "Library/Application Support/tatwo2/skills/skillet"
DEFAULT_STATE = Path(
    os.path.expanduser("~/Library/Application Support/Tatwo Ultrawork/os-image")
)
ADAPTER_RELATIVE = (
    "Contents/Resources/TatwoUltrawork_TatwoUltraworkMac.bundle/"
    "Contents/Resources/tatwo-direct-gateway-chat.mjs"
)
ADAPTER_RELATIVE_FLAT = (
    "Contents/Resources/TatwoUltrawork_TatwoUltraworkMac.bundle/"
    "tatwo-direct-gateway-chat.mjs"
)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_adapter(app: Path) -> Path | None:
    nested = app / ADAPTER_RELATIVE
    if nested.is_file():
        return nested
    flat = app / ADAPTER_RELATIVE_FLAT
    if flat.is_file():
        return flat
    matches = list(app.rglob("tatwo-direct-gateway-chat.mjs"))
    return matches[0] if matches else None


def plist_value(app: Path, key: str) -> str:
    info = app / "Contents/Info.plist"
    if not info.is_file():
        return ""
    try:
        return subprocess.check_output(
            ["defaults", "read", str(info), key],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def capture_roots(app: Path, gateway: Path, os_skill: Path) -> dict:
    files = []

    def add(surface: str, name: str, path: Path) -> None:
        if not path.is_file():
            files.append(
                {
                    "surface": surface,
                    "name": name,
                    "path": str(path),
                    "sha256": None,
                    "missing": True,
                    "bytes": 0,
                }
            )
            return
        files.append(
            {
                "surface": surface,
                "name": name,
                "path": str(path),
                "sha256": sha256_file(path),
                "missing": False,
                "bytes": path.stat().st_size,
            }
        )

    executable = app / "Contents/MacOS/TatwoUltraworkMac"
    add("app", "executable", executable)
    adapter = find_adapter(app)
    add("app", "adapter", adapter if adapter else app / ADAPTER_RELATIVE)
    add("gateway", "server", gateway / "runtime/server.js")
    add("gateway", "continuation", gateway / "runtime/tatwo-continuation.js")
    add("osSkill", "skill", os_skill / "SKILL.md")
    return {
        "app": {
            "version": plist_value(app, "CFBundleShortVersionString"),
            "build": plist_value(app, "CFBundleVersion"),
            "bundleId": plist_value(app, "CFBundleIdentifier"),
        },
        "files": files,
    }


def image_id_from_files(files: list[dict]) -> str:
    lines = []
    for item in files:
        digest = item.get("sha256") or "missing"
        lines.append(f"{item['surface']}.{item['name']}={digest}")
    payload = "\n".join(sorted(lines)).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def build_manifest(role: str, host: str, captured: dict) -> dict:
    files = captured["files"]
    return {
        "schema": SCHEMA,
        "role": role,
        "host": host,
        "capturedAt": utc_now(),
        "imageId": image_id_from_files(files),
        "display": captured["app"],
        "files": files,
        "trust": {
            "transport": "ssh_host_identity_plus_content_hash",
            "temporary": True,
            "not": "code_signing_infrastructure",
        },
    }


def compare_manifests(local: dict, remote: dict) -> dict:
    local_map = {
        f"{item['surface']}.{item['name']}": item for item in local.get("files", [])
    }
    remote_map = {
        f"{item['surface']}.{item['name']}": item for item in remote.get("files", [])
    }
    keys = sorted(set(local_map) | set(remote_map))
    surfaces = {}
    for key in keys:
        left = local_map.get(key)
        right = remote_map.get(key)
        left_hash = left.get("sha256") if left else None
        right_hash = right.get("sha256") if right else None
        if left is None:
            state = "local_missing"
        elif right is None:
            state = "remote_missing"
        elif left.get("missing") or right.get("missing"):
            state = "missing"
        elif left_hash == right_hash:
            state = "equal"
        else:
            state = "diverged"
        surface = key.split(".", 1)[0]
        surfaces.setdefault(surface, {})[key] = {
            "state": state,
            "local": left_hash,
            "remote": right_hash,
        }
    surface_state = {
        name: (
            "equal"
            if all(item["state"] == "equal" for item in values.values())
            else "diverged"
        )
        for name, values in surfaces.items()
    }
    return {
        "localImageId": local.get("imageId"),
        "remoteImageId": remote.get("imageId"),
        "aligned": local.get("imageId") == remote.get("imageId")
        and bool(local.get("imageId")),
        "surfaces": surface_state,
        "files": surfaces,
    }


def atomic_write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(path)


def publish(args: argparse.Namespace) -> int:
    app = Path(args.app)
    gateway = Path(args.gateway)
    os_skill = Path(args.os_skill)
    export = Path(args.export)
    captured = capture_roots(app, gateway, os_skill)
    manifest = build_manifest("room-live", os.uname().nodename, captured)
    if any(item["missing"] for item in captured["files"]):
        missing = [item["path"] for item in captured["files"] if item["missing"]]
        print("error: live image incomplete:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 2

    staging = export.parent / f".staging-{os.getpid()}"
    if staging.exists():
        shutil.rmtree(staging)
    blobs = staging / "blobs"
    blobs.mkdir(parents=True)
    for item in captured["files"]:
        dest = blobs / item["sha256"]
        if not dest.exists():
            shutil.copy2(item["path"], dest)
            dest.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
    atomic_write_json(staging / "manifest.json", manifest)
    export.parent.mkdir(parents=True, exist_ok=True)
    previous = export.parent / "previous"
    if export.exists():
        if previous.exists():
            shutil.rmtree(previous)
        export.replace(previous)
    staging.replace(export)
    print(f"published imageId={manifest['imageId']}")
    print(f"export={export}")
    return 0


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def status_cmd(args: argparse.Namespace) -> int:
    local = build_manifest(
        "local-running",
        os.uname().nodename,
        capture_roots(Path(args.app), Path(args.gateway), Path(args.os_skill)),
    )
    staged_path = Path(args.state) / "staged.json"
    staged = load_json(staged_path) if staged_path.is_file() else None
    remote = None
    if args.remote_manifest and Path(args.remote_manifest).is_file():
        remote = load_json(Path(args.remote_manifest))
    report = {
        "schema": "TatwoOsImageStatusV1",
        "observedAt": utc_now(),
        "running": {
            "imageId": local["imageId"],
            "display": local["display"],
        },
        "primary": {
            "imageId": remote.get("imageId") if remote else None,
            "display": remote.get("display") if remote else None,
        },
        "staged": {
            "imageId": staged.get("imageId") if staged else None,
            "display": staged.get("display") if staged else None,
        },
    }
    if remote:
        report["compare"] = compare_manifests(local, remote)
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if remote and not report["compare"]["aligned"]:
        return 3
    return 0


def verify_export(export: Path, manifest: dict) -> None:
    blobs = export / "blobs"
    for item in manifest["files"]:
        digest = item["sha256"]
        blob = blobs / digest
        if not blob.is_file():
            raise RuntimeError(f"missing blob {digest} for {item['name']}")
        actual = sha256_file(blob)
        if actual != digest:
            raise RuntimeError(
                f"blob mismatch {item['name']}: expected {digest} actual {actual}"
            )


def apply_blob(blob: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(f".{dest.name}.{os.getpid()}.tmp")
    shutil.copy2(blob, tmp)
    tmp.replace(dest)


def gateway_busy() -> bool:
    try:
        output = subprocess.check_output(
            ["curl", "-fsS", "--max-time", "2", "http://127.0.0.1:4177/healthz"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        return False
    routes = payload.get("routes") or {}
    for route in routes.values():
        if isinstance(route, dict) and route.get("in_flight"):
            return True
    return False


def app_running() -> bool:
    return subprocess.call(
        ["pgrep", "-x", "TatwoUltraworkMac"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ) == 0


def gateway_label() -> str:
    explicit = os.environ.get("MODEL_GATEWAY_LABEL")
    if explicit:
        return explicit
    current = "com.tatwo.codex-model-gateway"
    # Discover old per-user registrations without persisting any owner's identity.
    try:
        output = subprocess.check_output(["launchctl", "list"], text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return current
    labels = {
        fields[2] for line in output.splitlines()
        if len(fields := line.split()) == 3
        and re.fullmatch(r"com\.[^.]+\.codex-model-gateway", fields[2])
    }
    if current in labels or not labels:
        return current
    if len(labels) != 1:
        raise RuntimeError("Multiple gateways registered; set MODEL_GATEWAY_LABEL")
    return labels.pop()


def kickstart_gateway() -> None:
    if os.environ.get("TATWO_OS_IMAGE_SKIP_HEALTHZ") == "1":
        return
    uid = os.getuid()
    label = f"gui/{uid}/{gateway_label()}"
    subprocess.call(
        ["launchctl", "kickstart", "-k", label],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def healthz_runtime_sha() -> str | None:
    try:
        output = subprocess.check_output(
            ["curl", "-fsS", "--max-time", "5", "http://127.0.0.1:4177/healthz"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        payload = json.loads(output)
        return ((payload.get("runtime_source") or {}).get("sha256"))
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError):
        return None


def apply_runtime(args: argparse.Namespace, export: Path, manifest: dict) -> None:
    state = Path(args.state)
    previous = state / "previous-runtime"
    if previous.exists():
        shutil.rmtree(previous)
    previous.mkdir(parents=True)
    gateway = Path(args.gateway)
    os_skill = Path(args.os_skill)
    backups = {
        "server": gateway / "runtime/server.js",
        "continuation": gateway / "runtime/tatwo-continuation.js",
        "skill": os_skill / "SKILL.md",
    }
    for name, path in backups.items():
        if path.is_file():
            shutil.copy2(path, previous / name)

    blobs = export / "blobs"
    by_name = {item["name"]: item for item in manifest["files"]}
    apply_blob(blobs / by_name["server"]["sha256"], backups["server"])
    apply_blob(blobs / by_name["continuation"]["sha256"], backups["continuation"])
    apply_blob(blobs / by_name["skill"]["sha256"], backups["skill"])

    if sha256_file(backups["server"]) != by_name["server"]["sha256"]:
        raise RuntimeError("gateway server hash mismatch after apply")
    if sha256_file(backups["continuation"]) != by_name["continuation"]["sha256"]:
        raise RuntimeError("gateway continuation hash mismatch after apply")
    if sha256_file(backups["skill"]) != by_name["skill"]["sha256"]:
        raise RuntimeError("os skill hash mismatch after apply")

    kickstart_gateway()
    if os.environ.get("TATWO_OS_IMAGE_SKIP_HEALTHZ") == "1":
        return
    observed = None
    for _ in range(20):
        observed = healthz_runtime_sha()
        if observed == by_name["server"]["sha256"]:
            return
        subprocess.call(["sleep", "0.25"])
    raise RuntimeError(
        f"gateway healthz runtime hash mismatch: expected "
        f"{by_name['server']['sha256']} observed {observed}"
    )


def rollback_runtime(args: argparse.Namespace) -> int:
    previous = Path(args.state) / "previous-runtime"
    if not previous.is_dir():
        print("error: no previous-runtime image", file=sys.stderr)
        return 2
    gateway = Path(args.gateway)
    os_skill = Path(args.os_skill)
    mapping = {
        "server": gateway / "runtime/server.js",
        "continuation": gateway / "runtime/tatwo-continuation.js",
        "skill": os_skill / "SKILL.md",
    }
    for name, dest in mapping.items():
        src = previous / name
        if src.is_file():
            apply_blob(src, dest)
    kickstart_gateway()
    print("rolled_back=previous-runtime")
    return 0


def apply_cmd(args: argparse.Namespace) -> int:
    export = Path(args.export)
    manifest = load_json(export / "manifest.json")
    if manifest.get("schema") != SCHEMA:
        print("error: unsupported image schema", file=sys.stderr)
        return 2
    verify_export(export, manifest)
    local = build_manifest(
        "local-running",
        os.uname().nodename,
        capture_roots(Path(args.app), Path(args.gateway), Path(args.os_skill)),
    )
    diff = compare_manifests(local, manifest)
    atomic_write_json(Path(args.state) / "last-compare.json", diff)
    if diff["aligned"]:
        print(f"already_aligned imageId={manifest['imageId']}")
        return 0

    if diff["surfaces"].get("gateway") == "diverged" or diff["surfaces"].get("osSkill") == "diverged":
        if gateway_busy() and not args.force:
            print("deferred=runtime reason=gateway_busy")
        else:
            try:
                apply_runtime(args, export, manifest)
                print("applied=runtime")
            except Exception as error:
                print(f"error: runtime apply failed: {error}", file=sys.stderr)
                rollback_runtime(args)
                return 2

    if diff["surfaces"].get("app") == "diverged":
        atomic_write_json(Path(args.state) / "staged.json", manifest)
        print(f"staged=app imageId={manifest['imageId']}")
        if args.activate_app:
            if app_running() and not args.force:
                print("deferred=app reason=app_running")
            else:
                print("activate_app=required_external_activator")
    print(f"remote_imageId={manifest['imageId']}")
    print(f"local_imageId={local['imageId']}")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="tatwo-os-image")
    parser.add_argument("--app", default=str(DEFAULT_APP))
    parser.add_argument("--gateway", default=str(DEFAULT_GATEWAY_LOCAL))
    parser.add_argument("--os-skill", default=str(DEFAULT_OS_SKILL_LOCAL))
    parser.add_argument("--state", default=str(DEFAULT_STATE))
    parser.add_argument("--export", default="")
    parser.add_argument("--remote-manifest", default="")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--activate-app", action="store_true")
    parser.add_argument(
        "command",
        choices=["publish", "status", "apply", "rollback-runtime", "selftest-compare"],
    )
    args = parser.parse_args(argv)
    if not args.export:
        args.export = str(Path(args.state) / "export")
    return args


def selftest_compare() -> int:
    left = {
        "imageId": "aaa",
        "files": [
            {"surface": "gateway", "name": "server", "sha256": "1"},
            {"surface": "app", "name": "executable", "sha256": "2"},
        ],
    }
    right = {
        "imageId": "bbb",
        "files": [
            {"surface": "gateway", "name": "server", "sha256": "1"},
            {"surface": "app", "name": "executable", "sha256": "9"},
        ],
    }
    result = compare_manifests(left, right)
    assert result["aligned"] is False
    assert result["surfaces"]["gateway"] == "equal"
    assert result["surfaces"]["app"] == "diverged"
    same = compare_manifests(left, {"imageId": "aaa", "files": left["files"]})
    # imageId compare uses computed? here we passed imageId directly
    same["aligned"] = left["imageId"] == "aaa"
    assert same["surfaces"]["gateway"] == "equal"
    print("selftest-compare=passed")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.command == "publish":
        if args.gateway == str(DEFAULT_GATEWAY_LOCAL) and DEFAULT_GATEWAY_ROOM.is_dir():
            args.gateway = str(DEFAULT_GATEWAY_ROOM)
        if args.os_skill == str(DEFAULT_OS_SKILL_LOCAL) and DEFAULT_OS_SKILL_ROOM.is_dir():
            args.os_skill = str(DEFAULT_OS_SKILL_ROOM)
        return publish(args)
    if args.command == "status":
        return status_cmd(args)
    if args.command == "apply":
        return apply_cmd(args)
    if args.command == "rollback-runtime":
        return rollback_runtime(args)
    if args.command == "selftest-compare":
        return selftest_compare()
    return 2


if __name__ == "__main__":
    sys.exit(main())
