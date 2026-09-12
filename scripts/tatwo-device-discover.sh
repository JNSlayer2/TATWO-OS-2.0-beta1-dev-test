#!/usr/bin/env bash
# tatwo-device-discover.sh — Plug-and-Manage S1 read-only discovery prototype
#
# Iron rules (D11 / PLUG_AND_MANAGE_DESIGN.md §1.3, §3.4):
#   - Discovery only: never pair, never enroll/pin, never execute on a device.
#   - trustState is always "untrusted".
#   - Serials / stable IDs are hashed (SHA-256); raw serials never appear in output.
#   - No writes to attached devices; no privileged/TCC-gated APIs (null if needed).
#
# Usage:
#   bash scripts/tatwo-device-discover.sh
#   bash scripts/tatwo-device-discover.sh --selftest
#   bash scripts/tatwo-device-discover.sh --bonjour-timeout 6
#
# Live probes (macOS built-in, read-only):
#   system_profiler SPThunderboltDataType SPUSBDataType SPUSBHostDataType -json
#   dns-sd -t <seconds> -B <service> local   (default 6s; do not use only 2s)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SELFTEST=0
BONJOUR_TIMEOUT=6
FIXTURE_DIR="${TATWO_DEVICE_DISCOVER_FIXTURE_DIR:-$ROOT_DIR/tests/fixtures/device-discover}"
# Optional overrides for tests / offline parsing.
PROFILER_JSON_FILE="${TATWO_DEVICE_DISCOVER_PROFILER_JSON:-}"
DNS_SD_TEXT_FILE="${TATWO_DEVICE_DISCOVER_DNS_SD_TEXT:-}"
SKIP_LIVE_BONJOUR=0
SKIP_LIVE_PROFILER=0

usage() {
  cat <<'EOF'
用法：
  bash scripts/tatwo-device-discover.sh
  bash scripts/tatwo-device-discover.sh --selftest
  bash scripts/tatwo-device-discover.sh --bonjour-timeout SECONDS

輸出 JSON（stdout）：
  {
    "schema": "TatwoDeviceDiscoveryReportV1",
    "stage": "discovery-only",
    "nextStep": "requires-pairing-code",
    "devices": [ TatwoDiscoveredDeviceV1, ... ],
    "notes": [ string, ... ]
  }

每個 device：
  transport, name, identityFingerprint, interfaces[], capabilitiesObserved[],
  storageGB?, cpuGpuMemory?, powerThermal?, trustState="untrusted"

S1 不提供配對／納管；canBeManaged 語意在 Core 型別恆為 false。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --selftest)
      SELFTEST=1
      shift
      ;;
    --bonjour-timeout)
      BONJOUR_TIMEOUT="${2:-}"
      if ! [[ "$BONJOUR_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$BONJOUR_TIMEOUT" -lt 1 ]]; then
        printf 'invalid --bonjour-timeout: %s\n' "${2:-}" >&2
        exit 2
      fi
      shift 2
      ;;
    --profiler-json)
      PROFILER_JSON_FILE="${2:-}"
      SKIP_LIVE_PROFILER=1
      shift 2
      ;;
    --dns-sd-text)
      DNS_SD_TEXT_FILE="${2:-}"
      SKIP_LIVE_BONJOUR=1
      shift 2
      ;;
    --fixture-dir)
      FIXTURE_DIR="${2:-}"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SELFTEST" -eq 1 ]]; then
  # Selftest uses fixtures only (no live IO / no device contact).
  SKIP_LIVE_BONJOUR=1
  SKIP_LIVE_PROFILER=1
fi

export ROOT_DIR FIXTURE_DIR PROFILER_JSON_FILE DNS_SD_TEXT_FILE
export SKIP_LIVE_BONJOUR SKIP_LIVE_PROFILER BONJOUR_TIMEOUT SELFTEST

