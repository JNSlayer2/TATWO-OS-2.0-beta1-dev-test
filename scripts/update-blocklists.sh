#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
output_dir="${1:-$repo_root/Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/Resources/BrowserBlocklists}"

python3 - "$output_dir" <<'PY'
from __future__ import annotations

import datetime as dt
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import sys
import urllib.request

OUTPUT_DIR = pathlib.Path(sys.argv[1])
LIST_NAME = "browser-host-deny-list.json"
MANIFEST_NAME = "browser-blocklists-manifest.json"
PARSER_VERSION = "TatwoHostSubsetV1"
USER_AGENT = "Tatwo-Ultrawork-Blocklist-Updater/1"

SOURCES = (
    {
        "id": "easylist",
        "url": "https://easylist.to/easylist/easylist.txt",
        "format": "abp",
        "minimumAccepted": 10_000,
    },
    {
        "id": "easyprivacy",
        "url": "https://easylist.to/easylist/easyprivacy.txt",
        "format": "abp",
        "minimumAccepted": 10_000,
    },
    {
        "id": "urlhaus",
        "url": "https://urlhaus.abuse.ch/downloads/hostfile/",
        "format": "hosts",
        "minimumAccepted": 50,
    },
    {
        "id": "brave-firstparty-cname",
        "url": (
            "https://raw.githubusercontent.com/brave/adblock-lists/"
            "master/brave-lists/brave-firstparty-cname.txt"
        ),
        "format": "abp",
        "minimumAccepted": 100,
    },
)

ABP_HOST_RULE = re.compile(
    r"^\|\|([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)\^$"
)
HOSTS_LINE = re.compile(r"^(?:0\.0\.0\.0|127\.0\.0\.1)\s+(.+)$")
DNS_HOST = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"
)


def canonical_host(raw: str) -> str | None:
    host = raw.strip().lower().rstrip(".")
    if "." not in host or len(host) > 253 or not DNS_HOST.fullmatch(host):
        return None
    labels = host.split(".")
    if any(
        not label
        or len(label) > 63
        or label.startswith("-")
        or label.endswith("-")
        for label in labels
    ):
        return None
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return host
    return None


def extract_version(text: str, source_sha256: str) -> str:
    for raw in text.splitlines()[:80]:
        line = raw.strip().lstrip("!#").strip()
        lowered = line.lower()
        if lowered.startswith(("version:", "last updated:", "last modified:")):
            return line.split(":", 1)[1].strip().rstrip("#").strip()
    return f"sha256:{source_sha256}"


def extract_hosts(text: str, source_format: str) -> set[str]:
    hosts: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("!", "#", "[", "@@")):
            continue
        candidates: list[str] = []
        if source_format == "abp":
            match = ABP_HOST_RULE.fullmatch(line)
            if match:
                candidates.append(match.group(1))
        elif source_format == "hosts":
            match = HOSTS_LINE.match(line)
            if match:
                candidates.extend(
                    token
                    for token in match.group(1).split()
                    if not token.startswith("#")
                )
        for candidate in candidates:
            host = canonical_host(candidate)
            if host is not None:
                hosts.add(host)
    return hosts


def fetch(source: dict[str, object]) -> tuple[bytes, dict[str, str]]:
    request = urllib.request.Request(
        str(source["url"]),
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/plain, application/octet-stream;q=0.9, */*;q=0.1",
        },
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        body = response.read()
        headers = {
            key.lower(): value
            for key, value in response.headers.items()
        }
    if not body:
        raise RuntimeError(f"{source['id']}: empty response")
    return body, headers


def atomic_write(path: pathlib.Path, payload: bytes) -> None:
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    with temporary.open("wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    generated_at = (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    combined_suffixes: set[str] = set()
    source_receipts: list[dict[str, object]] = []

    for source in SOURCES:
        body, headers = fetch(source)
        source_sha256 = hashlib.sha256(body).hexdigest()
        text = body.decode("utf-8", errors="replace")
        accepted = extract_hosts(text, str(source["format"]))
        minimum = int(source["minimumAccepted"])
        if len(accepted) < minimum:
            raise RuntimeError(
                f"{source['id']}: accepted {len(accepted)} hosts, "
                f"expected at least {minimum}; refusing format drift"
            )
        combined_suffixes.update(accepted)
        source_receipts.append(
            {
                "id": source["id"],
                "url": source["url"],
                "format": source["format"],
                "version": extract_version(text, source_sha256),
                "retrievedAt": generated_at,
                "lastModified": headers.get("last-modified"),
                "etag": headers.get("etag"),
                "sha256": source_sha256,
                "acceptedSuffixCount": len(accepted),
            }
        )

    list_document = {
        "schema": "TatwoBrowserHostDenyListV1",
        "exactHosts": [],
        "suffixes": sorted(combined_suffixes),
    }
    list_payload = (
        json.dumps(
            list_document,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")
    list_sha256 = hashlib.sha256(list_payload).hexdigest()

    manifest = {
        "schema": "TatwoBrowserBlocklistManifestV1",
        "generatedAt": generated_at,
        "parser": {
            "version": PARSER_VERSION,
            "acceptedSyntax": [
                "ABP unconditional ||host^ rules without options",
                "hosts-file 0.0.0.0/127.0.0.1 host entries",
            ],
            "semantics": (
                "host-level suffix blocking only; exceptions, options, "
                "paths, regex, cosmetic filters, redirects, and scriptlets "
                "are deliberately excluded for Phase 2a"
            ),
        },
        "sources": source_receipts,
        "output": {
            "file": LIST_NAME,
            "sha256": list_sha256,
            "bytes": len(list_payload),
            "exactCount": 0,
            "suffixCount": len(combined_suffixes),
        },
    }
    manifest_payload = (
        json.dumps(
            manifest,
            ensure_ascii=True,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")

    atomic_write(OUTPUT_DIR / LIST_NAME, list_payload)
    atomic_write(OUTPUT_DIR / MANIFEST_NAME, manifest_payload)
    print(
        json.dumps(
            {
                "ok": True,
                "outputDir": str(OUTPUT_DIR),
                "listSHA256": list_sha256,
                "suffixCount": len(combined_suffixes),
                "sourceCount": len(source_receipts),
                "generatedAt": generated_at,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
PY
