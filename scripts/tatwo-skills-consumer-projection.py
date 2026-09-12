#!/usr/bin/env python3
"""Durable, fail-closed projection of verified Skillet skills to native AI clients.

The projection has one managed indirection:

    ~/.codex/skills  ─┐
                      ├─> <consumer-root>/current -> source or verified runtime
    ~/.claude/skills ─┘

Only symlinks are replaced. Unknown real files/directories are never overwritten.
Every mutation is journaled and recoverable under <consumer-root>/.tatwo-binding.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import sys
import unicodedata
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


SCHEMA_RECEIPT = "TatwoSkillsConsumerProjectionReceiptV1"
SCHEMA_STATE = "TatwoSkillsConsumerProjectionStateV1"
SCHEMA_TRANSACTION = "TatwoSkillsConsumerProjectionTransactionV1"
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
NATIVE_IDS = ("codex.native-skills", "claude.native-skills")
NATIVE_MANIFEST_EVIDENCE_KEYS = (
    "nativeManifestStatus",
    "nativeSkillName",
    "nativeManifestDigest",
)
UNSAFE_NATIVE_LINE_SEPARATORS = (
    "\v",
    "\f",
    "\x1c",
    "\x1d",
    "\x1e",
    "\x1f",
    "\x85",
    "\u2028",
    "\u2029",
)
NATIVE_FRONTMATTER_FIELDS = {
    "name",
    "description",
    "license",
    "compatibility",
    "allowed-tools",
    "metadata",
    "user-invocable",
    "when-to-use",
}
NATIVE_BLOCK_SCALAR = re.compile(
    r"^[>|](?:[1-9][+-]?|[+-][1-9]?)?$"
)
NATIVE_FRONTMATTER_KEY = re.compile(
    r"^([A-Za-z][A-Za-z0-9-]*):(?:[ ]+(.*))?$"
)
NATIVE_METADATA_KEY = re.compile(
    r"^  ([A-Za-z][A-Za-z0-9_.-]*):(?:[ ]+(.*))?$"
)
YAML_NON_STRING_LITERALS = {
    "~",
    "null",
    "true",
    "false",
    "yes",
    "no",
    "on",
    "off",
}
YAML_NUMBER_LITERAL = re.compile(
    r"^[+-]?(?:"
    r"(?:0|[1-9][0-9_]*)(?:\.[0-9_]*)?(?:[eE][+-]?[0-9]+)?"
    r"|0[xX][0-9a-fA-F_]+"
    r"|0[oO][0-7_]+"
    r"|0[bB][01_]+"
    r")$"
)


class ProjectionError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def require_absolute(path: str, field: str) -> str:
    if not path or not os.path.isabs(path) or "\x00" in path:
        raise ProjectionError(f"{field} must be an absolute path")
    return os.path.normpath(path)


def existing_realpath(path: str) -> str:
    return os.path.normpath(os.path.realpath(path))


def paths_overlap(first: str, second: str) -> bool:
    first_value = existing_realpath(first) if os.path.lexists(first) else os.path.normpath(first)
    second_value = existing_realpath(second) if os.path.lexists(second) else os.path.normpath(second)
    try:
        common = os.path.commonpath([first_value, second_value])
    except ValueError:
        return False
    return common == first_value or common == second_value


def managed_location(path: str) -> str:
    """Resolve the parent but not the managed leaf symlink itself."""
    return os.path.join(existing_realpath(os.path.dirname(path)), os.path.basename(path))


def locations_overlap(first: str, second: str) -> bool:
    first_value = managed_location(first)
    second_value = managed_location(second)
    try:
        common = os.path.commonpath([first_value, second_value])
    except ValueError:
        return False
    return common == first_value or common == second_value


def fsync_directory(path: str) -> None:
    directory = os.open(path, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def atomic_write_bytes(path: str, data: bytes, immutable: bool = False) -> None:
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    if immutable and os.path.lexists(path):
        raise ProjectionError(f"immutable receipt already exists: {path}")
    temporary = os.path.join(parent, f".{os.path.basename(path)}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.close(descriptor)
        descriptor = -1
        if immutable and os.path.lexists(path):
            raise ProjectionError(f"immutable receipt already exists: {path}")
        os.replace(temporary, path)
        fsync_directory(parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def atomic_write_json(path: str, value: Dict[str, Any], immutable: bool = False) -> None:
    data = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    atomic_write_bytes(path, data, immutable=immutable)


def read_json(path: str) -> Dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise ProjectionError(f"invalid JSON at {path}: {error}") from error
    if not isinstance(value, dict):
        raise ProjectionError(f"JSON object required at {path}")
    return value


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def path_snapshot(path: str) -> Dict[str, Any]:
    if not os.path.lexists(path):
        return {"kind": "absent"}
    mode = os.lstat(path).st_mode
    if not stat.S_ISLNK(mode):
        raise ProjectionError(f"managed path is not absent or a symlink: {path}")
    return {"kind": "symlink", "target": os.readlink(path)}


def restore_snapshot(path: str, snapshot: Dict[str, Any]) -> None:
    if os.path.lexists(path):
        mode = os.lstat(path).st_mode
        if not stat.S_ISLNK(mode):
            raise ProjectionError(f"rollback refused to overwrite non-symlink: {path}")
        os.unlink(path)
        fsync_directory(os.path.dirname(path))
    kind = snapshot.get("kind")
    if kind == "absent":
        return
    if kind != "symlink" or not isinstance(snapshot.get("target"), str):
        raise ProjectionError(f"invalid rollback snapshot for {path}")
    atomic_symlink(path, snapshot["target"])


def atomic_symlink(path: str, target: str) -> None:
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    if os.path.lexists(path) and not stat.S_ISLNK(os.lstat(path).st_mode):
        raise ProjectionError(f"refusing to overwrite non-symlink: {path}")
    temporary = os.path.join(parent, f".{os.path.basename(path)}.{os.getpid()}.{uuid.uuid4().hex}.link")
    try:
        os.symlink(target, temporary)
        os.replace(temporary, path)
        fsync_directory(parent)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def normalized_link_target(link: str) -> str:
    target = os.readlink(link)
    if os.path.isabs(target):
        return os.path.normpath(target)
    return os.path.normpath(os.path.join(os.path.dirname(link), target))


def require_symlink_to(link: str, expected: str, consumer_id: str) -> None:
    if not os.path.lexists(link) or not stat.S_ISLNK(os.lstat(link).st_mode):
        raise ProjectionError(f"{consumer_id} native skills entrypoint is not a symlink: {link}")
    if normalized_link_target(link) != os.path.normpath(expected):
        raise ProjectionError(f"{consumer_id} native skills entrypoint drifted from managed current")


def require_directory(path: str, field: str) -> None:
    if not os.path.isdir(path) or os.path.islink(path):
        raise ProjectionError(f"{field} must be a real directory: {path}")


def has_skill_manifest(root: str) -> bool:
    try:
        with os.scandir(root) as entries:
            for entry in entries:
                if entry.name.startswith("."):
                    continue
                if entry.is_dir(follow_symlinks=True) and os.path.isfile(
                    os.path.join(entry.path, "SKILL.md")
                ):
                    return True
    except OSError:
        return False
    return False


def strip_yaml_inline_comment(raw: str) -> str:
    for index, character in enumerate(raw):
        if character == "#" and index > 0 and raw[index - 1].isspace():
            return raw[:index].rstrip()
    return raw.rstrip()


def validate_native_string_characters(
    value: str, repository_id: str, field: str
) -> None:
    for character in value:
        category = unicodedata.category(character)
        if (
            character in ("\t", "\n", "\r")
            or character in UNSAFE_NATIVE_LINE_SEPARATORS
            or category.startswith("C")
            or category in ("Zl", "Zp")
        ):
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter {field} "
                "contains an unsafe character"
            )


def validate_native_skill_name(name: str, repository_id: str) -> None:
    invalid_message = (
        f"native skill {repository_id} YAML frontmatter name "
        "must be a normalized lowercase skill identifier"
    )
    if (
        len(name) > 64
        or unicodedata.normalize("NFKC", name) != name
        or name.startswith("-")
        or name.endswith("-")
        or "--" in name
    ):
        raise ProjectionError(invalid_message)
    segment_has_base = False
    for character in name:
        if character == "-":
            if not segment_has_base:
                raise ProjectionError(invalid_message)
            segment_has_base = False
            continue
        category = unicodedata.category(character)
        if category in ("Ll", "Lo", "Nd"):
            segment_has_base = True
            continue
        if category in ("Mn", "Mc") and segment_has_base:
            continue
        raise ProjectionError(invalid_message)
    if not segment_has_base:
        raise ProjectionError(invalid_message)


def native_frontmatter_value(
    raw: str, repository_id: str, field: str
) -> str:
    value = raw.strip()
    if not value:
        raise ProjectionError(
            f"native skill {repository_id} YAML frontmatter {field} must be a string"
        )

    parsed: Optional[str] = None
    remainder = ""
    if value.startswith('"'):
        try:
            parsed_value, consumed = json.JSONDecoder().raw_decode(value)
        except json.JSONDecodeError as error:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter {field} "
                "has an invalid quoted string"
            ) from error
        if not isinstance(parsed_value, str):
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter {field} must be a string"
            )
        parsed = parsed_value
        remainder = value[consumed:].strip()
    elif value.startswith("'"):
        characters: List[str] = []
        index = 1
        closed = False
        while index < len(value):
            character = value[index]
            if character != "'":
                characters.append(character)
                index += 1
                continue
            if index + 1 < len(value) and value[index + 1] == "'":
                characters.append("'")
                index += 2
                continue
            closed = True
            index += 1
            break
        if not closed:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter {field} "
                "has an invalid quoted string"
            )
        parsed = "".join(characters)
        remainder = value[index:].strip()
    else:
        value = strip_yaml_inline_comment(value).strip()
        lowered = value.lower()
        if (
            not value
            or lowered in YAML_NON_STRING_LITERALS
            or YAML_NUMBER_LITERAL.fullmatch(value)
            or value[0] in "[]{}#&*!|>@`,%"
            or (
                value[0] in "-?"
                and (len(value) == 1 or value[1].isspace())
            )
            or re.search(r":(?:[ ]|$)", value) is not None
        ):
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter {field} must be a string"
            )
        parsed = value

    if remainder and not remainder.startswith("#"):
        raise ProjectionError(
            f"native skill {repository_id} YAML frontmatter {field} "
            "has trailing YAML syntax"
        )
    parsed = parsed.strip()
    if not parsed:
        raise ProjectionError(
            f"native skill {repository_id} YAML frontmatter {field} must be non-empty"
        )
    validate_native_string_characters(parsed, repository_id, field)
    return parsed


def native_block_scalar_value(
    lines: List[str],
    start: int,
    repository_id: str,
    field: str,
) -> Tuple[str, int]:
    values: List[str] = []
    index = start
    while index < len(lines):
        line = lines[index]
        if line and not line.startswith(" "):
            break
        if "\t" in line:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter contains tab indentation"
            )
        stripped = line.strip()
        if stripped:
            values.append(stripped)
        index += 1
    value = " ".join(values).strip()
    if not value:
        raise ProjectionError(
            f"native skill {repository_id} YAML frontmatter {field} "
            "block scalar must be non-empty"
        )
    validate_native_string_characters(value, repository_id, field)
    return value, index


def validate_native_metadata(
    lines: List[str], start: int, repository_id: str
) -> int:
    index = start
    entries = 0
    keys = set()
    while index < len(lines):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            index += 1
            continue
        if not line.startswith(" "):
            break
        if "\t" in line:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter contains tab indentation"
            )
        match = NATIVE_METADATA_KEY.fullmatch(line)
        if match is None or match.group(2) is None:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter metadata "
                "must be a flat string mapping"
            )
        key = match.group(1)
        if key in keys:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter metadata "
                f"duplicates {key}"
            )
        native_frontmatter_value(
            match.group(2), repository_id, f"metadata.{key}"
        )
        keys.add(key)
        entries += 1
        index += 1
    if entries == 0:
        raise ProjectionError(
            f"native skill {repository_id} YAML frontmatter metadata must not be empty"
        )
    return index


def validate_native_skill_manifest(
    repository_root: str,
    repository_id: str,
    *,
    test_invalidated: bool = False,
) -> Dict[str, str]:
    manifest_path = os.path.join(repository_root, "SKILL.md")
    if (
        os.path.islink(manifest_path)
        or not os.path.isfile(manifest_path)
    ):
        raise ProjectionError(
            f"native skill {repository_id} is missing regular SKILL.md"
        )
    try:
        with open(
            manifest_path,
            "r",
            encoding="utf-8",
            newline=None,
        ) as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError) as error:
        raise ProjectionError(
            f"native skill {repository_id} SKILL.md is not readable UTF-8"
        ) from error

    if test_invalidated:
        text = "# test-only post-link invalid native manifest\n"
    if any(separator in text for separator in UNSAFE_NATIVE_LINE_SEPARATORS):
        raise ProjectionError(
            f"native skill {repository_id} SKILL.md contains an unsafe line separator"
        )
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        raise ProjectionError(
            f"native skill {repository_id} SKILL.md is missing YAML frontmatter"
        )

    closing: Optional[int] = None
    for index in range(1, len(lines)):
        if lines[index] == "---":
            closing = index
            break
    if closing is None:
        raise ProjectionError(
            f"native skill {repository_id} SKILL.md has unclosed YAML frontmatter"
        )

    frontmatter = lines[1:closing]
    values: Dict[str, str] = {}
    index = 0
    while index < len(frontmatter):
        line = frontmatter[index]
        if not line.strip() or line.lstrip().startswith("#"):
            index += 1
            continue
        if "\t" in line or line.startswith(" "):
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter has invalid indentation"
            )
        match = NATIVE_FRONTMATTER_KEY.fullmatch(line)
        if match is None:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter has invalid mapping syntax"
            )
        field = match.group(1)
        raw_value = match.group(2)
        if field not in NATIVE_FRONTMATTER_FIELDS:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter uses "
                f"unsupported top-level field: {field}"
            )
        if field in values:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter duplicates {field}"
            )
        if field == "metadata":
            if raw_value == "{}":
                values[field] = "{}"
                index += 1
                continue
            if raw_value is not None:
                raise ProjectionError(
                    f"native skill {repository_id} YAML frontmatter metadata "
                    "must be a mapping"
                )
            index = validate_native_metadata(
                frontmatter, index + 1, repository_id
            )
            values[field] = "valid"
            continue
        if field == "user-invocable":
            literal = strip_yaml_inline_comment(raw_value or "").strip().lower()
            if literal not in ("true", "false"):
                raise ProjectionError(
                    f"native skill {repository_id} YAML frontmatter "
                    "user-invocable must be true or false"
                )
            values[field] = literal
            index += 1
            continue
        if raw_value is None:
            raise ProjectionError(
                f"native skill {repository_id} YAML frontmatter {field} "
                "must be a string"
            )
        block_marker = strip_yaml_inline_comment(raw_value).strip()
        if NATIVE_BLOCK_SCALAR.fullmatch(block_marker):
            if field != "description":
                raise ProjectionError(
                    f"native skill {repository_id} YAML frontmatter {field} "
                    "must use an inline string"
                )
            value, index = native_block_scalar_value(
                frontmatter, index + 1, repository_id, field
            )
            values[field] = value
            continue
        values[field] = native_frontmatter_value(
            raw_value, repository_id, field
        )
        index += 1

    name = values.get("name")
    description = values.get("description")
    if name is None:
        raise ProjectionError(
            f"native skill {repository_id} YAML frontmatter is missing name"
        )
    if description is None:
        raise ProjectionError(
            f"native skill {repository_id} YAML frontmatter is missing description"
        )
    validate_native_skill_name(name, repository_id)
    return {
        "nativeManifestStatus": "valid",
        "nativeSkillName": name,
        "nativeManifestDigest": sha256_file(manifest_path),
    }


def repository_readback_matches(
    stored: Any, current: Dict[str, Any]
) -> bool:
    if not isinstance(stored, dict):
        return False
    if stored == current:
        return True
    evidence_presence = [
        key in stored for key in NATIVE_MANIFEST_EVIDENCE_KEYS
    ]
    if any(evidence_presence):
        return False
    legacy_current = {
        key: value
        for key, value in current.items()
        if key not in NATIVE_MANIFEST_EVIDENCE_KEYS
    }
    return stored == legacy_current


def repository_readback_lists_match(
    stored: Any, current: List[Dict[str, Any]]
) -> bool:
    return (
        isinstance(stored, list)
        and len(stored) == len(current)
        and all(
            repository_readback_matches(stored_item, current_item)
            for stored_item, current_item in zip(stored, current)
        )
    )


def projection_state_matches(
    stored: Dict[str, Any], expected: Dict[str, Any]
) -> bool:
    stored_scalars = dict(stored)
    expected_scalars = dict(expected)
    stored_repositories = stored_scalars.pop("repositories", None)
    expected_repositories = expected_scalars.pop("repositories", None)
    stored_preserved = stored_scalars.pop(
        "targetPreservedRepositories", None
    )
    expected_preserved = expected_scalars.pop(
        "targetPreservedRepositories", None
    )
    return (
        stored_scalars == expected_scalars
        and isinstance(expected_repositories, list)
        and repository_readback_lists_match(
            stored_repositories, expected_repositories
        )
        and isinstance(expected_preserved, list)
        and repository_readback_lists_match(
            stored_preserved, expected_preserved
        )
    )


def validate_roots(
    desired_root: str,
    consumer_root: str,
    codex_link: str,
    claude_link: str,
    desired_field: str,
    require_existing_directory: bool = True,
) -> None:
    if require_existing_directory:
        require_directory(desired_root, desired_field)
    elif os.path.lexists(desired_root) and (
        not os.path.isdir(desired_root) or os.path.islink(desired_root)
    ):
        raise ProjectionError(
            f"{desired_field} must be absent or a real directory: {desired_root}"
        )
    if paths_overlap(desired_root, consumer_root):
        raise ProjectionError(f"{desired_field} overlaps consumer root")
    desired_location = existing_realpath(desired_root)
    for other, field in (
        (codex_link, "Codex skills link"),
        (claude_link, "Claude skills link"),
    ):
        other_location = managed_location(other)
        try:
            common = os.path.commonpath([desired_location, other_location])
        except ValueError:
            common = ""
        if common == desired_location or common == other_location:
            raise ProjectionError(f"{desired_field} overlaps {field}")
    if locations_overlap(consumer_root, codex_link) or locations_overlap(
        consumer_root, claude_link
    ):
        raise ProjectionError("consumer root overlaps a native skills entrypoint")
    if codex_link == claude_link:
        raise ProjectionError("Codex and Claude native skills entrypoints must differ")


def is_prohibited_relative_path(relative: str) -> bool:
    components = [component.lower() for component in relative.split("/")]
    if not components:
        return True
    filename = components[-1]
    if ".git" in components:
        return True
    if filename == ".env" or filename.startswith(".env."):
        return True
    if filename in {
        "id_rsa",
        "id_ed25519",
        "credentials.json",
        "api-keys.json",
        "api_keys.json",
        "apikeys.json",
    }:
        return True
    fragments = (
        "token",
        "secret",
        "credential",
        "cookie",
        "session",
        "keychain",
        "api-key",
        "api_key",
        "apikey",
        "private-key",
        "private_key",
    )
    if any(fragment in component for component in components for fragment in fragments):
        return True
    return os.path.splitext(filename)[1].lower() in {".key", ".pem", ".p12", ".pfx"}


def snapshot_digest(root: str) -> Tuple[str, int, int]:
    require_directory(root, "runtime repository")
    files: List[Tuple[str, bytes]] = []
    seen: set[str] = set()
    for current, directories, names in os.walk(root, topdown=True, followlinks=False):
        kept_directories: List[str] = []
        for name in directories:
            path = os.path.join(current, name)
            if os.path.islink(path):
                raise ProjectionError(f"runtime repository contains symlink: {path}")
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            relative = unicodedata.normalize("NFC", relative)
            if any(component.lower() == ".git" for component in relative.split("/")):
                continue
            if is_prohibited_relative_path(relative):
                raise ProjectionError(f"runtime repository contains prohibited path: {relative}")
            kept_directories.append(name)
        directories[:] = kept_directories
        for name in names:
            path = os.path.join(current, name)
            if os.path.islink(path) or not os.path.isfile(path):
                raise ProjectionError(f"runtime repository contains unsupported entry: {path}")
            relative = unicodedata.normalize(
                "NFC", os.path.relpath(path, root).replace(os.sep, "/")
            )
            if any(component.lower() == ".git" for component in relative.split("/")):
                continue
            if not relative or relative.startswith("/") or any(
                component in ("", ".", "..") for component in relative.split("/")
            ):
                raise ProjectionError(f"runtime repository contains unsafe path: {relative}")
            if is_prohibited_relative_path(relative):
                raise ProjectionError(f"runtime repository contains prohibited path: {relative}")
            if relative in seen:
                raise ProjectionError(f"runtime repository has duplicate canonical path: {relative}")
            seen.add(relative)
            with open(path, "rb") as handle:
                files.append((relative, handle.read()))
    if "SKILL.md" not in seen:
        raise ProjectionError(f"runtime repository has no SKILL.md: {root}")
    files.sort(key=lambda item: item[0].encode("utf-8"))
    digest = hashlib.sha256()
    byte_count = 0
    for relative, data in files:
        encoded = relative.encode("utf-8")
        digest.update(struct.pack(">Q", len(encoded)))
        digest.update(encoded)
        digest.update(struct.pack(">Q", len(data)))
        digest.update(data)
        byte_count += len(data)
    return digest.hexdigest(), len(files), byte_count


def load_set_manifest(
    path: str,
    request_id: Optional[str],
    activation_receipt_path: Optional[str] = None,
) -> Dict[str, Any]:
    require_absolute(path, "set manifest")
    if not os.path.isfile(path) or os.path.islink(path):
        raise ProjectionError(f"set manifest must be a regular file: {path}")
    value = read_json(path)
    repositories = value.get("repositories")
    if (
        value.get("schemaVersion") != 1
        or not isinstance(repositories, list)
        or not repositories
        or (request_id is not None and value.get("requestID") != request_id)
    ):
        raise ProjectionError("set manifest binding is invalid")
    repository_ids: List[str] = []
    normalized: List[Dict[str, str]] = []
    for repository in repositories:
        if not isinstance(repository, dict):
            raise ProjectionError("set manifest repository is invalid")
        repository_id = repository.get("repositoryID")
        revision_id = repository.get("revisionID")
        content_digest = repository.get("contentDigest")
        if (
            not isinstance(repository_id, str)
            or SAFE_IDENTIFIER.fullmatch(repository_id) is None
            or repository_id.startswith(".")
            or not isinstance(content_digest, str)
            or SHA256.fullmatch(content_digest) is None
            or revision_id != f"rev-{content_digest}"
        ):
            raise ProjectionError("set manifest repository identity is invalid")
        repository_ids.append(repository_id)
        normalized.append(
            {
                "repositoryID": repository_id,
                "revisionID": revision_id,
                "contentDigest": content_digest,
            }
        )
    if len(set(repository_ids)) != len(repository_ids):
        raise ProjectionError("set manifest contains duplicate repositories")
    if repository_ids != sorted(repository_ids, key=lambda item: item.encode("utf-8")):
        raise ProjectionError("set manifest repositories are not in portable order")
    manifest = {
        "requestID": value.get("requestID"),
        "catalogRevision": value.get("catalogRevision"),
        "authorityEpoch": value.get("authorityEpoch"),
        "ledgerSequence": value.get("ledgerSequence"),
        "sourceDeviceID": value.get("sourceDeviceID"),
        "targetDeviceID": value.get("targetDeviceID"),
        "manifestDigest": sha256_file(path),
        "repositories": normalized,
    }
    manifest["targetPreservedRepositories"] = (
        load_target_preserved_repositories(
            activation_receipt_path,
            request_id,
            manifest,
        )
        if activation_receipt_path is not None
        else []
    )
    return manifest


def load_target_preserved_repositories(
    path: str,
    request_id: Optional[str],
    manifest: Dict[str, Any],
) -> List[Dict[str, str]]:
    require_absolute(path, "Skillet activation receipt")
    if not os.path.isfile(path) or os.path.islink(path):
        raise ProjectionError(
            f"Skillet activation receipt must be a regular file: {path}"
        )
    receipt = read_json(path)
    if (
        receipt.get("schema")
        not in (
            "TatwoSkilletSetActivationCLIOutputV1",
            "TatwoSkilletSetActiveVerificationCLIOutputV1",
        )
        or receipt.get("activationState") != "active"
        or receipt.get("requestID") != manifest["requestID"]
        or (request_id is not None and receipt.get("requestID") != request_id)
        or receipt.get("sourceDeviceID") != manifest["sourceDeviceID"]
        or receipt.get("targetDeviceID") != manifest["targetDeviceID"]
        or receipt.get("authorityEpoch") != manifest["authorityEpoch"]
        or receipt.get("ledgerSequence") != manifest["ledgerSequence"]
        or receipt.get("catalogRevision") != manifest["catalogRevision"]
        or receipt.get("targetPreservedRuntimeClosureCapability")
        != "target-preserved-runtime-closure-v1"
        or receipt.get("targetPreservedRuntimeClosed") is not True
        or receipt.get("repositoryCount") != len(manifest["repositories"])
        or receipt.get("repositories") is None
        or receipt.get("targetPreservedCount") is None
        or receipt.get("targetPreservedRepositories") is None
    ):
        raise ProjectionError("Skillet activation receipt binding is invalid")
    incoming = receipt["repositories"]
    if not isinstance(incoming, list) or len(incoming) != len(manifest["repositories"]):
        raise ProjectionError("Skillet activation receipt repository set is invalid")
    for expected, actual in zip(manifest["repositories"], incoming):
        if (
            not isinstance(actual, dict)
            or actual.get("repositoryID") != expected["repositoryID"]
            or actual.get("revisionID") != expected["revisionID"]
            or actual.get("contentDigest") != expected["contentDigest"]
            or actual.get("requestID") != manifest["requestID"]
            or actual.get("sourceDeviceID") != manifest["sourceDeviceID"]
            or actual.get("targetDeviceID") != manifest["targetDeviceID"]
            or actual.get("authorityEpoch") != manifest["authorityEpoch"]
            or actual.get("ledgerSequence") != manifest["ledgerSequence"]
            or actual.get("catalogRevision") != manifest["catalogRevision"]
            or actual.get("activationState") != "active"
        ):
            raise ProjectionError(
                "Skillet activation receipt does not match the set manifest"
            )

    preserved = receipt["targetPreservedRepositories"]
    if (
        not isinstance(preserved, list)
        or not isinstance(receipt["targetPreservedCount"], int)
        or receipt["targetPreservedCount"] != len(preserved)
    ):
        raise ProjectionError("target-preserved repository count is invalid")
    normalized: List[Dict[str, str]] = []
    preserved_ids: List[str] = []
    incoming_ids = {
        repository["repositoryID"] for repository in manifest["repositories"]
    }
    for repository in preserved:
        if not isinstance(repository, dict):
            raise ProjectionError("target-preserved repository is invalid")
        repository_id = repository.get("repositoryID")
        revision_id = repository.get("revisionID")
        content_digest = repository.get("contentDigest")
        state = repository.get("state")
        if (
            not isinstance(repository_id, str)
            or SAFE_IDENTIFIER.fullmatch(repository_id) is None
            or repository_id.startswith(".")
            or repository_id in incoming_ids
            or not isinstance(content_digest, str)
            or SHA256.fullmatch(content_digest) is None
            or revision_id != f"rev-{content_digest}"
            or state != "runtime-preserved"
        ):
            raise ProjectionError("target-preserved repository identity is invalid")
        preserved_ids.append(repository_id)
        normalized.append(
            {
                "repositoryID": repository_id,
                "revisionID": revision_id,
                "contentDigest": content_digest,
                "state": state,
            }
        )
    if len(set(preserved_ids)) != len(preserved_ids):
        raise ProjectionError("target-preserved repository set contains duplicates")
    if preserved_ids != sorted(preserved_ids, key=lambda item: item.encode("utf-8")):
        raise ProjectionError("target-preserved repositories are not in portable order")
    return normalized


def verify_runtime(
    runtime_root: str,
    manifest: Dict[str, Any],
    *,
    post_link_validation: bool = False,
) -> List[Dict[str, Any]]:
    require_directory(runtime_root, "runtime root")
    actual_repositories: List[str] = []
    for entry in os.scandir(runtime_root):
        if entry.name.startswith("."):
            continue
        if not entry.is_dir(follow_symlinks=False) or entry.is_symlink():
            raise ProjectionError(f"runtime root contains unsupported top-level entry: {entry.name}")
        actual_repositories.append(entry.name)
    actual_repositories.sort(key=lambda item: item.encode("utf-8"))
    expected_repositories = [
        repository["repositoryID"] for repository in manifest["repositories"]
    ]
    target_preserved = manifest.get("targetPreservedRepositories", [])
    if not isinstance(target_preserved, list):
        raise ProjectionError("target-preserved repository evidence is invalid")
    expected_repositories.extend(
        repository["repositoryID"]
        for repository in target_preserved
        if repository.get("state") == "runtime-preserved"
    )
    expected_repositories.sort(key=lambda item: item.encode("utf-8"))
    if actual_repositories != expected_repositories:
        raise ProjectionError(
            "runtime repository coverage mismatch: "
            f"expected={expected_repositories} actual={actual_repositories}"
        )
    readbacks: List[Dict[str, Any]] = []
    for repository in manifest["repositories"]:
        repository_root = os.path.join(runtime_root, repository["repositoryID"])
        digest, file_count, byte_count = snapshot_digest(repository_root)
        if digest != repository["contentDigest"]:
            raise ProjectionError(
                f"runtime repository digest mismatch: {repository['repositoryID']}"
            )
        test_invalidated = (
            post_link_validation
            and os.environ.get("TATWO_TEST_MODE") == "1"
            and os.environ.get(
                "TATWO_TEST_INVALIDATE_NATIVE_MANIFEST_AFTER_LINK"
            )
            == repository["repositoryID"]
        )
        native_manifest = validate_native_skill_manifest(
            repository_root,
            repository["repositoryID"],
            test_invalidated=test_invalidated,
        )
        readbacks.append(
            {
                "repositoryID": repository["repositoryID"],
                "revisionID": repository["revisionID"],
                "contentDigest": digest,
                "fileCount": file_count,
                "byteCount": byte_count,
                "status": "verified",
                **native_manifest,
            }
        )
    target_preserved_readbacks: List[Dict[str, Any]] = []
    for repository in target_preserved:
        if repository["state"] != "runtime-preserved":
            target_preserved_readbacks.append(repository)
            continue
        repository_root = os.path.join(runtime_root, repository["repositoryID"])
        digest, file_count, byte_count = snapshot_digest(repository_root)
        if digest != repository["contentDigest"]:
            raise ProjectionError(
                "target-preserved runtime repository digest mismatch: "
                f"{repository['repositoryID']}"
            )
        test_invalidated = (
            post_link_validation
            and os.environ.get("TATWO_TEST_MODE") == "1"
            and os.environ.get(
                "TATWO_TEST_INVALIDATE_NATIVE_MANIFEST_AFTER_LINK"
            )
            == repository["repositoryID"]
        )
        native_manifest = validate_native_skill_manifest(
            repository_root,
            repository["repositoryID"],
            test_invalidated=test_invalidated,
        )
        target_preserved_readbacks.append(
            {
                "repositoryID": repository["repositoryID"],
                "revisionID": repository["revisionID"],
                "contentDigest": digest,
                "state": repository["state"],
                "fileCount": file_count,
                "byteCount": byte_count,
                "status": "verified",
                **native_manifest,
            }
        )
    manifest["_targetPreservedReadbacks"] = target_preserved_readbacks
    return readbacks


def binding_paths(consumer_root: str) -> Dict[str, str]:
    binding = os.path.join(consumer_root, ".tatwo-binding")
    return {
        "root": binding,
        "lock": os.path.join(binding, ".lock"),
        "journal": os.path.join(binding, "transaction.json"),
        "state": os.path.join(binding, "state.json"),
        "transactions": os.path.join(binding, "transactions"),
        "recovered": os.path.join(binding, "recovered"),
    }


@contextlib.contextmanager
def projection_lock(consumer_root: str) -> Iterable[Dict[str, str]]:
    paths = binding_paths(consumer_root)
    os.makedirs(paths["root"], exist_ok=True)
    descriptor = os.open(paths["lock"], os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield paths
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def archive_journal(paths: Dict[str, str], destination_root: str, suffix: str) -> str:
    os.makedirs(destination_root, exist_ok=True)
    destination = os.path.join(
        destination_root,
        f"{utc_now().replace(':', '').replace('-', '')}-{suffix}-{uuid.uuid4().hex}.json",
    )
    os.replace(paths["journal"], destination)
    fsync_directory(destination_root)
    return destination


def rollback_transaction(paths: Dict[str, str], journal: Dict[str, Any], reason: str) -> str:
    previous = journal.get("previous")
    if not isinstance(previous, dict):
        raise ProjectionError("projection transaction has no rollback snapshot")
    native_links = journal.get("nativeLinks")
    if not isinstance(native_links, list) or len(native_links) != 2:
        raise ProjectionError("projection transaction has invalid native links")
    restore_snapshot(journal["currentLink"], previous["current"])
    for native in native_links:
        restore_snapshot(native["path"], previous[native["consumerID"]])
    receipt_path = journal.get("receiptPath")
    if isinstance(receipt_path, str) and os.path.lexists(receipt_path):
        stale_receipt = f"{receipt_path}.rolled-back-{uuid.uuid4().hex}"
        os.replace(receipt_path, stale_receipt)
        fsync_directory(os.path.dirname(receipt_path))
        journal["rolledBackReceipt"] = stale_receipt
    journal["phase"] = "rolled-back"
    journal["recoveryReason"] = reason
    journal["recoveredAt"] = utc_now()
    atomic_write_json(paths["journal"], journal)
    return archive_journal(paths, paths["recovered"], "rolled-back")


def recover_locked(paths: Dict[str, str]) -> Optional[str]:
    if not os.path.lexists(paths["journal"]):
        return None
    if os.path.islink(paths["journal"]) or not os.path.isfile(paths["journal"]):
        raise ProjectionError("projection transaction journal is not a regular file")
    journal = read_json(paths["journal"])
    if journal.get("schema") != SCHEMA_TRANSACTION:
        raise ProjectionError("projection transaction journal schema is invalid")
    if journal.get("phase") == "committed":
        receipt_path = journal.get("receiptPath")
        if not isinstance(receipt_path, str) or not os.path.isfile(receipt_path):
            return rollback_transaction(paths, journal, "committed journal missing receipt")
        return archive_journal(paths, paths["transactions"], "committed-recovered")
    return rollback_transaction(paths, journal, "interrupted projection transaction")


def begin_transaction(
    paths: Dict[str, str],
    operation: str,
    desired_root: str,
    current_link: str,
    native_links: List[Dict[str, str]],
    receipt_path: str,
    request_id: Optional[str],
    set_manifest: Optional[Dict[str, Any]],
) -> Dict[str, Any]:
    if os.path.lexists(paths["journal"]):
        raise ProjectionError("projection transaction journal already exists")
    journal: Dict[str, Any] = {
        "schema": SCHEMA_TRANSACTION,
        "transactionID": f"projection-{uuid.uuid4().hex}",
        "operation": operation,
        "phase": "prepared",
        "desiredRoot": desired_root,
        "currentLink": current_link,
        "nativeLinks": native_links,
        "receiptPath": receipt_path,
        "requestID": request_id,
        "setManifestDigest": None if set_manifest is None else set_manifest["manifestDigest"],
        "previous": {
            "current": path_snapshot(current_link),
            native_links[0]["consumerID"]: path_snapshot(native_links[0]["path"]),
            native_links[1]["consumerID"]: path_snapshot(native_links[1]["path"]),
        },
        "createdAt": utc_now(),
        "updatedAt": utc_now(),
    }
    atomic_write_json(paths["journal"], journal)
    return journal


def update_journal(paths: Dict[str, str], journal: Dict[str, Any], phase: str) -> None:
    journal["phase"] = phase
    journal["updatedAt"] = utc_now()
    atomic_write_json(paths["journal"], journal)


def verify_projection(
    desired_root: str,
    consumer_root: str,
    codex_link: str,
    claude_link: str,
) -> None:
    current_link = os.path.join(consumer_root, "current")
    if not os.path.lexists(current_link) or not stat.S_ISLNK(os.lstat(current_link).st_mode):
        raise ProjectionError("managed consumer current is not a symlink")
    if normalized_link_target(current_link) != os.path.normpath(desired_root):
        raise ProjectionError("managed consumer current points to an unexpected root")
    require_symlink_to(codex_link, current_link, NATIVE_IDS[0])
    require_symlink_to(claude_link, current_link, NATIVE_IDS[1])
    expected_real = existing_realpath(desired_root)
    for consumer_id, link in zip(NATIVE_IDS, (codex_link, claude_link)):
        if existing_realpath(link) != expected_real:
            raise ProjectionError(f"{consumer_id} does not resolve to the desired root")


def write_receipt_and_state(
    paths: Dict[str, str],
    journal: Dict[str, Any],
    operation: str,
    desired_root: str,
    consumer_root: str,
    codex_link: str,
    claude_link: str,
    receipt_path: str,
    request_id: Optional[str],
    set_manifest: Optional[Dict[str, Any]],
    repository_readbacks: List[Dict[str, Any]],
    recovered_transaction: Optional[str],
) -> Dict[str, Any]:
    target_preserved_readbacks = (
        []
        if set_manifest is None
        else set_manifest.get("_targetPreservedReadbacks", [])
    )
    receipt: Dict[str, Any] = {
        "schema": SCHEMA_RECEIPT,
        "transactionID": journal["transactionID"],
        "operation": operation,
        "status": "passed",
        "requestID": request_id,
        "consumerRoot": consumer_root,
        "currentLink": os.path.join(consumer_root, "current"),
        "desiredRoot": desired_root,
        "desiredRootDigestMode": "skillet-snapshot-v1" if set_manifest else "source-bootstrap",
        "nativeConsumers": [
            {
                "consumerID": NATIVE_IDS[0],
                "linkPath": codex_link,
                "managedTarget": os.path.join(consumer_root, "current"),
                "resolvedRoot": existing_realpath(codex_link),
                "status": "bound",
            },
            {
                "consumerID": NATIVE_IDS[1],
                "linkPath": claude_link,
                "managedTarget": os.path.join(consumer_root, "current"),
                "resolvedRoot": existing_realpath(claude_link),
                "status": "bound",
            },
        ],
        "setManifestDigest": None if set_manifest is None else set_manifest["manifestDigest"],
        "catalogRevision": None if set_manifest is None else set_manifest["catalogRevision"],
        "authorityEpoch": None if set_manifest is None else set_manifest["authorityEpoch"],
        "ledgerSequence": None if set_manifest is None else set_manifest["ledgerSequence"],
        "repositoryCount": len(repository_readbacks),
        "repositories": repository_readbacks,
        "targetPreservedCount": len(target_preserved_readbacks),
        "targetPreservedRepositories": target_preserved_readbacks,
        "recoveredTransaction": recovered_transaction,
        "observedAt": utc_now(),
    }
    atomic_write_json(receipt_path, receipt, immutable=True)
    state = {
        "schema": SCHEMA_STATE,
        "status": "active",
        "mode": "runtime" if set_manifest else "source",
        "requestID": request_id,
        "consumerRoot": consumer_root,
        "currentLink": os.path.join(consumer_root, "current"),
        "desiredRoot": desired_root,
        "nativeConsumers": receipt["nativeConsumers"],
        "setManifestDigest": receipt["setManifestDigest"],
        "catalogRevision": receipt["catalogRevision"],
        "authorityEpoch": receipt["authorityEpoch"],
        "ledgerSequence": receipt["ledgerSequence"],
        "repositoryCount": receipt["repositoryCount"],
        "repositories": repository_readbacks,
        "targetPreservedCount": receipt["targetPreservedCount"],
        "targetPreservedRepositories": target_preserved_readbacks,
        "receiptPath": receipt_path,
        "updatedAt": receipt["observedAt"],
    }
    atomic_write_json(paths["state"], state)
    return receipt


def normalized_runtime_state_repositories(
    state: Dict[str, Any], runtime_root: str
) -> Dict[str, Any]:
    repositories = state.get("repositories")
    if not isinstance(repositories, list) or not repositories:
        raise ProjectionError("runtime projection state has no repository evidence")
    normalized: List[Dict[str, Any]] = []
    repository_ids: List[str] = []
    for repository in repositories:
        if not isinstance(repository, dict):
            raise ProjectionError("runtime projection state repository is invalid")
        repository_id = repository.get("repositoryID")
        revision_id = repository.get("revisionID")
        content_digest = repository.get("contentDigest")
        if (
            not isinstance(repository_id, str)
            or SAFE_IDENTIFIER.fullmatch(repository_id) is None
            or repository_id.startswith(".")
            or not isinstance(content_digest, str)
            or SHA256.fullmatch(content_digest) is None
            or revision_id != f"rev-{content_digest}"
        ):
            raise ProjectionError("runtime projection state repository identity is invalid")
        repository_ids.append(repository_id)
        normalized.append(
            {
                "repositoryID": repository_id,
                "revisionID": revision_id,
                "contentDigest": content_digest,
            }
        )
    if repository_ids != sorted(repository_ids, key=lambda item: item.encode("utf-8")):
        raise ProjectionError("runtime projection state repositories are not in portable order")
    if len(set(repository_ids)) != len(repository_ids):
        raise ProjectionError("runtime projection state contains duplicate repositories")
    has_target_preserved_count = "targetPreservedCount" in state
    has_target_preserved_repositories = "targetPreservedRepositories" in state
    if has_target_preserved_count != has_target_preserved_repositories:
        raise ProjectionError(
            "runtime projection state target-preserved evidence is partial"
        )
    target_preserved = (
        state["targetPreservedRepositories"]
        if has_target_preserved_repositories
        else []
    )
    target_preserved_count = (
        state["targetPreservedCount"] if has_target_preserved_count else 0
    )
    if (
        not isinstance(target_preserved, list)
        or not isinstance(target_preserved_count, int)
        or target_preserved_count != len(target_preserved)
    ):
        raise ProjectionError(
            "runtime projection state target-preserved evidence is invalid"
        )
    normalized_preserved: List[Dict[str, str]] = []
    preserved_ids: List[str] = []
    for repository in target_preserved:
        if not isinstance(repository, dict):
            raise ProjectionError(
                "runtime projection state target-preserved repository is invalid"
            )
        repository_id = repository.get("repositoryID")
        revision_id = repository.get("revisionID")
        content_digest = repository.get("contentDigest")
        preserved_state = repository.get("state")
        if (
            not isinstance(repository_id, str)
            or SAFE_IDENTIFIER.fullmatch(repository_id) is None
            or repository_id.startswith(".")
            or repository_id in repository_ids
            or not isinstance(content_digest, str)
            or SHA256.fullmatch(content_digest) is None
            or revision_id != f"rev-{content_digest}"
            or preserved_state not in ("store-preserved", "runtime-preserved")
        ):
            raise ProjectionError(
                "runtime projection state target-preserved identity is invalid"
            )
        preserved_ids.append(repository_id)
        normalized_preserved.append(
            {
                "repositoryID": repository_id,
                "revisionID": revision_id,
                "contentDigest": content_digest,
                "state": preserved_state,
            }
        )
    if len(set(preserved_ids)) != len(preserved_ids):
        raise ProjectionError(
            "runtime projection state target-preserved set contains duplicates"
        )
    if preserved_ids != sorted(preserved_ids, key=lambda item: item.encode("utf-8")):
        raise ProjectionError(
            "runtime projection state target-preserved repositories are not portable"
        )
    runtime_manifest: Dict[str, Any] = {
        "repositories": normalized,
        "targetPreservedRepositories": normalized_preserved,
    }
    readbacks = verify_runtime(runtime_root, runtime_manifest)
    if not repository_readback_lists_match(repositories, readbacks):
        raise ProjectionError("runtime projection state no longer matches the runtime root")
    preserved_readbacks = runtime_manifest.get("_targetPreservedReadbacks", [])
    if not repository_readback_lists_match(
        target_preserved, preserved_readbacks
    ):
        raise ProjectionError(
            "target-preserved runtime state no longer matches the runtime root"
        )
    return {
        "repositories": readbacks,
        "targetPreservedRepositories": preserved_readbacks,
    }


def load_runtime_adoption_evidence(
    paths: Dict[str, str], runtime_root: str
) -> Dict[str, Any]:
    if os.path.islink(paths["state"]) or not os.path.isfile(paths["state"]):
        raise ProjectionError(
            "runtime adoption requires an existing regular projection state"
        )
    state = read_json(paths["state"])
    if (
        state.get("schema") != SCHEMA_STATE
        or state.get("status") != "active"
        or state.get("mode") not in ("runtime", "runtime-adopted")
        or not isinstance(state.get("desiredRoot"), str)
        or existing_realpath(state["desiredRoot"]) != existing_realpath(runtime_root)
    ):
        raise ProjectionError(
            "runtime adoption state is not bound to the explicitly enrolled runtime root"
        )
    request_id = state.get("requestID")
    set_manifest_digest = state.get("setManifestDigest")
    catalog_revision = state.get("catalogRevision")
    authority_epoch = state.get("authorityEpoch")
    ledger_sequence = state.get("ledgerSequence")
    repository_count = state.get("repositoryCount")
    if (
        not isinstance(request_id, str)
        or not request_id
        or not isinstance(set_manifest_digest, str)
        or SHA256.fullmatch(set_manifest_digest) is None
        or not isinstance(catalog_revision, str)
        or not catalog_revision
        or not isinstance(authority_epoch, int)
        or authority_epoch < 1
        or not isinstance(ledger_sequence, int)
        or ledger_sequence < 1
        or not isinstance(repository_count, int)
        or repository_count < 1
    ):
        raise ProjectionError("runtime adoption state has invalid authority evidence")
    runtime_evidence = normalized_runtime_state_repositories(state, runtime_root)
    repositories = runtime_evidence["repositories"]
    target_preserved_repositories = runtime_evidence[
        "targetPreservedRepositories"
    ]
    if repository_count != len(repositories):
        raise ProjectionError("runtime adoption repository count does not match")

    if state["mode"] == "runtime":
        origin_receipt_path = state.get("receiptPath")
    else:
        origin_receipt_path = state.get("originActivationReceiptPath")
    if not isinstance(origin_receipt_path, str):
        raise ProjectionError("runtime adoption has no origin activation receipt")
    origin_receipt_path = require_absolute(
        origin_receipt_path, "origin activation receipt"
    )
    if os.path.islink(origin_receipt_path) or not os.path.isfile(origin_receipt_path):
        raise ProjectionError("runtime adoption origin activation receipt is unavailable")
    origin = read_json(origin_receipt_path)
    origin_has_target_preserved_count = "targetPreservedCount" in origin
    origin_has_target_preserved_repositories = (
        "targetPreservedRepositories" in origin
    )
    if (
        origin_has_target_preserved_count
        != origin_has_target_preserved_repositories
    ):
        raise ProjectionError(
            "runtime adoption origin activation receipt has partial "
            "target-preserved evidence"
        )
    if (
        not origin_has_target_preserved_count
        and target_preserved_repositories
    ):
        raise ProjectionError(
            "runtime adoption origin activation receipt omitted "
            "target-preserved repositories"
        )
    expected_origin = {
        "schema": SCHEMA_RECEIPT,
        "operation": "activate",
        "status": "passed",
        "requestID": request_id,
        "desiredRoot": state["desiredRoot"],
        "desiredRootDigestMode": "skillet-snapshot-v1",
        "setManifestDigest": set_manifest_digest,
        "catalogRevision": catalog_revision,
        "authorityEpoch": authority_epoch,
        "ledgerSequence": ledger_sequence,
        "repositoryCount": repository_count,
    }
    if origin_has_target_preserved_count:
        expected_origin["targetPreservedCount"] = len(
            target_preserved_repositories
        )
    if any(origin.get(key) != value for key, value in expected_origin.items()):
        raise ProjectionError("runtime adoption origin activation receipt does not match")
    if not repository_readback_lists_match(
        origin.get("repositories"), repositories
    ):
        raise ProjectionError(
            "runtime adoption origin activation repository evidence does not match"
        )
    if origin_has_target_preserved_count and not repository_readback_lists_match(
        origin.get("targetPreservedRepositories"),
        target_preserved_repositories,
    ):
        raise ProjectionError(
            "runtime adoption origin activation target-preserved evidence does not match"
        )
    return {
        "requestID": request_id,
        "setManifestDigest": set_manifest_digest,
        "catalogRevision": catalog_revision,
        "authorityEpoch": authority_epoch,
        "ledgerSequence": ledger_sequence,
        "repositoryCount": repository_count,
        "repositories": repositories,
        "targetPreservedCount": len(target_preserved_repositories),
        "targetPreservedRepositories": target_preserved_repositories,
        "originActivationReceiptPath": origin_receipt_path,
        "previousStateDigest": sha256_file(paths["state"]),
        "previousMode": state["mode"],
    }


def write_runtime_adoption_receipt_and_state(
    paths: Dict[str, str],
    journal: Dict[str, Any],
    source_root: str,
    runtime_root: str,
    consumer_root: str,
    codex_link: str,
    claude_link: str,
    receipt_path: str,
    evidence: Dict[str, Any],
    recovered_transaction: Optional[str],
) -> Dict[str, Any]:
    current_link = os.path.join(consumer_root, "current")
    receipt: Dict[str, Any] = {
        "schema": SCHEMA_RECEIPT,
        "transactionID": journal["transactionID"],
        "operation": "adopt-runtime",
        "status": "passed",
        "requestID": evidence["requestID"],
        "consumerRoot": consumer_root,
        "currentLink": current_link,
        "desiredRoot": runtime_root,
        "desiredRootDigestMode": "runtime-adoption-v1",
        "enrollmentSourceRoot": source_root,
        "nativeConsumers": [
            {
                "consumerID": NATIVE_IDS[0],
                "linkPath": codex_link,
                "managedTarget": current_link,
                "resolvedRoot": existing_realpath(codex_link),
                "status": "bound",
            },
            {
                "consumerID": NATIVE_IDS[1],
                "linkPath": claude_link,
                "managedTarget": current_link,
                "resolvedRoot": existing_realpath(claude_link),
                "status": "bound",
            },
        ],
        "setManifestDigest": evidence["setManifestDigest"],
        "catalogRevision": evidence["catalogRevision"],
        "authorityEpoch": evidence["authorityEpoch"],
        "ledgerSequence": evidence["ledgerSequence"],
        "repositoryCount": evidence["repositoryCount"],
        "repositories": evidence["repositories"],
        "targetPreservedCount": evidence["targetPreservedCount"],
        "targetPreservedRepositories": evidence["targetPreservedRepositories"],
        "originActivationReceiptPath": evidence["originActivationReceiptPath"],
        "adoptedFromStateDigest": evidence["previousStateDigest"],
        "adoptedFromMode": evidence["previousMode"],
        "recoveredTransaction": recovered_transaction,
        "observedAt": utc_now(),
    }
    atomic_write_json(receipt_path, receipt, immutable=True)
    state = {
        "schema": SCHEMA_STATE,
        "status": "active",
        "mode": "runtime-adopted",
        "requestID": evidence["requestID"],
        "consumerRoot": consumer_root,
        "currentLink": current_link,
        "desiredRoot": runtime_root,
        "enrollmentSourceRoot": source_root,
        "nativeConsumers": receipt["nativeConsumers"],
        "setManifestDigest": evidence["setManifestDigest"],
        "catalogRevision": evidence["catalogRevision"],
        "authorityEpoch": evidence["authorityEpoch"],
        "ledgerSequence": evidence["ledgerSequence"],
        "repositoryCount": evidence["repositoryCount"],
        "repositories": evidence["repositories"],
        "targetPreservedCount": evidence["targetPreservedCount"],
        "targetPreservedRepositories": evidence["targetPreservedRepositories"],
        "originActivationReceiptPath": evidence["originActivationReceiptPath"],
        "receiptPath": receipt_path,
        "updatedAt": receipt["observedAt"],
    }
    atomic_write_json(paths["state"], state)
    return receipt


def perform_runtime_adoption(
    source_root: str,
    runtime_root: str,
    consumer_root: str,
    codex_link: str,
    claude_link: str,
    receipt_path: str,
) -> Dict[str, Any]:
    validate_roots(
        source_root, consumer_root, codex_link, claude_link, "source root"
    )
    validate_roots(
        runtime_root, consumer_root, codex_link, claude_link, "runtime root"
    )
    if paths_overlap(source_root, runtime_root):
        raise ProjectionError("source root overlaps runtime root")
    if not has_skill_manifest(source_root):
        raise ProjectionError("source root contains no managed SKILL.md")
    if not has_skill_manifest(runtime_root):
        raise ProjectionError("runtime root contains no managed SKILL.md")
    receipt_path = require_absolute(receipt_path, "receipt")
    current_link = os.path.join(consumer_root, "current")
    native_links = [
        {"consumerID": NATIVE_IDS[0], "path": codex_link},
        {"consumerID": NATIVE_IDS[1], "path": claude_link},
    ]
    with projection_lock(consumer_root) as paths:
        recovered_transaction = recover_locked(paths)
        if not os.path.lexists(current_link) or not stat.S_ISLNK(
            os.lstat(current_link).st_mode
        ):
            raise ProjectionError(
                "runtime adoption requires managed current to be a symlink"
            )
        if existing_realpath(current_link) != existing_realpath(runtime_root):
            raise ProjectionError(
                "managed current does not resolve to the explicitly enrolled runtime root"
            )
        evidence = load_runtime_adoption_evidence(paths, runtime_root)
        allowed_roots = {
            existing_realpath(source_root),
            existing_realpath(runtime_root),
        }
        for native in native_links:
            snapshot = path_snapshot(native["path"])
            if snapshot["kind"] == "symlink":
                points_managed = (
                    normalized_link_target(native["path"])
                    == os.path.normpath(current_link)
                )
                resolves_known = existing_realpath(native["path"]) in allowed_roots
                if not points_managed and not resolves_known:
                    raise ProjectionError(
                        f"{native['consumerID']} existing symlink points to an unknown root"
                    )
        journal = begin_transaction(
            paths,
            "adopt-runtime",
            runtime_root,
            current_link,
            native_links,
            receipt_path,
            evidence["requestID"],
            None,
        )
        try:
            atomic_symlink(current_link, runtime_root)
            update_journal(paths, journal, "current-canonicalized")
            for native in native_links:
                atomic_symlink(native["path"], current_link)
            update_journal(paths, journal, "native-links-reprojected")
            verify_projection(
                runtime_root, consumer_root, codex_link, claude_link
            )
            if normalized_runtime_state_repositories(
                read_json(paths["state"]), runtime_root
            ) != {
                "repositories": evidence["repositories"],
                "targetPreservedRepositories": evidence[
                    "targetPreservedRepositories"
                ],
            }:
                raise ProjectionError("runtime changed during adoption")
            receipt = write_runtime_adoption_receipt_and_state(
                paths,
                journal,
                source_root,
                runtime_root,
                consumer_root,
                codex_link,
                claude_link,
                receipt_path,
                evidence,
                recovered_transaction,
            )
            update_journal(paths, journal, "committed")
            archive_journal(paths, paths["transactions"], "committed")
            return receipt
        except Exception:
            if os.path.lexists(paths["journal"]):
                rollback_transaction(
                    paths, read_json(paths["journal"]), "runtime adoption failed"
                )
            raise


def perform_enrollment(
    source_root: str,
    runtime_root: str,
    consumer_root: str,
    codex_link: str,
    claude_link: str,
    receipt_path: str,
) -> Dict[str, Any]:
    validate_roots(
        source_root, consumer_root, codex_link, claude_link, "source root"
    )
    validate_roots(
        runtime_root,
        consumer_root,
        codex_link,
        claude_link,
        "runtime root",
        require_existing_directory=False,
    )
    if paths_overlap(source_root, runtime_root):
        raise ProjectionError("source root overlaps runtime root")
    current_link = os.path.join(consumer_root, "current")
    if not os.path.lexists(current_link):
        return perform_projection(
            "bootstrap",
            source_root,
            consumer_root,
            codex_link,
            claude_link,
            receipt_path,
            None,
            None,
        )
    if not stat.S_ISLNK(os.lstat(current_link).st_mode):
        raise ProjectionError("managed consumer current is not a symlink")
    current_resolved = existing_realpath(current_link)
    if current_resolved == existing_realpath(source_root):
        return perform_projection(
            "bootstrap",
            source_root,
            consumer_root,
            codex_link,
            claude_link,
            receipt_path,
            None,
            None,
        )
    if current_resolved == existing_realpath(runtime_root):
        return perform_runtime_adoption(
            source_root,
            runtime_root,
            consumer_root,
            codex_link,
            claude_link,
            receipt_path,
        )
    raise ProjectionError(
        "existing managed current points to neither enrolled source nor runtime root"
    )


def validate_existing_projection_receipt(
    paths: Dict[str, str],
    operation: str,
    desired_root: str,
    consumer_root: str,
    codex_link: str,
    claude_link: str,
    receipt_path: str,
    request_id: Optional[str],
    set_manifest: Optional[Dict[str, Any]],
    repository_readbacks: List[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    if not os.path.lexists(receipt_path):
        return None
    if os.path.islink(receipt_path) or not os.path.isfile(receipt_path):
        raise ProjectionError(f"immutable receipt is not a regular file: {receipt_path}")

    verify_projection(desired_root, consumer_root, codex_link, claude_link)
    verified_repositories = (
        verify_runtime(desired_root, set_manifest) if set_manifest is not None else []
    )
    target_preserved_readbacks = (
        []
        if set_manifest is None
        else set_manifest.get("_targetPreservedReadbacks", [])
    )
    if not repository_readback_lists_match(
        verified_repositories, repository_readbacks
    ):
        raise ProjectionError("existing projection repository readback changed")

    current_link = os.path.join(consumer_root, "current")
    expected_native_consumers = [
        {
            "consumerID": NATIVE_IDS[0],
            "linkPath": codex_link,
            "managedTarget": current_link,
            "resolvedRoot": existing_realpath(codex_link),
            "status": "bound",
        },
        {
            "consumerID": NATIVE_IDS[1],
            "linkPath": claude_link,
            "managedTarget": current_link,
            "resolvedRoot": existing_realpath(claude_link),
            "status": "bound",
        },
    ]
    expected_scalars = {
        "schema": SCHEMA_RECEIPT,
        "operation": operation,
        "status": "passed",
        "requestID": request_id,
        "consumerRoot": consumer_root,
        "currentLink": current_link,
        "desiredRoot": desired_root,
        "desiredRootDigestMode": (
            "skillet-snapshot-v1" if set_manifest is not None else "source-bootstrap"
        ),
        "setManifestDigest": (
            None if set_manifest is None else set_manifest["manifestDigest"]
        ),
        "catalogRevision": (
            None if set_manifest is None else set_manifest["catalogRevision"]
        ),
        "authorityEpoch": (
            None if set_manifest is None else set_manifest["authorityEpoch"]
        ),
        "ledgerSequence": (
            None if set_manifest is None else set_manifest["ledgerSequence"]
        ),
        "repositoryCount": len(repository_readbacks),
        "targetPreservedCount": len(target_preserved_readbacks),
    }
    receipt = read_json(receipt_path)
    if any(receipt.get(key) != value for key, value in expected_scalars.items()):
        raise ProjectionError("immutable projection receipt binding does not match request")
    if receipt.get("nativeConsumers") != expected_native_consumers:
        raise ProjectionError("immutable projection receipt native consumers do not match")
    if not repository_readback_lists_match(
        receipt.get("repositories"), repository_readbacks
    ):
        raise ProjectionError("immutable projection receipt repository set does not match")
    if not repository_readback_lists_match(
        receipt.get("targetPreservedRepositories"),
        target_preserved_readbacks,
    ):
        raise ProjectionError(
            "immutable projection receipt target-preserved set does not match"
        )
    transaction_id = receipt.get("transactionID")
    observed_at = receipt.get("observedAt")
    if not isinstance(transaction_id, str) or not transaction_id.startswith("projection-"):
        raise ProjectionError("immutable projection receipt transaction id is invalid")
    if not isinstance(observed_at, str) or not observed_at:
        raise ProjectionError("immutable projection receipt observedAt is invalid")

    if os.path.islink(paths["state"]) or not os.path.isfile(paths["state"]):
        raise ProjectionError("projection state is missing or not a regular file")
    state = read_json(paths["state"])
    expected_state = {
        "schema": SCHEMA_STATE,
        "status": "active",
        "mode": "runtime" if set_manifest is not None else "source",
        "requestID": request_id,
        "consumerRoot": consumer_root,
        "currentLink": current_link,
        "desiredRoot": desired_root,
        "nativeConsumers": expected_native_consumers,
        "setManifestDigest": expected_scalars["setManifestDigest"],
        "catalogRevision": expected_scalars["catalogRevision"],
        "authorityEpoch": expected_scalars["authorityEpoch"],
        "ledgerSequence": expected_scalars["ledgerSequence"],
        "repositoryCount": len(repository_readbacks),
        "repositories": repository_readbacks,
        "targetPreservedCount": len(target_preserved_readbacks),
        "targetPreservedRepositories": target_preserved_readbacks,
        "receiptPath": receipt_path,
        "updatedAt": observed_at,
    }
    if not projection_state_matches(state, expected_state):
        raise ProjectionError("projection state does not match immutable receipt")
    return receipt


def perform_projection(
    operation: str,
    desired_root: str,
    consumer_root: str,
    codex_link: str,
    claude_link: str,
    receipt_path: str,
    request_id: Optional[str],
    set_manifest_path: Optional[str],
    activation_receipt_path: Optional[str] = None,
) -> Dict[str, Any]:
    desired_field = "runtime root" if operation == "activate" else "source root"
    validate_roots(desired_root, consumer_root, codex_link, claude_link, desired_field)
    if operation == "bootstrap" and not has_skill_manifest(desired_root):
        raise ProjectionError("source root contains no managed SKILL.md")
    set_manifest = (
        load_set_manifest(
            set_manifest_path,
            request_id,
            activation_receipt_path,
        )
        if set_manifest_path is not None
        else None
    )
    repository_readbacks = (
        verify_runtime(desired_root, set_manifest) if set_manifest is not None else []
    )
    current_link = os.path.join(consumer_root, "current")
    native_links = [
        {"consumerID": NATIVE_IDS[0], "path": codex_link},
        {"consumerID": NATIVE_IDS[1], "path": claude_link},
    ]
    receipt_path = require_absolute(receipt_path, "receipt")
    with projection_lock(consumer_root) as paths:
        recovered_transaction = recover_locked(paths)
        existing_receipt = validate_existing_projection_receipt(
            paths,
            operation,
            desired_root,
            consumer_root,
            codex_link,
            claude_link,
            receipt_path,
            request_id,
            set_manifest,
            repository_readbacks,
        )
        if existing_receipt is not None:
            return existing_receipt
        for native in native_links:
            snapshot = path_snapshot(native["path"])
            if operation == "bootstrap" and snapshot["kind"] == "symlink":
                raw_managed = os.path.normpath(current_link)
                resolves_source = existing_realpath(native["path"]) == existing_realpath(desired_root)
                points_managed = normalized_link_target(native["path"]) == raw_managed
                if not resolves_source and not points_managed:
                    raise ProjectionError(
                        f"{native['consumerID']} existing symlink points to an unknown root"
                    )
            elif operation == "activate":
                require_symlink_to(native["path"], current_link, native["consumerID"])
        if os.path.lexists(current_link):
            if not stat.S_ISLNK(os.lstat(current_link).st_mode):
                raise ProjectionError("managed consumer current is not a symlink")
            if operation == "bootstrap":
                current_resolves_source = (
                    existing_realpath(current_link) == existing_realpath(desired_root)
                )
                if not current_resolves_source:
                    raise ProjectionError("existing managed current points to an unknown root")
        journal = begin_transaction(
            paths,
            operation,
            desired_root,
            current_link,
            native_links,
            receipt_path,
            request_id,
            set_manifest,
        )
        try:
            atomic_symlink(current_link, desired_root)
            update_journal(paths, journal, "current-swapped")
            if (
                os.environ.get("TATWO_TEST_MODE") == "1"
                and os.environ.get("TATWO_TEST_CRASH_AFTER_CURRENT_SWAP") == "1"
            ):
                os._exit(86)
            for native in native_links:
                atomic_symlink(native["path"], current_link)
            update_journal(paths, journal, "native-links-bound")
            verify_projection(
                desired_root, consumer_root, codex_link, claude_link
            )
            if set_manifest is not None:
                repository_readbacks = verify_runtime(
                    desired_root,
                    set_manifest,
                    post_link_validation=True,
                )
            receipt = write_receipt_and_state(
                paths,
                journal,
                operation,
                desired_root,
                consumer_root,
                codex_link,
                claude_link,
                receipt_path,
                request_id,
                set_manifest,
                repository_readbacks,
                recovered_transaction,
            )
            update_journal(paths, journal, "committed")
            archive_journal(paths, paths["transactions"], "committed")
            return receipt
        except Exception:
            if os.path.lexists(paths["journal"]):
                rollback_transaction(paths, read_json(paths["journal"]), "projection failed")
            raise


def verify_command(args: argparse.Namespace) -> Dict[str, Any]:
    expected_root = require_absolute(args.expected_root, "expected root")
    consumer_root = require_absolute(args.consumer_root, "consumer root")
    codex_link = require_absolute(args.codex_skills_link, "Codex skills link")
    claude_link = require_absolute(args.claude_skills_link, "Claude skills link")
    receipt_path = require_absolute(args.receipt, "receipt")
    validate_roots(expected_root, consumer_root, codex_link, claude_link, "expected root")
    manifest = (
        load_set_manifest(
            args.set_manifest,
            args.request,
            args.activation_receipt,
        )
        if args.set_manifest is not None
        else None
    )
    with projection_lock(consumer_root) as paths:
        recovered_transaction = recover_locked(paths)
        verify_projection(expected_root, consumer_root, codex_link, claude_link)
        repositories = verify_runtime(expected_root, manifest) if manifest else []
        target_preserved_repositories = (
            []
            if manifest is None
            else manifest.get("_targetPreservedReadbacks", [])
        )
        receipt = {
            "schema": SCHEMA_RECEIPT,
            "transactionID": None,
            "operation": "verify",
            "status": "passed",
            "requestID": args.request,
            "consumerRoot": consumer_root,
            "currentLink": os.path.join(consumer_root, "current"),
            "desiredRoot": expected_root,
            "nativeConsumers": [
                {
                    "consumerID": NATIVE_IDS[0],
                    "linkPath": codex_link,
                    "managedTarget": os.path.join(consumer_root, "current"),
                    "resolvedRoot": existing_realpath(codex_link),
                    "status": "bound",
                },
                {
                    "consumerID": NATIVE_IDS[1],
                    "linkPath": claude_link,
                    "managedTarget": os.path.join(consumer_root, "current"),
                    "resolvedRoot": existing_realpath(claude_link),
                    "status": "bound",
                },
            ],
            "setManifestDigest": None if manifest is None else manifest["manifestDigest"],
            "catalogRevision": None if manifest is None else manifest["catalogRevision"],
            "authorityEpoch": None if manifest is None else manifest["authorityEpoch"],
            "ledgerSequence": None if manifest is None else manifest["ledgerSequence"],
            "repositoryCount": len(repositories),
            "repositories": repositories,
            "targetPreservedCount": len(target_preserved_repositories),
            "targetPreservedRepositories": target_preserved_repositories,
            "recoveredTransaction": recovered_transaction,
            "observedAt": utc_now(),
        }
        atomic_write_json(receipt_path, receipt, immutable=True)
        return receipt


def recover_command(args: argparse.Namespace) -> Dict[str, Any]:
    consumer_root = require_absolute(args.consumer_root, "consumer root")
    with projection_lock(consumer_root) as paths:
        recovered = recover_locked(paths)
    return {
        "schema": SCHEMA_RECEIPT,
        "operation": "recover",
        "status": "passed",
        "consumerRoot": consumer_root,
        "recoveredTransaction": recovered,
        "observedAt": utc_now(),
    }


def add_projection_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--consumer-root", required=True)
    parser.add_argument("--codex-skills-link", required=True)
    parser.add_argument("--claude-skills-link", required=True)
    parser.add_argument("--receipt", required=True)


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Manage durable Skillet native-consumer projection"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    bootstrap = subparsers.add_parser("bootstrap")
    bootstrap.add_argument("--source-root", required=True)
    add_projection_arguments(bootstrap)

    enroll = subparsers.add_parser("enroll")
    enroll.add_argument("--source-root", required=True)
    enroll.add_argument("--runtime-root", required=True)
    add_projection_arguments(enroll)

    activate = subparsers.add_parser("activate")
    activate.add_argument("--runtime-root", required=True)
    activate.add_argument("--set-manifest", required=True)
    activate.add_argument("--activation-receipt", required=True)
    activate.add_argument("--request", required=True)
    add_projection_arguments(activate)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--expected-root", required=True)
    verify.add_argument("--set-manifest")
    verify.add_argument("--activation-receipt")
    verify.add_argument("--request")
    add_projection_arguments(verify)

    recover = subparsers.add_parser("recover")
    recover.add_argument("--consumer-root", required=True)
    return parser


def main(argv: List[str]) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "bootstrap":
            receipt = perform_projection(
                "bootstrap",
                require_absolute(args.source_root, "source root"),
                require_absolute(args.consumer_root, "consumer root"),
                require_absolute(args.codex_skills_link, "Codex skills link"),
                require_absolute(args.claude_skills_link, "Claude skills link"),
                args.receipt,
                None,
                None,
            )
        elif args.command == "enroll":
            receipt = perform_enrollment(
                require_absolute(args.source_root, "source root"),
                require_absolute(args.runtime_root, "runtime root"),
                require_absolute(args.consumer_root, "consumer root"),
                require_absolute(args.codex_skills_link, "Codex skills link"),
                require_absolute(args.claude_skills_link, "Claude skills link"),
                args.receipt,
            )
        elif args.command == "activate":
            receipt = perform_projection(
                "activate",
                require_absolute(args.runtime_root, "runtime root"),
                require_absolute(args.consumer_root, "consumer root"),
                require_absolute(args.codex_skills_link, "Codex skills link"),
                require_absolute(args.claude_skills_link, "Claude skills link"),
                args.receipt,
                args.request,
                args.set_manifest,
                args.activation_receipt,
            )
        elif args.command == "verify":
            receipt = verify_command(args)
        elif args.command == "recover":
            receipt = recover_command(args)
        else:
            raise ProjectionError(f"unsupported command: {args.command}")
    except ProjectionError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(receipt, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