# shellcheck disable=SC2016
python3 - <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(os.environ["ROOT_DIR"])
FIXTURE_DIR = Path(os.environ["FIXTURE_DIR"])
SELFTEST = os.environ.get("SELFTEST", "0") == "1"
SKIP_LIVE_PROFILER = os.environ.get("SKIP_LIVE_PROFILER", "0") == "1"
SKIP_LIVE_BONJOUR = os.environ.get("SKIP_LIVE_BONJOUR", "0") == "1"
BONJOUR_TIMEOUT = int(os.environ.get("BONJOUR_TIMEOUT", "6"))
PROFILER_JSON_FILE = os.environ.get("PROFILER_JSON_FILE") or ""
DNS_SD_TEXT_FILE = os.environ.get("DNS_SD_TEXT_FILE") or ""

SCHEMA_DEVICE = "TatwoDiscoveredDeviceV1"
SCHEMA_REPORT = "TatwoDeviceDiscoveryReportV1"
STAGE = "discovery-only"
NEXT_STEP = "requires-pairing-code"
TRUST = "untrusted"

# Service types browsed for Bonjour discovery (local mDNS only; no WAN).
BONJOUR_TYPES = (
    "_workstation._tcp",
    "_ssh._tcp",
    "_sftp-ssh._tcp",
)


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def normalize_id(value: Any) -> str:
    if value is None:
        return ""
    s = str(value).strip()
    # system_profiler sometimes returns "0x05ac  (Apple)" — keep hex token only.
    m = re.match(r"(0x[0-9a-fA-F]+)", s)
    if m:
        return m.group(1).lower()
    return s.lower()


def first_str(node: dict[str, Any], keys: tuple[str, ...]) -> str:
    for key in keys:
        if key in node and node[key] is not None:
            val = node[key]
            if isinstance(val, (str, int, float)):
                s = str(val).strip()
                if s:
                    return s
    return ""


def identity_fingerprint(
    transport: str,
    vendor: str,
    product: str,
    serial: str,
    name: str,
) -> str:
    """Hash stable IDs; never emit raw serial. No serial → unstable: prefix."""
    vendor_n = normalize_id(vendor)
    product_n = normalize_id(product)
    serial_n = (serial or "").strip()
    name_n = (name or "").strip()
    if serial_n:
        material = f"v1|{transport}|{vendor_n}|{product_n}|{serial_n}"
        return "sha256:" + sha256_hex(material)
    fallback = f"v1|{transport}|{vendor_n}|{product_n}|{name_n}"
    return "unstable:" + sha256_hex(fallback)


def device_record(
    *,
    transport: str,
    name: str,
    identity_fingerprint_value: str,
    interfaces: list[str],
    capabilities: list[str] | None = None,
    storage_gb: float | None = None,
    cpu_gpu_memory: dict[str, Any] | None = None,
    power_thermal: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "schema": SCHEMA_DEVICE,
        "transport": transport,
        "name": name,
        "identityFingerprint": identity_fingerprint_value,
        "interfaces": interfaces,
        "capabilitiesObserved": capabilities or [],
        "storageGB": storage_gb,
        "cpuGpuMemory": cpu_gpu_memory,
        "powerThermal": power_thermal,
        "trustState": TRUST,
    }


def walk_items(node: Any):
    if isinstance(node, list):
        for item in node:
            yield from walk_items(item)
    elif isinstance(node, dict):
        yield node
        for key, val in node.items():
            if key in ("_items", "items") or key.endswith("_items"):
                yield from walk_items(val)


def is_bus_only_usb(node: dict[str, Any]) -> bool:
    name = first_str(node, ("_name",)).lower()
    has_product = bool(
        first_str(
            node,
            (
                "USBDeviceKeyProductID",
                "product_id",
                "product_id_key",
                "pid",
            ),
        )
    )
    has_serial = bool(
        first_str(
            node,
            (
                "USBDeviceKeySerialNumber",
                "serial_num",
                "serial_number",
                "USB Device Serial Number",
            ),
        )
    )
    if has_product or has_serial:
        return False
    if "bus" in name and not has_product:
        return True
    # Controllers without product identity are not useful device cards.
    if first_str(node, ("Driver", "USBKeyHardwareType")) and not has_product:
        # Built-in bus roots often only have Driver + location.
        if "hub" not in name and "device" not in name:
            return True
    return False


