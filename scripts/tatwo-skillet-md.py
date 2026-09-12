#!/usr/bin/env python3
"""OS skillet.md — host unifies, nobody overwrites vendor SKILL.md.

Law:
  The OS common skill is skillet.md on the primary device.
  Each AI keeps its own system SKILL.md.
  Secondaries submit skillet.md proposals. The host integrates.
  This tool never writes tatwo-ultrawork/SKILL.md or any other vendor skill.
  This tool never dumps the skillet store into OS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SUBMIT_SCHEMA = "TatwoOsSkilletSubmitV1"
SKILL_NAME = "skillet"
FRONTMATTER = """---
name: skillet
description: OS 常用技能（skillet.md）。使用者說 $skillet、/skillet、OS skillet、常用 skill、或要讀主設備統整的 OS skill 時使用。各家系統 SKILL.md 仍保留；本檔不是把全部 skill 灌進 OS。
user-invocable: true
when-to-use: "$skillet /skillet OS skillet 常用 skill"
---
"""
SEED_BODY = """# OS skillet

主設備統整的 OS 常用技能。各家 AI 保有自己系統的 `SKILL.md`，但必須能用快捷鍵讀到這一份。

## 快捷鍵

| 模型 | 快捷 | 目錄 |
|---|---|---|
| Codex | `$skillet` | `~/.codex/skills/skillet/SKILL.md` |
| Claude | `$skillet` | `~/.claude/skills/skillet/SKILL.md` |
| Grok | `/skillet` | `~/.grok/skills/skillet/SKILL.md` |

描述匹配也可自動找到。不要把各家雜亂 skill 整包灌進來。

## 統一法

- 統一標準是主設備的 `skillet.md`。
- 跟資料同步一樣：附設送提案，主機整合，不是覆蓋。
- 各家系統 `SKILL.md`（含 `$tatwo-ultrawork`）不得被本通道改寫。
- skillet store / 大量現成 skill 不得灌進本檔。人只把需要的常用放進來。

## 與產品 skill 的界線

`$tatwo-ultrawork` 仍是 TATWO Work OS 產品 skill。本檔是 OS 常用層，取代 OS 映像裡舊的「單一 OS skill = tatwo-ultrawork/SKILL.md」那個槽位。

## 常用

