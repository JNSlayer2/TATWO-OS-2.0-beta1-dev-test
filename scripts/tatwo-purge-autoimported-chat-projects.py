#!/usr/bin/env python3
"""One-shot cleanup for Codex-session projects auto-promoted into Chat.

Default is dry-run. --apply copies the store to chat-repair-backups/ then
rewrites native-chat-threads.json. Standalone threads are never touched.

A project is auto-imported when every child thread is a Codex-mirror row:
id == codexSessionID, only a codex-exec handle (or the decoder-synthesized
equivalent), and no Tatwo-authored user messages / Goal / GitHub / CLI
sessions. Explicit user projects stay.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def login_home() -> Path:
    env_home = os.environ.get("TATWO_LOGIN_HOME")
    if env_home:
        return Path(env_home)
    try:
        import pwd

        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    except Exception:
        return Path.home()


def default_store_path() -> Path:
    if explicit := os.environ.get("TATWO_NATIVE_CHAT_STORE"):
        return Path(explicit)
    if support := os.environ.get("TATWO_APP_SUPPORT"):
        return Path(support) / "native-chat-threads.json"
    home_candidate = (
        Path.home()
        / "Library"
        / "Application Support"
        / "Tatwo Ultrawork"
        / "native-chat-threads.json"
    )
    if home_candidate.is_file():
        return home_candidate
    login_candidate = (
        login_home()
        / "Library"
        / "Application Support"
        / "Tatwo Ultrawork"
        / "native-chat-threads.json"
    )
    if login_candidate.is_file():
        return login_candidate
    return home_candidate


def nonempty(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    return text or None


def thread_has_user_message(thread: Any) -> bool:
    if not isinstance(thread, dict):
        return False
    bags = [thread.get("messages")]
    for discussion in thread.get("discussions") or []:
        if isinstance(discussion, dict):
            bags.append(discussion.get("messages"))
    for messages in bags:
        if not isinstance(messages, list):
            continue
        for message in messages:
            if not isinstance(message, dict):
                continue
            role = str(message.get("role") or "").strip().lower()
            text = str(message.get("text") or "").strip()
            if role in {"user", "human"} and text:
                return True
    return False


def is_autoimported_codex_project(project: Any) -> bool:
    if not isinstance(project, dict):
        return False
    if project.get("githubRepo"):
        return False
    if project.get("sessions"):
        return False
    threads = project.get("threads") or []
    if not isinstance(threads, list) or not threads:
        return False
    for thread in threads:
        if not isinstance(thread, dict):
            return False
        if thread_has_user_message(thread):
            return False
        if thread.get("discussions"):
            return False
        codex_id = nonempty(thread.get("codexSessionID"))
        if not codex_id:
            return False
        thread_id = str(thread.get("id") or "").strip().lower()
        if thread_id != codex_id.lower():
            return False
        handles = thread.get("adapterSessionHandles") or []
        if handles:
            adapters = {
                str(handle.get("adapterID") or "").strip()
                for handle in handles
                if isinstance(handle, dict)
            }
            adapters.discard("")
            # Resume handles attached after import are not user authorship.
            if adapters - {"codex-exec", "gateway-direct"}:
                return False
    return True


def classify(document: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    remove: list[dict[str, Any]] = []
    keep: list[dict[str, Any]] = []
    for project in document.get("projects") or []:
        if is_autoimported_codex_project(project):
            remove.append(project)
        else:
            keep.append(project)
    return keep, remove


def summarize_project(project: dict[str, Any]) -> str:
    name = project.get("name") or "(unnamed)"
    workdir = project.get("workdir") or ""
    threads = project.get("threads") or []
    updated = None
    for thread in threads:
        if isinstance(thread, dict):
            updated = thread.get("updatedAt") or thread.get("updatedISO") or updated
    return (
        f"  - name={name!r} threads={len(threads)} "
        f"updated={updated or '-'} workdir={workdir}"
    )


def write_json(path: Path, payload: Any) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(path)


def run_selftest() -> int:
    imported_id = "019f0000-0000-7000-8000-00000000aa18"
    fixture = {
        "schemaVersion": 1,
        "updatedAt": "2026-08-15T15:00:00Z",
        "threads": [
            {"id": "keep-standalone-1", "title": "user thread"},
            {"id": "keep-standalone-2", "title": "complaint thread"},
        ],
        "projects": [
            {
                "id": "keep-user",
                "name": "Tatwo UI loop fixture",
                "workdir": "/tmp/tatwo2-fixture",
                "threads": [{"id": "local-thread", "title": "N10 transcript visual check"}],
            },
            {
                "id": "drop-auto",
                "name": "example",
                "workdir": "/Users/example",
                "threads": [
                    {
                        "id": imported_id,
                        "title": "MacBook home session",
                        "codexSessionID": imported_id,
                        "adapterSessionHandles": [
                            {
                                "adapterID": "codex-exec",
                                "providerSessionID": imported_id,
                            }
                        ],
                    }
                ],
            },
        ],
    }
    keep, remove = classify(fixture)
    assert [project["id"] for project in keep] == ["keep-user"]
    assert [project["id"] for project in remove] == ["drop-auto"]
    print("selftest=passed keep=1 remove=1 standalone=2")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Dry-run (default) or apply cleanup of auto-imported Codex projects"
    )
    parser.add_argument("--store", type=Path, default=None, help="native-chat-threads.json")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write the cleaned store after copying a backup. Off by default.",
    )
    parser.add_argument("--selftest", action="store_true", help="Run the fixture classifier")
    args = parser.parse_args(argv)
    if args.selftest:
        return run_selftest()

    store = args.store or default_store_path()
    if not store.is_file():
        print(f"error: store not found: {store}", file=sys.stderr)
        return 2

    document = json.loads(store.read_text())
    if not isinstance(document, dict):
        print("error: store root is not an object", file=sys.stderr)
        return 2

    standalone = document.get("threads") or []
    keep, remove = classify(document)
    mode = "apply" if args.apply else "dry-run"
    print(f"mode={mode}")
    print(f"store={store}")
    print(
        f"counts projects={len(document.get('projects') or [])} "
        f"keep={len(keep)} remove={len(remove)} standalone={len(standalone)}"
    )
    print("KEEP")
    if keep:
        for project in keep:
            print(summarize_project(project))
    else:
        print("  (none)")
    print("REMOVE")
    if remove:
        for project in remove:
            print(summarize_project(project))
    else:
        print("  (none)")
    print("STANDALONE_UNTOUCHED")
    print(f"  count={len(standalone)}")

    if not args.apply:
        print("write=skipped (dry-run)")
        return 0

    backup_root = store.parent / "chat-repair-backups" / utc_stamp()
    backup_root.mkdir(parents=True, exist_ok=True)
    backup = backup_root / store.name
    shutil.copy2(store, backup)
    cleaned = dict(document)
    cleaned["projects"] = keep
    cleaned["updatedAt"] = (
        datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
            "+00:00", "Z"
        )
    )
    write_json(store, cleaned)
    print(f"backup={backup}")
    print(f"write={store}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