def parse_storage_gb(node: dict[str, Any]) -> float | None:
    # Never mount or open device files; only profiler-exposed size fields.
    for key in ("size_in_bytes", "size", "bsd_size", "capacity"):
        if key not in node:
            continue
        raw = node[key]
        try:
            if isinstance(raw, (int, float)):
                n = float(raw)
            else:
                s = str(raw).strip().replace(",", "")
                m = re.search(r"([0-9]+(?:\.[0-9]+)?)", s)
                if not m:
                    continue
                n = float(m.group(1))
                if "gb" in s.lower():
                    return round(n, 3)
                if "tb" in s.lower():
                    return round(n * 1024.0, 3)
                if "mb" in s.lower():
                    return round(n / 1024.0, 3)
            # Heuristic: large integers are bytes.
            if n > 10_000_000:
                return round(n / (1024.0 ** 3), 3)
        except (TypeError, ValueError):
            continue
    media = node.get("Media") or node.get("media")
    if isinstance(media, list):
        for entry in media:
            if isinstance(entry, dict):
                got = parse_storage_gb(entry)
                if got is not None:
                    return got
    return None


def parse_usb_nodes(roots: list[Any], source_key: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for node in walk_items(roots):
        if not isinstance(node, dict):
            continue
        if is_bus_only_usb(node):
            continue
        name = first_str(node, ("_name", "name", "device_name_key")) or "usb-device"
        vendor = first_str(
            node,
            (
                "USBDeviceKeyVendorID",
                "vendor_id",
                "vendor_id_key",
                "idVendor",
            ),
        )
        product = first_str(
            node,
            (
                "USBDeviceKeyProductID",
                "product_id",
                "product_id_key",
                "idProduct",
            ),
        )
        serial = first_str(
            node,
            (
                "USBDeviceKeySerialNumber",
                "serial_num",
                "serial_number",
                "USB Device Serial Number",
            ),
        )
        # Require at least one identity-ish field beyond a bare bus name.
        if not vendor and not product and not serial:
            continue
        if first_str(node, ("USBKeyHardwareType",)) == "Built-in" and "hub" in name.lower():
            # Built-in root hubs are noise for plug-and-manage cards.
            continue
        fp = identity_fingerprint("usb", vendor, product, serial, name)
        dedupe = f"usb|{fp}|{name}|{normalize_id(vendor)}|{normalize_id(product)}"
        if dedupe in seen:
            continue
        seen.add(dedupe)
        caps: list[str] = ["usb-device"]
        hw = first_str(node, ("USBKeyHardwareType",))
        if hw:
            caps.append(f"hardware-type:{hw}")
        speed = first_str(node, ("USBDeviceKeyLinkSpeed", "device_speed"))
        if speed:
            caps.append(f"link-speed:{speed}")
        interfaces = ["usb"]
        loc = first_str(node, ("USBKeyLocationID", "location_id"))
        if loc:
            interfaces.append(f"location:{loc}")
        out.append(
            device_record(
                transport="usb",
                name=name,
                identity_fingerprint_value=fp,
                interfaces=interfaces,
                capabilities=caps,
                storage_gb=parse_storage_gb(node),
                cpu_gpu_memory=None,
                power_thermal=None,
            )
        )
    return out


def is_host_tb_controller(node: dict[str, Any]) -> bool:
    """Host TB/USB4 bus with no downstream peer device."""
    if node.get("_items") or node.get("items"):
        return False
    receptacle = node.get("receptacle_1_tag") or node.get("receptacle_2_tag")
    if isinstance(receptacle, dict):
        status = first_str(receptacle, ("receptacle_status_key", "receptacle_status"))
        if status and "no_devices" in status:
            return True
    # Leaf peer devices usually carry serial / device_id / distinct device_name.
    if first_str(node, ("serial_number", "device_serial_number", "serial_num")):
        return False
    if first_str(node, ("device_id_key", "device_id", "vendor_id")) and first_str(
        node, ("device_name_key",)
    ):
        # Could still be host self-entry; only treat as controller when route is 0
        # and name looks like a bus.
        name = first_str(node, ("_name",)).lower()
        if "bus" in name or "thunderboltusb4" in name:
            return True
    name = first_str(node, ("_name",)).lower()
    return "bus" in name or "thunderboltusb4" in name


def parse_thunderbolt_nodes(roots: list[Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for node in walk_items(roots):
        if not isinstance(node, dict):
            continue
        # Parent buses with children are not themselves cards; children walk separately.
        if node.get("_items") or node.get("items"):
            continue
        if is_host_tb_controller(node):
            continue
        name = first_str(node, ("device_name_key", "_name", "name")) or "thunderbolt-device"
        # Skip pure receptacle tags accidentally walked (nested speed/status dicts).
        keys = set(node.keys())
        if keys and keys <= {
            "current_speed_key",
            "link_status_key",
            "receptacle_id_key",
            "receptacle_status_key",
        }:
            continue
        vendor = first_str(
            node,
            ("vendor_id", "vendor_id_key", "vendor_name_key", "vendor_name"),
        )
        product = first_str(node, ("device_id_key", "device_id", "product_id", "product_id_key"))
        true_serial = first_str(node, ("serial_number", "device_serial_number", "serial_num"))
        # Prefer true serial for stability; do not promote host switch_uid of empty buses.
        if not true_serial and not product:
            # Leaf without serial/product is not a useful peer observation.
            continue
        if not vendor and not product and not true_serial:
            continue
        stable_token = true_serial
        fp = identity_fingerprint("thunderbolt", vendor, product, stable_token, name)
        dedupe = f"tb|{fp}|{name}"
        if dedupe in seen:
            continue
        seen.add(dedupe)
        caps = ["thunderbolt-device"]
        speed = None
        for rkey in ("receptacle_1_tag", "receptacle_2_tag"):
            r = node.get(rkey)
            if isinstance(r, dict):
                speed = first_str(r, ("current_speed_key",)) or speed
        if speed:
            caps.append(f"link-speed:{speed}")
        out.append(
            device_record(
                transport="thunderbolt",
                name=name,
                identity_fingerprint_value=fp,
                interfaces=["thunderbolt"],
                capabilities=caps,
                storage_gb=None,
                cpu_gpu_memory=None,
                power_thermal=None,
            )
        )
    return out


def parse_profiler_json(data: dict[str, Any]) -> tuple[list[dict[str, Any]], list[str]]:
    notes: list[str] = []
    devices: list[dict[str, Any]] = []
    tb = data.get("SPThunderboltDataType") or []
    usb_legacy = data.get("SPUSBDataType") or []
    usb_host = data.get("SPUSBHostDataType") or []
    if not isinstance(tb, list):
        tb = []
    if not isinstance(usb_legacy, list):
        usb_legacy = []
    if not isinstance(usb_host, list):
        usb_host = []

    devices.extend(parse_thunderbolt_nodes(tb))
    devices.extend(parse_usb_nodes(usb_legacy, "SPUSBDataType"))
    devices.extend(parse_usb_nodes(usb_host, "SPUSBHostDataType"))

    if not usb_legacy and usb_host:
        notes.append(
            "SPUSBDataType empty; used SPUSBHostDataType (modern macOS USB report key). "
            "Not a device write — still read-only system_profiler."
        )
    if not tb and not usb_legacy and not usb_host:
        notes.append("system_profiler returned no Thunderbolt/USB trees (fail-soft empty).")
    return devices, notes


_ADD_RE = re.compile(
    r"\bAdd\b\s+\S+\s+\S+\s+(?P<domain>\S+)\s+(?P<type>\S+)\s+(?P<name>.+?)\s*$"
)


def unescape_dns_sd_name(raw: str) -> str:
    # dns-sd escapes spaces as \032
    def repl(m: re.Match[str]) -> str:
        try:
            return chr(int(m.group(1), 10))
        except ValueError:
            return m.group(0)

    return re.sub(r"\\([0-9]{3})", repl, raw.strip())


def parse_dns_sd_browse_text(text: str, service_type: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line in text.splitlines():
        if "Add" not in line:
            continue
        m = _ADD_RE.search(line)
        if not m:
            continue
        name = unescape_dns_sd_name(m.group("name"))
        stype = m.group("type").rstrip(".")
        domain = m.group("domain").rstrip(".")
        if not name:
            continue
        # No serial available from browse-only; mark unstable.
        fp = identity_fingerprint("bonjour", stype, domain, "", name)
        dedupe = f"bonjour|{stype}|{domain}|{name}|{fp}"
        if dedupe in seen:
            continue
        seen.add(dedupe)
        # Bonjour claims are untrusted self-reports only.
        caps = [f"bonjour-service:{stype}", "claimed-untrusted"]
        # cpuGpuMemory / powerThermal unknown without privileged/enrolled telemetry.
        out.append(
            device_record(
                transport="bonjour",
                name=name,
                identity_fingerprint_value=fp,
                interfaces=["bonjour", stype, domain],
                capabilities=caps,
                storage_gb=None,
                cpu_gpu_memory=None,
                power_thermal=None,
            )
        )
    return out


def load_profiler_data() -> tuple[dict[str, Any], list[str]]:
    notes: list[str] = []
    if PROFILER_JSON_FILE:
        path = Path(PROFILER_JSON_FILE)
        data = json.loads(path.read_text(encoding="utf-8"))
        return data, notes
    if SKIP_LIVE_PROFILER:
        return {
            "SPThunderboltDataType": [],
            "SPUSBDataType": [],
            "SPUSBHostDataType": [],
        }, notes
    # Ticket primary keys + SPUSBHostDataType for modern macOS (SPUSBDataType often empty).
    cmd = [
        "system_profiler",
        "SPThunderboltDataType",
        "SPUSBDataType",
        "SPUSBHostDataType",
        "-json",
    ]
    try:
        proc = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if proc.returncode != 0 and not proc.stdout.strip():
            notes.append(
                f"system_profiler failed (exit {proc.returncode}); fail-soft empty wired devices."
            )
            return {
                "SPThunderboltDataType": [],
                "SPUSBDataType": [],
                "SPUSBHostDataType": [],
            }, notes
        data = json.loads(proc.stdout or "{}")
        if not isinstance(data, dict):
            notes.append("system_profiler JSON root not object; fail-soft empty.")
            return {
                "SPThunderboltDataType": [],
                "SPUSBDataType": [],
                "SPUSBHostDataType": [],
            }, notes
        return data, notes
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError) as exc:
        notes.append(f"system_profiler unavailable ({type(exc).__name__}); fail-soft empty.")
        return {
            "SPThunderboltDataType": [],
            "SPUSBDataType": [],
            "SPUSBHostDataType": [],
        }, notes


def load_bonjour_devices() -> tuple[list[dict[str, Any]], list[str]]:
    notes: list[str] = []
    devices: list[dict[str, Any]] = []
    if DNS_SD_TEXT_FILE:
        text = Path(DNS_SD_TEXT_FILE).read_text(encoding="utf-8")
        # Infer service type from first Browsing line if present.
        stype = "_workstation._tcp"
        m = re.search(r"Browsing for\s+(\S+)", text)
        if m:
            stype = m.group(1).rstrip(".").removesuffix(".local")
        devices.extend(parse_dns_sd_browse_text(text, stype))
        return devices, notes
    if SKIP_LIVE_BONJOUR:
        return devices, notes
    if not Path("/usr/bin/dns-sd").exists() and not shutil_which("dns-sd"):
        notes.append("dns-sd not found; Bonjour discovery skipped (fail-soft).")
        return devices, notes

    # Important: dns-sd -t N (ticket / design). Do not use only 2 seconds.
    if BONJOUR_TIMEOUT < 6 and not SELFTEST:
        notes.append(
            f"bonjour timeout {BONJOUR_TIMEOUT}s is below recommended 6s "
            "(design: avoid 2s-only scans); proceeding as requested."
        )

    for stype in BONJOUR_TYPES:
        cmd = ["dns-sd", "-t", str(BONJOUR_TIMEOUT), "-B", stype, "local"]
        try:
            proc = subprocess.run(
                cmd,
                check=False,
                capture_output=True,
                text=True,
                timeout=BONJOUR_TIMEOUT + 5,
            )
            text = (proc.stdout or "") + "\n" + (proc.stderr or "")
            found = parse_dns_sd_browse_text(text, stype)
            devices.extend(found)
        except (subprocess.TimeoutExpired, OSError) as exc:
            notes.append(f"dns-sd {stype} failed ({type(exc).__name__}); partial fail-soft.")
    if not devices:
        notes.append(
            "Bonjour browse produced no Add records (local network empty, permission, "
            "or short window); fail-soft empty for bonjour."
        )
    return devices, notes


def shutil_which(name: str) -> str | None:
    paths = os.environ.get("PATH", "").split(os.pathsep)
    for directory in paths:
        candidate = Path(directory) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def build_report(
    devices: list[dict[str, Any]], notes: list[str]
) -> dict[str, Any]:
    # Stable ordering for receipt diffs: transport, name, fingerprint.
    devices_sorted = sorted(
        devices,
        key=lambda d: (d.get("transport", ""), d.get("name", ""), d.get("identityFingerprint", "")),
    )
    # Dedupe exact fingerprint+transport+name triples across sources.
    final: list[dict[str, Any]] = []
    seen: set[str] = set()
    for d in devices_sorted:
        key = f"{d.get('transport')}|{d.get('identityFingerprint')}|{d.get('name')}"
        if key in seen:
            continue
        seen.add(key)
        # Enforce S1 constants.
        d = dict(d)
        d["trustState"] = TRUST
        d["schema"] = SCHEMA_DEVICE
        final.append(d)
    if not final and not any("empty" in n.lower() for n in notes):
        notes.append(
            "No devices observed; returning empty devices[] (fail-soft, not an error)."
        )
    return {
        "schema": SCHEMA_REPORT,
        "stage": STAGE,
        "nextStep": NEXT_STEP,
        "devices": final,
        "notes": notes,
    }


def assert_true(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def run_selftest() -> int:
    mixed = FIXTURE_DIR / "system_profiler_mixed.json"
    empty = FIXTURE_DIR / "system_profiler_empty.json"
    dns_txt = FIXTURE_DIR / "dns_sd_workstation.txt"
    dns_empty = FIXTURE_DIR / "dns_sd_empty.txt"
    expected_path = FIXTURE_DIR / "expected_fingerprints.json"
    for p in (mixed, empty, dns_txt, dns_empty, expected_path):
        assert_true(p.is_file(), f"missing fixture: {p}")

    expected = json.loads(expected_path.read_text(encoding="utf-8"))

    data = json.loads(mixed.read_text(encoding="utf-8"))
    devices_a, notes_a = parse_profiler_json(data)
    devices_b, _ = parse_profiler_json(data)
    # Fingerprint stability across two parses.
    fps_a = sorted(d["identityFingerprint"] for d in devices_a)
    fps_b = sorted(d["identityFingerprint"] for d in devices_b)
    assert_true(fps_a == fps_b, "fingerprint instability across identical parses")

    by_name = {d["name"]: d for d in devices_a}
    assert_true("Peer MacBook" in by_name, "missing TB peer from fixture")
    assert_true(by_name["Peer MacBook"]["transport"] == "thunderbolt", "TB transport")
    assert_true(
        by_name["Peer MacBook"]["identityFingerprint"] == expected["thunderbolt_peer"],
        f"TB fingerprint mismatch: {by_name['Peer MacBook']['identityFingerprint']}",
    )
    assert_true(
        by_name["Peer MacBook"]["identityFingerprint"].startswith("sha256:"),
        "serial-backed TB must be sha256:",
    )

    assert_true("ESD360C" in by_name, "missing USB serial device")
    assert_true(
        by_name["ESD360C"]["identityFingerprint"] == expected["usb_stable"],
        "USB stable fingerprint mismatch",
    )
    assert_true(by_name["ESD360C"]["identityFingerprint"].startswith("sha256:"), "usb sha")

    assert_true("Cruzer" in by_name, "missing USB no-serial device")
    assert_true(
        by_name["Cruzer"]["identityFingerprint"] == expected["usb_unstable"],
        "USB unstable fingerprint mismatch",
    )
    assert_true(
        by_name["Cruzer"]["identityFingerprint"].startswith("unstable:"),
        "no-serial must mark unstable",
    )

    for d in devices_a:
        assert_true(d["trustState"] == TRUST, "trustState must be untrusted")
        # Privacy: raw fixture serials must not leak into JSON fields.
        blob = json.dumps(d)
        assert_true("TB-SERIAL-AAA" not in blob, "raw TB serial leaked")
        assert_true("USB-SERIAL-BBB" not in blob, "raw USB serial leaked")

    # Empty profiler fail-soft.
    empty_data = json.loads(empty.read_text(encoding="utf-8"))
    empty_devices, empty_notes = parse_profiler_json(empty_data)
    assert_true(empty_devices == [], "empty profiler must yield no wired devices")
    assert_true(any("empty" in n.lower() or "no Thunderbolt" in n for n in empty_notes), "empty note")

    # Bonjour parse.
    bonj = parse_dns_sd_browse_text(dns_txt.read_text(encoding="utf-8"), "_workstation._tcp")
    assert_true(len(bonj) >= 2, "expected bonjour instances in fixture")
    for d in bonj:
        assert_true(d["transport"] == "bonjour", "bonjour transport")
        assert_true(d["identityFingerprint"].startswith("unstable:"), "bonjour no serial → unstable")
        assert_true(d["trustState"] == TRUST, "bonjour untrusted")
        assert_true(d["cpuGpuMemory"] is None, "S1 bonjour cpu/gpu null without claims")
        assert_true(d["powerThermal"] is None, "powerThermal null")

    bonj_empty = parse_dns_sd_browse_text(
        dns_empty.read_text(encoding="utf-8"), "_workstation._tcp"
    )
    assert_true(bonj_empty == [], "empty dns-sd text → empty list")

    # End-to-end report shape via env overrides.
    os.environ["PROFILER_JSON_FILE"] = str(mixed)
    os.environ["DNS_SD_TEXT_FILE"] = str(dns_txt)
    # re-read globals is awkward; call builders directly
    wired, n1 = parse_profiler_json(data)
    bonj2, n2 = [], []
    bonj2 = parse_dns_sd_browse_text(dns_txt.read_text(encoding="utf-8"), "_workstation._tcp")
    report = build_report(wired + bonj2, n1 + n2)
    assert_true(report["stage"] == STAGE, "stage")
    assert_true(report["nextStep"] == NEXT_STEP, "nextStep")
    assert_true(report["schema"] == SCHEMA_REPORT, "report schema")
    assert_true(all(d["trustState"] == TRUST for d in report["devices"]), "all untrusted")

    empty_report = build_report([], ["No devices observed; returning empty devices[] (fail-soft, not an error)."])
    assert_true(empty_report["devices"] == [], "empty report devices")
    assert_true(empty_report["stage"] == STAGE, "empty still discovery-only")
    assert_true(empty_report["nextStep"] == NEXT_STEP, "empty still requires pairing code")

    print(
        json.dumps(
            {
                "selftest": "pass",
                "deviceCountMixed": len(report["devices"]),
                "fingerprintsChecked": [
                    expected["thunderbolt_peer"],
                    expected["usb_stable"],
                    expected["usb_unstable"],
                ],
                "emptyDevicesOk": True,
                "stage": STAGE,
                "nextStep": NEXT_STEP,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def main() -> int:
    if SELFTEST:
        try:
            return run_selftest()
        except AssertionError as exc:
            print(json.dumps({"selftest": "fail", "error": str(exc)}), file=sys.stderr)
            return 1

    notes: list[str] = []
    profiler, n0 = load_profiler_data()
    notes.extend(n0)
    wired, n1 = parse_profiler_json(profiler)
    notes.extend(n1)
    bonj, n2 = load_bonjour_devices()
    notes.extend(n2)
    report = build_report(wired + bonj, notes)
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
