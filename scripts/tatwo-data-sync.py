#!/usr/bin/env python3
"""Submit-to-host user-data sync. Not Apple iCloud. Not host overwrite.

Law:
  Secondaries package local chat data and send it to the host inbox.
  The host unifies concurrent edits into the host store.
  A secondary's live files are never overwritten by this tool.

Both machines may be optimizing at the same time. The host's job is
to merge by identity, not to declare itself the only copy.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SUBMIT_SCHEMA = "TatwoDeviceDataSubmitV1"
DEFAULT_SUPPORT = Path(
    os.path.expanduser("~/Library/Application Support/Tatwo Ultrawork")
)
BUNDLE_FILES = (
    "native-chat-threads.json",
    "chat-transcript-journal-v1.json",
)
LIST_KEYS = frozenset(
    {
        "projects",
        "threads",
        "sessions",
        "discussions",
        "adapterSessionHandles",
        "gatewayConversationHandles",
        "loopsSessions",
        "events",
        "turns",
        "items",
        "eventIDs",
        "messages",
        "subAgents",
    }
)
TIME_KEYS = (
    "updatedAt",
    "updatedISO",
    "updated_iso",
    "occurredAt",
    "createdAt",
    "createdISO",
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


def safe_device_name(raw: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", raw.strip())
    return cleaned.strip(".-") or "device"


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(path)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def parse_time(value: Any) -> float | None:
    if value is None or value is False:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        if number > 1e12:
            return number / 1000.0
        return number
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            return datetime.fromisoformat(text).timestamp()
        except ValueError:
            try:
                return parse_time(float(text))
            except ValueError:
                return None
    return None


def record_time(obj: Any) -> float | None:
    if not isinstance(obj, dict):
        return None
    for key in TIME_KEYS:
        stamp = parse_time(obj.get(key))
        if stamp is not None:
            return stamp
    return None


def identity(item: Any) -> tuple[str, str]:
    if not isinstance(item, dict):
        return (
            "lit",
            json.dumps(item, sort_keys=True, ensure_ascii=False, default=str),
        )
    for key in ("eventID", "id"):
        value = item.get(key)
        if value:
            return ("id", str(value))
    handle = item.get("opaque_response_handle")
    if handle:
        return ("gw", str(handle))
    adapter = item.get("adapterID")
    session = item.get("providerSessionID")
    if adapter or session:
        return ("ad", f"{adapter or ''}|{session or ''}")
    digest = hashlib.sha256(
        json.dumps(item, sort_keys=True, ensure_ascii=False, default=str).encode()
    ).hexdigest()
    return ("hash", digest)


def is_empty(value: Any) -> bool:
    return value in (None, "", [], {})


def merge_list(base: Any, incoming: Any) -> list[Any]:
    out: list[Any] = []
    index: dict[tuple[str, str], int] = {}
    for item in list(base or []) + list(incoming or []):
        key = identity(item)
        if key in index:
            out[index[key]] = merge_value(out[index[key]], item)
        else:
            index[key] = len(out)
            out.append(item)
    return out


def merge_record(base: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    base_time = record_time(base)
    incoming_time = record_time(incoming)
    if (
        incoming_time is not None
        and (base_time is None or incoming_time > base_time)
    ):
        winner, loser = incoming, base
    else:
        winner, loser = base, incoming
    out: dict[str, Any] = {}
    for key in set(winner) | set(loser):
        winner_value = winner.get(key)
        loser_value = loser.get(key)
        if key in LIST_KEYS or (
            isinstance(winner_value, list) and isinstance(loser_value, list)
        ):
            left = winner_value if isinstance(winner_value, list) else []
            right = loser_value if isinstance(loser_value, list) else []
            if not isinstance(winner_value, list) and not is_empty(winner_value):
                left = [winner_value]
            if not isinstance(loser_value, list) and not is_empty(loser_value):
                right = [loser_value]
            out[key] = merge_list(left, right)
        elif isinstance(winner_value, dict) and isinstance(loser_value, dict):
            out[key] = merge_record(winner_value, loser_value)
        elif is_empty(winner_value):
            out[key] = loser_value
        else:
            out[key] = winner_value
    return out


def merge_value(base: Any, incoming: Any) -> Any:
    if isinstance(base, dict) and isinstance(incoming, dict):
        return merge_record(base, incoming)
    if isinstance(base, list) and isinstance(incoming, list):
        return merge_list(base, incoming)
    if is_empty(base):
        return incoming
    if is_empty(incoming):
        return base
    return incoming if record_time(incoming) and (
        record_time(base) is None or record_time(incoming) > record_time(base)
    ) else base


def normalize_events(events: Any) -> list[Any]:
    if isinstance(events, dict):
        out = []
        for key, value in events.items():
            if isinstance(value, dict):
                event = dict(value)
                event.setdefault("eventID", key)
                out.append(event)
            else:
                out.append(value)
        return out
    return list(events or [])


def sort_events(events: list[Any]) -> list[Any]:
    def sort_key(event: Any) -> tuple[float, int, str]:
        if not isinstance(event, dict):
            return (0.0, 0, "")
        sequence = event.get("sequence")
        seq = int(sequence) if isinstance(sequence, (int, float)) else 0
        return (record_time(event) or 0.0, seq, str(event.get("eventID") or ""))

    return sorted(events, key=sort_key)


def _nonempty(value: Any) -> str | None:
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
    """True when every child looks like a Codex-session promotion, not a user project.

    Signature matches the native-chat store pollution: threads whose UUID is
    the Codex session id, only a synthesized/explicit codex-exec handle, and
    no Tatwo-authored user messages, Goal binding, GitHub binding, or CLI
    sessions.
    """
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
        codex_id = _nonempty(thread.get("codexSessionID"))
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


def reject_unsolicited_autoimported_projects(
    host: Any, incoming: Any
) -> Any:
    if not isinstance(incoming, dict):
        return incoming
    known_ids = {
        str(project.get("id"))
        for project in (host.get("projects") if isinstance(host, dict) else None)
        or []
        if isinstance(project, dict) and project.get("id")
    }
    projects = incoming.get("projects")
    if not isinstance(projects, list):
        return incoming
    kept = []
    for project in projects:
        if (
            is_autoimported_codex_project(project)
            and str(project.get("id") or "") not in known_ids
        ):
            continue
        kept.append(project)
    copy = dict(incoming)
    copy["projects"] = kept
    return copy


def merge_native(host: Any, incoming: Any) -> dict[str, Any]:
    incoming = reject_unsolicited_autoimported_projects(host, incoming)
    if not isinstance(host, dict) or not host:
        return incoming if isinstance(incoming, dict) else {"schemaVersion": 1, "projects": [], "threads": []}
    if not isinstance(incoming, dict) or not incoming:
        return host
    merged = merge_record(host, incoming)
    merged["schemaVersion"] = (
        host.get("schemaVersion") or incoming.get("schemaVersion") or 1
    )
    merged["updatedAt"] = utc_now()
    return merged


def merge_journal(host: Any, incoming: Any) -> dict[str, Any]:
    host_obj = dict(host) if isinstance(host, dict) else {}
    incoming_obj = dict(incoming) if isinstance(incoming, dict) else {}
    host_obj["events"] = normalize_events(host_obj.get("events"))
    incoming_obj["events"] = normalize_events(incoming_obj.get("events"))
    if not host_obj:
        merged = incoming_obj
    elif not incoming_obj:
        merged = host_obj
    else:
        merged = merge_record(host_obj, incoming_obj)
    merged["schema"] = (
        host_obj.get("schema")
        or incoming_obj.get("schema")
        or "ChatTranscriptJournalSnapshotV1"
    )
    merged["events"] = sort_events(normalize_events(merged.get("events")))
    return merged


MERGERS = {
    "native-chat-threads.json": merge_native,
    "chat-transcript-journal-v1.json": merge_journal,
}


def empty_payload(name: str) -> dict[str, Any]:
    if name == "native-chat-threads.json":
        return {"schemaVersion": 1, "projects": [], "threads": []}
    return {"schema": "ChatTranscriptJournalSnapshotV1", "events": [], "threads": []}


def package(support: Path, export: Path, device: str) -> int:
    files = []
    staging = export.parent / f".data-submit-{os.getpid()}"
    if staging.exists():
        shutil.rmtree(staging)
    blobs = staging / "blobs"
    blobs.mkdir(parents=True)
    for name in BUNDLE_FILES:
        src = support / name
        if not src.is_file():
            continue
        digest = sha256_file(src)
        shutil.copy2(src, blobs / digest)
        files.append(
            {"name": name, "sha256": digest, "bytes": src.stat().st_size}
        )
    if not files:
        shutil.rmtree(staging, ignore_errors=True)
        print("error: no local chat data files to submit", file=sys.stderr)
        return 2
    device_name = safe_device_name(device)
    submit_id = hashlib.sha256(
        "\n".join(f"{item['name']}={item['sha256']}" for item in files).encode()
    ).hexdigest()
    manifest = {
        "schema": SUBMIT_SCHEMA,
        "submittedAt": utc_now(),
        "device": device_name,
        "host": os.uname().nodename,
        "files": files,
        "submitId": submit_id,
        "excludes": ["keychain", "auth", "session", "token", "pid", "cache"],
        "direction": "secondary-to-host",
    }
    (staging / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    )
    export.parent.mkdir(parents=True, exist_ok=True)
    if export.exists():
        shutil.rmtree(export)
    staging.replace(export)
    print(f"packaged submitId={submit_id} device={device_name} files={len(files)}")
    return 0


def load_bundle_payloads(bundle: Path) -> dict[str, Any]:
    manifest = read_json(bundle / "manifest.json")
    if manifest.get("schema") != SUBMIT_SCHEMA:
        raise ValueError(f"unsupported submit schema in {bundle}")
    payloads: dict[str, Any] = {}
    for item in manifest.get("files") or []:
        name = item["name"]
        blob = bundle / "blobs" / item["sha256"]
        if not blob.is_file() or sha256_file(blob) != item["sha256"]:
            raise ValueError(f"corrupt blob {name}")
        payloads[name] = read_json(blob)
    return payloads


def iter_inbox_bundles(inbox: Path) -> list[Path]:
    if not inbox.is_dir():
        return []
    bundles = []
    for manifest in sorted(inbox.glob("*/*/manifest.json")):
        bundles.append(manifest.parent)
    return bundles


def backup_host_files(support: Path, names: list[str]) -> None:
    backup = support / "data-sync-previous"
    if backup.exists():
        shutil.rmtree(backup)
    backup.mkdir(parents=True)
    for name in names:
        src = support / name
        if src.is_file():
            shutil.copy2(src, backup / name)


def unify(support: Path, inbox: Path) -> int:
    if (
        os.environ.get("TATWO_OS_IMAGE_CONSUMER") == "1"
        and os.environ.get("TATWO_DATA_SYNC_ALLOW_LOCAL_UNIFY") != "1"
        and os.environ.get("TATWO_DATA_SYNC_ROLE") != "host"
    ):
        print(
            "error: refuse local unify on a consumer; submit to host instead",
            file=sys.stderr,
        )
        return 2
    bundles = iter_inbox_bundles(inbox)
    if not bundles:
        print("unified submitCount=0 (inbox empty; host files untouched)")
        return 0

    lock_dir = support / "data-sync"
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_handle = (lock_dir / "unify.lock").open("a+")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX)
        bundles = iter_inbox_bundles(inbox)
        if not bundles:
            print("unified submitCount=0 (inbox empty; host files untouched)")
            return 0

        merged: dict[str, Any] = {}
        for name in BUNDLE_FILES:
            src = support / name
            if src.is_file():
                merged[name] = read_json(src)
            else:
                merged[name] = empty_payload(name)

        applied: list[str] = []
        for bundle in bundles:
            try:
                payloads = load_bundle_payloads(bundle)
            except (OSError, ValueError, json.JSONDecodeError, KeyError) as exc:
                print(f"error: skip corrupt submit {bundle}: {exc}", file=sys.stderr)
                return 2
            for name, payload in payloads.items():
                merger = MERGERS.get(name)
                if merger is None:
                    continue
                merged[name] = merger(merged.get(name) or empty_payload(name), payload)
            applied.append(bundle.as_posix())

        backup_host_files(support, list(merged))
        for name, payload in merged.items():
            write_json(support / name, payload)

        applied_root = inbox.parent / "inbox-applied"
        for bundle in bundles:
            device_dir = bundle.parent
            dest = applied_root / device_dir.name / bundle.name
            if dest.exists():
                dest = applied_root / device_dir.name / f"{bundle.name}-{utc_now().replace(':', '')}"
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(bundle), str(dest))
            if device_dir.is_dir() and not any(device_dir.iterdir()):
                device_dir.rmdir()

        print(f"unified submitCount={len(applied)} files={len(merged)}")
        return 0
    finally:
        fcntl.flock(lock_handle, fcntl.LOCK_UN)
        lock_handle.close()


def refuse_apply() -> int:
    print(
        "error: apply/overwrite is removed; submit to host and let the host unify",
        file=sys.stderr,
    )
    return 2


def selftest_merge() -> int:
    host_native = {
        "schemaVersion": 1,
        "updatedAt": "2026-08-15T01:00:00Z",
        "projects": [
            {
                "id": "proj-shared",
                "name": "host-name",
                "threads": [
                    {
                        "id": "t-shared",
                        "title": "host-title",
                        "updatedAt": "2026-08-15T01:00:00Z",
                        "gatewayConversationHandles": [
                            {"opaque_response_handle": "host-h", "thread_id": "t-shared"}
                        ],
                    }
                ],
            }
        ],
        "threads": [
            {
                "id": "t-host-only",
                "title": "only-on-host",
                "updatedAt": "2026-08-15T01:00:00Z",
                "loopsSessions": [],
            }
        ],
    }
    laptop_native = {
        "schemaVersion": 1,
        "updatedAt": "2026-08-15T03:00:00Z",
        "projects": [
            {
                "id": "proj-shared",
                "name": "laptop-name",
                "threads": [
                    {
                        "id": "t-shared",
                        "title": "laptop-title",
                        "updatedAt": "2026-08-15T03:00:00Z",
                        "gatewayConversationHandles": [
                            {"opaque_response_handle": "laptop-h", "thread_id": "t-shared"}
                        ],
                    },
                    {
                        "id": "t-laptop-proj",
                        "title": "new-on-laptop",
                        "updatedAt": "2026-08-15T03:10:00Z",
                    },
                ],
            }
        ],
        "threads": [
            {
                "id": "t-laptop-only",
                "title": "only-on-laptop",
                "updatedAt": "2026-08-15T03:00:00Z",
                "loopsSessions": [
                    {"id": "loop-1", "messages": [{"id": "m-laptop", "summary": "opt"}]}
                ],
            }
        ],
    }
    native = merge_native(host_native, laptop_native)
    thread_ids = {item["id"] for item in native["threads"]}
    assert "t-host-only" in thread_ids
    assert "t-laptop-only" in thread_ids
    shared = next(
        item
        for project in native["projects"]
        if project["id"] == "proj-shared"
        for item in project["threads"]
        if item["id"] == "t-shared"
    )
    assert shared["title"] == "laptop-title"
    handles = {item["opaque_response_handle"] for item in shared["gatewayConversationHandles"]}
    assert handles == {"host-h", "laptop-h"}
    proj_thread_ids = {
        item["id"]
        for project in native["projects"]
        if project["id"] == "proj-shared"
        for item in project["threads"]
    }
    assert "t-laptop-proj" in proj_thread_ids

    imported_id = "019f0000-0000-7000-8000-00000000aa18"
    polluted = merge_native(
        host_native,
        {
            "schemaVersion": 1,
            "updatedAt": "2026-08-15T05:00:00Z",
            "projects": [
                {
                    "id": "proj-auto-codex",
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
                }
            ],
            "threads": [],
        },
    )
    assert all(project.get("id") != "proj-auto-codex" for project in polluted["projects"])

    host_journal = {
        "schema": "ChatTranscriptJournalSnapshotV1",
        "events": [
            {
                "eventID": "e-host",
                "occurredAt": "2026-08-15T01:00:00Z",
                "sequence": 1,
                "summary": "host",
            },
            {
                "eventID": "e-shared",
                "occurredAt": "2026-08-15T01:00:00Z",
                "sequence": 2,
                "summary": "old",
            },
        ],
        "threads": [{"id": "thread:host", "turns": [{"id": "turn-h", "items": []}]}],
    }
    laptop_journal = {
        "schema": "ChatTranscriptJournalSnapshotV1",
        "events": [
            {
                "eventID": "e-laptop",
                "occurredAt": "2026-08-15T03:00:00Z",
                "sequence": 3,
                "summary": "laptop",
            },
            {
                "eventID": "e-shared",
                "occurredAt": "2026-08-15T03:00:00Z",
                "sequence": 2,
                "summary": "new",
            },
        ],
        "threads": [
            {
                "id": "thread:host",
                "turns": [{"id": "turn-l", "items": [{"id": "item-l"}]}],
            },
            {"id": "thread:laptop", "turns": []},
        ],
    }
    journal = merge_journal(host_journal, laptop_journal)
    events = {item["eventID"]: item for item in journal["events"]}
    assert set(events) == {"e-host", "e-laptop", "e-shared"}
    assert events["e-shared"]["summary"] == "new"
    thread_map = {item["id"]: item for item in journal["threads"]}
    assert "thread:laptop" in thread_map
    turn_ids = {item["id"] for item in thread_map["thread:host"]["turns"]}
    assert turn_ids == {"turn-h", "turn-l"}
    print("selftest-merge=passed")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--support", default=str(DEFAULT_SUPPORT))
    parser.add_argument(
        "--export",
        default=str(DEFAULT_SUPPORT / "data-sync/outgoing/local"),
    )
    parser.add_argument(
        "--inbox",
        default=str(DEFAULT_SUPPORT / "data-sync/inbox"),
    )
    parser.add_argument(
        "--device",
        default=os.environ.get("TATWO_DEVICE_NAME") or os.uname().nodename,
    )
    parser.add_argument(
        "command",
        choices=[
            "package",
            "publish",
            "unify",
            "apply",
            "selftest-merge",
        ],
    )
    args = parser.parse_args(argv)
    support = Path(args.support)
    if args.command == "selftest-merge":
        return selftest_merge()
    if args.command == "apply":
        return refuse_apply()
    if args.command in {"package", "publish"}:
        return package(support, Path(args.export), args.device)
    return unify(support, Path(args.inbox))


if __name__ == "__main__":
    sys.exit(main())