（人整理。主機 unify 只歸檔提案，不自動改寫本節。）
"""


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_device_name(raw: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", raw.strip())
    return cleaned.strip(".-") or "device"


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text)
    tmp.replace(path)


def write_json(path: Path, payload: Any) -> None:
    write_text(path, json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


def expand(path: str) -> Path:
    return Path(os.path.expanduser(path)).resolve()


def default_support() -> Path:
    return expand("~/Library/Application Support/Tatwo Ultrawork")


def default_os_root() -> Path:
    env = os.environ.get("TATWO_OS_ROOT", "").strip()
    if env:
        return expand(env)
    return expand("~/Library/Application Support/Tatwo Ultrawork/work-os")


def canonical_path(args: argparse.Namespace) -> Path:
    if args.canonical:
        return expand(args.canonical)
    env = os.environ.get("TATWO_OS_SKILLET_MD", "").strip()
    if env:
        return expand(env)
    os_root = Path(args.os_root)
    if (os_root / "os.md").is_file():
        return os_root / "skillet.md"
    return Path(args.support) / "skillet-md" / "skillet.md"


def render_document(body: str | None = None) -> str:
    text = (body if body is not None else SEED_BODY).strip() + "\n"
    if text.lstrip().startswith("---"):
        return text
    return FRONTMATTER + "\n" + text


def strip_frontmatter(text: str) -> str:
    if not text.startswith("---"):
        return text
    rest = text[3:]
    end = rest.find("\n---")
    if end < 0:
        return text
    return rest[end + 4 :].lstrip("\n")


def is_skillet_target(path: Path) -> bool:
    name = path.name
    if name == "skillet.md":
        return True
    if name == "SKILL.md" and path.parent.name == SKILL_NAME:
        return True
    return False


def refuse_if_unsafe(path: Path) -> None:
    resolved = path if path.is_absolute() else path.resolve()
    if not is_skillet_target(resolved):
        raise RuntimeError(f"refused non-skillet path: {resolved}")
    parts = [part.lower() for part in resolved.parts]
    if "tatwo-ultrawork" in parts:
        raise RuntimeError(f"refused tatwo-ultrawork path: {resolved}")


def wrapper_paths(args: argparse.Namespace) -> list[Path]:
    roots: list[Path] = []
    runtime = os.environ.get("TATWO_SKILLS_RUNTIME_ROOT", "").strip()
    roots.append(
        expand(runtime)
        if runtime
        else Path(args.support) / "skills-runtime"
    )
    warehouse = os.environ.get("TATWO_SKILLET_SOURCE_ROOT", "").strip()
    if warehouse:
        roots.append(expand(warehouse))
    extra = os.environ.get("TATWO_SKILLET_MD_WRAPPERS", "").strip()
    paths: list[Path] = []
    for root in roots:
        paths.append(root / SKILL_NAME / "SKILL.md")
    use_defaults = os.environ.get("TATWO_SKILLET_MD_NO_DEFAULT_WRAPPERS", "").strip() != "1"
    if use_defaults:
        grok = expand("~/.grok/skills/skillet/SKILL.md")
        paths.append(grok)
        isolated = expand(
            "~/.tatwo-agent-homes/grok-codex-gateway/.grok/skills/skillet/SKILL.md"
        )
        if isolated.parent.parent.exists() or isolated.is_file():
            paths.append(isolated)
    if extra:
        for item in extra.split(":"):
            item = item.strip()
            if item:
                paths.append(expand(item))
    if args.wrappers:
        for item in args.wrappers:
            paths.append(expand(item))
    unique: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(path)
    return unique


def ensure_seed(path: Path) -> str:
    if path.is_file():
        return path.read_text()
    text = render_document()
    refuse_if_unsafe(path)
    write_text(path, text)
    return text


def mirror_wrappers(canonical: Path, wrappers: list[Path]) -> list[str]:
    text = canonical.read_text()
    updated: list[str] = []
    for dest in wrappers:
        if dest.resolve() == canonical.resolve():
            continue
        refuse_if_unsafe(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.is_file() and dest.read_text() == text:
            continue
        write_text(dest, text)
        updated.append(str(dest))
    return updated


def fingerprint_other_skills(roots: list[Path]) -> dict[str, str]:
    out: dict[str, str] = {}
    for root in roots:
        if not root.is_dir():
            continue
        for skill_md in root.rglob("SKILL.md"):
            if skill_md.parent.name == SKILL_NAME:
                continue
            digest = sha256_file(skill_md)
            if digest:
                out[str(skill_md)] = digest
    return out


def package_cmd(args: argparse.Namespace) -> int:
    canonical = canonical_path(args)
    text = ensure_seed(canonical)
    export = expand(args.export)
    if export.exists():
        shutil.rmtree(export)
    export.mkdir(parents=True)
    write_text(export / "skillet.md", text)
    payload = {
        "schema": SUBMIT_SCHEMA,
        "device": safe_device_name(args.device),
        "submittedAt": utc_now(),
        "sha256": sha256_bytes(text.encode()),
        "bytes": len(text.encode()),
        "canonical": str(canonical),
    }
    payload["submitId"] = sha256_bytes(
        json.dumps(payload, sort_keys=True).encode()
    )
    write_json(export / "manifest.json", payload)
    print(f"packaged submitId={payload['submitId']} bytes={payload['bytes']}")
    return 0


def unify_cmd(args: argparse.Namespace) -> int:
    if os.environ.get("TATWO_OS_IMAGE_CONSUMER", "").strip() == "1" and not args.force:
        print("error: consumer cannot local-unify skillet.md", file=sys.stderr)
        return 2
    if os.environ.get("TATWO_DATA_SYNC_ROLE", "").strip() == "secondary" and not args.force:
        print("error: secondary cannot local-unify skillet.md", file=sys.stderr)
        return 2
    canonical = canonical_path(args)
    inbox = expand(args.inbox)
    ensure_seed(canonical)
    before = canonical.read_text()
    archived_root = Path(args.support) / "skillet-md" / "archived"
    index_path = Path(args.support) / "skillet-md" / "INDEX.md"
    proposals: list[dict[str, Any]] = []
    if inbox.is_dir():
        for manifest in sorted(inbox.rglob("manifest.json")):
            bundle = manifest.parent
            skillet = bundle / "skillet.md"
            if not skillet.is_file():
                continue
            try:
                meta = json.loads(manifest.read_text())
            except json.JSONDecodeError:
                meta = {}
            dest = archived_root / utc_now().replace(":", "") / bundle.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            device_dir = bundle.parent
            shutil.move(str(bundle), dest)
            body = (dest / "skillet.md").read_text()
            proposals.append(
                {
                    "device": meta.get("device") or dest.parent.name,
                    "submitId": meta.get("submitId") or dest.name,
                    "sha256": sha256_bytes(body.encode()),
                    "archived": str(dest),
                    "sameAsCanonical": body == before,
                }
            )
            if device_dir.is_dir() and not any(device_dir.iterdir()):
                device_dir.rmdir()
    if proposals:
        lines = [
            "# OS skillet proposals",
            "",
            "Host archives proposals here. Curated body in skillet.md is not auto-replaced.",
            "",
        ]
        if index_path.is_file():
            existing = index_path.read_text().rstrip()
            if existing:
                lines = [existing, "", f"## {utc_now()}", ""]
        else:
            lines.append(f"## {utc_now()}")
            lines.append("")
        for item in proposals:
            lines.append(
                f"- `{item['device']}` `{item['submitId'][:12]}` "
                f"{'same' if item['sameAsCanonical'] else 'diff'} `{item['archived']}`"
            )
        write_text(index_path, "\n".join(lines) + "\n")
    after = canonical.read_text()
    if after != before:
        print("error: unify must not rewrite canonical skillet.md", file=sys.stderr)
        return 2
    mirrored = mirror_wrappers(canonical, wrapper_paths(args))
    print(
        json.dumps(
            {
                "ok": True,
                "canonical": str(canonical),
                "canonicalSha256": sha256_file(canonical),
                "submitCount": len(proposals),
                "proposals": proposals,
                "mirrored": mirrored,
                "canonicalUntouched": True,
            },
            ensure_ascii=False,
        )
    )
    return 0


def install_cmd(args: argparse.Namespace) -> int:
    canonical = canonical_path(args)
    ensure_seed(canonical)
    mirrored = mirror_wrappers(canonical, wrapper_paths(args))
    print(
        json.dumps(
            {
                "ok": True,
                "canonical": str(canonical),
                "canonicalSha256": sha256_file(canonical),
                "mirrored": mirrored,
            },
            ensure_ascii=False,
        )
    )
    return 0


def pull_cmd(args: argparse.Namespace) -> int:
    source = expand(args.source) if args.source else canonical_path(args)
    if not source.is_file():
        print(f"error: missing skillet source {source}", file=sys.stderr)
        return 2
    refuse_if_unsafe(source)
    dest = canonical_path(args)
    refuse_if_unsafe(dest)
    text = source.read_text()
    write_text(dest, text)
    mirrored = mirror_wrappers(dest, wrapper_paths(args))
    print(
        json.dumps(
            {
                "ok": True,
                "pulled": str(source),
                "canonical": str(dest),
                "canonicalSha256": sha256_file(dest),
                "mirrored": mirrored,
            },
            ensure_ascii=False,
        )
    )
    return 0


def status_cmd(args: argparse.Namespace) -> int:
    canonical = canonical_path(args)
    wrappers = wrapper_paths(args)
    print(
        json.dumps(
            {
                "canonical": str(canonical),
                "exists": canonical.is_file(),
                "sha256": sha256_file(canonical),
                "wrappers": [
                    {
                        "path": str(path),
                        "exists": path.is_file(),
                        "sha256": sha256_file(path),
                    }
                    for path in wrappers
                ],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def selftest(args: argparse.Namespace) -> int:
    work = Path(args.support)
    host_skill = work / "vendor" / "tatwo-ultrawork" / "SKILL.md"
    other = work / "vendor" / "other-skill" / "SKILL.md"
    write_text(host_skill, "VENDOR_TATWO\n")
    write_text(other, "VENDOR_OTHER\n")
    before = fingerprint_other_skills([work / "vendor"])
    args.canonical = str(work / "os" / "skillet.md")
    args.os_root = str(work / "os")
    write_text(work / "os" / "os.md", "# os\n")
    args.wrappers = [
        str(work / "runtime" / "skillet" / "SKILL.md"),
        str(work / "warehouse" / "skillet" / "SKILL.md"),
    ]
    args.inbox = str(work / "inbox")
    install_cmd(args)
    export = work / "submit"
    args.export = str(export)
    args.device = "laptop"
    package_cmd(args)
    inbox_bundle = Path(args.inbox) / "laptop" / "abc"
    shutil.copytree(export, inbox_bundle)
    rc = unify_cmd(args)
    if rc != 0:
        print("error: selftest unify failed", file=sys.stderr)
        return 2
    after = fingerprint_other_skills([work / "vendor"])
    if after != before:
        print("error: vendor skills changed", file=sys.stderr)
        return 2
    if host_skill.read_text() != "VENDOR_TATWO\n":
        print("error: tatwo-ultrawork overwritten", file=sys.stderr)
        return 2
    skillet = Path(args.canonical).read_text()
    if "OS skillet" not in skillet:
        print("error: canonical missing seed", file=sys.stderr)
        return 2
    wrapper = Path(args.wrappers[0]).read_text()
    if wrapper != skillet:
        print("error: wrapper drifted", file=sys.stderr)
        return 2
    try:
        refuse_if_unsafe(host_skill)
    except RuntimeError:
        pass
    else:
        print("error: unsafe path accepted", file=sys.stderr)
        return 2
    print("selftest=passed")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="tatwo-skillet-md")
    parser.add_argument("--support", default=str(default_support()))
    parser.add_argument("--os-root", default=str(default_os_root()))
    parser.add_argument("--canonical", default="")
    parser.add_argument("--export", default="")
    parser.add_argument("--inbox", default="")
    parser.add_argument("--source", default="")
    parser.add_argument("--device", default=os.environ.get("TATWO_DEVICE_NAME", "device"))
    parser.add_argument("--wrappers", action="append", default=[])
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "command",
        choices=["package", "unify", "install", "pull", "status", "selftest"],
    )
    args = parser.parse_args(argv)
    args.support = str(expand(args.support))
    args.os_root = str(expand(args.os_root))
    if not args.inbox:
        args.inbox = str(Path(args.support) / "skillet-md" / "inbox")
    if not args.export:
        args.export = str(Path(args.support) / "skillet-md" / "outgoing" / "local")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.command == "package":
        return package_cmd(args)
    if args.command == "unify":
        return unify_cmd(args)
    if args.command == "install":
        return install_cmd(args)
    if args.command == "pull":
        return pull_cmd(args)
    if args.command == "status":
        return status_cmd(args)
    if args.command == "selftest":
        import tempfile

        args.support = tempfile.mkdtemp(prefix="tatwo-skillet-md-")
        os.environ["TATWO_SKILLET_MD_NO_DEFAULT_WRAPPERS"] = "1"
        os.environ.pop("TATWO_SKILLS_RUNTIME_ROOT", None)
        os.environ.pop("TATWO_SKILLET_SOURCE_ROOT", None)
        try:
            return selftest(args)
        finally:
            shutil.rmtree(args.support, ignore_errors=True)
    return 2


if __name__ == "__main__":
    sys.exit(main())
