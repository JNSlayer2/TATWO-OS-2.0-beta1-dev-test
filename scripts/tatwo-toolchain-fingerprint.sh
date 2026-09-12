#!/usr/bin/env bash
# tatwo-toolchain-fingerprint.sh — emit TatwoToolchainFingerprintV1 JSON
#
# Production (no args): print one JSON object to stdout.
# --selftest: require required fields non-empty and JSON parseable; exit 0/1.
#
# Scope (D10 S1 / K4): local probe only. Remote result receipt embedding is S2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SELFTEST=0

usage() {
  cat <<'EOF'
用法：
  bash scripts/tatwo-toolchain-fingerprint.sh
  bash scripts/tatwo-toolchain-fingerprint.sh --selftest

輸出 JSON 欄位（schema=TatwoToolchainFingerprintV1）：
  swiftVersion, xcodePath, xcodeVersion, os, arch, hostName,
  ramGB, logicalCPU, generatedAt

xcodePath / xcodeVersion 在工具鏈缺席時可為 null；其餘欄位必須非空。
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--selftest" ]]; then
  if [[ $# -ne 1 ]]; then
    printf 'selftest: unknown argument: %s\n' "${2:-}" >&2
    exit 2
  fi
  SELFTEST=1
elif [[ $# -ne 0 ]]; then
  printf 'unknown argument: %s\n' "$1" >&2
  usage >&2
  exit 2
fi

# --- probes (tolerate Xcode absence; never fail production emit) ---

swift_raw=""
if command -v swift >/dev/null 2>&1; then
  swift_raw="$(swift --version 2>&1 || true)"
fi

# Prefer "Apple Swift version X.Y (swiftlang-...)" full token; fall back to first version-like token.
swift_version=""
if [[ -n "$swift_raw" ]]; then
  swift_version="$(
    printf '%s\n' "$swift_raw" | python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"Apple Swift version\s+([0-9.]+(?:\s*\([^)]+\))?)", text)
if m:
    print(m.group(1).strip())
    raise SystemExit(0)
m = re.search(r"Swift version\s+([0-9.]+)", text)
if m:
    print(m.group(1).strip())
    raise SystemExit(0)
' 2>/dev/null || true
  )"
fi
if [[ -z "$swift_version" && -n "$swift_raw" ]]; then
  # Last-resort: first line, trimmed, capped.
  swift_version="$(printf '%s\n' "$swift_raw" | head -n 1 | tr -d '\r' | cut -c1-160)"
fi

xcode_path=""
if command -v xcode-select >/dev/null 2>&1; then
  xcode_path="$(xcode-select -p 2>/dev/null || true)"
fi
# Treat empty or non-directory as absent.
if [[ -z "$xcode_path" || ! -d "$xcode_path" ]]; then
  xcode_path=""
fi

xcode_version=""
if command -v xcodebuild >/dev/null 2>&1; then
  xcode_ver_raw="$(xcodebuild -version 2>/dev/null || true)"
  if [[ -n "$xcode_ver_raw" ]]; then
    xcode_version="$(
      printf '%s\n' "$xcode_ver_raw" | python3 -c '
import re, sys
lines = [ln.strip() for ln in sys.stdin.read().splitlines() if ln.strip()]
if not lines:
    raise SystemExit(0)
name = lines[0]
build = ""
for ln in lines[1:]:
    m = re.match(r"Build version\s+(.+)", ln, re.I)
    if m:
        build = m.group(1).strip()
        break
if build:
    print(f"{name} ({build})")
else:
    print(name)
' 2>/dev/null || true
    )"
  fi
fi

os_string=""
if command -v sw_vers >/dev/null 2>&1; then
  product_name="$(sw_vers -productName 2>/dev/null || true)"
  product_version="$(sw_vers -productVersion 2>/dev/null || true)"
  build_version="$(sw_vers -buildVersion 2>/dev/null || true)"
  if [[ -n "$product_name" && -n "$product_version" ]]; then
    if [[ -n "$build_version" ]]; then
      os_string="${product_name} ${product_version} (${build_version})"
    else
      os_string="${product_name} ${product_version}"
    fi
  fi
fi
if [[ -z "$os_string" ]]; then
  os_string="$(uname -s 2>/dev/null || echo unknown)-$(uname -r 2>/dev/null || echo unknown)"
fi

arch="$(uname -m 2>/dev/null || true)"
if [[ -z "$arch" ]]; then
  arch="unknown"
fi

host_name="$(hostname 2>/dev/null || true)"
if [[ -z "$host_name" ]]; then
  host_name="$(scutil --get LocalHostName 2>/dev/null || true)"
fi
if [[ -z "$host_name" ]]; then
  host_name="unknown-host"
fi

logical_cpu=""
if command -v sysctl >/dev/null 2>&1; then
  logical_cpu="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)"
fi
if [[ -z "$logical_cpu" ]]; then
  logical_cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"
fi
# Coerce to integer string.
if ! [[ "$logical_cpu" =~ ^[0-9]+$ ]]; then
  logical_cpu=0
fi

ram_gb=0
if command -v sysctl >/dev/null 2>&1; then
  mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
  if [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
    # Integer GiB (floor). 16 GiB machines report 17179869184 → 16.
    ram_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  fi
fi

generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Build JSON via Python for stable escaping (no network).
JSON_OUT="$(
  SWIFT_VERSION="$swift_version" \
  XCODE_PATH="$xcode_path" \
  XCODE_VERSION="$xcode_version" \
  OS_STRING="$os_string" \
  ARCH="$arch" \
  HOST_NAME="$host_name" \
  RAM_GB="$ram_gb" \
  LOGICAL_CPU="$logical_cpu" \
  GENERATED_AT="$generated_at" \
  python3 - <<'PY'
import json, os

def nz(s):
    s = (s or "").strip()
    return s if s else None

payload = {
    "schema": "TatwoToolchainFingerprintV1",
    "swiftVersion": nz(os.environ.get("SWIFT_VERSION")) or "unknown",
    "xcodePath": nz(os.environ.get("XCODE_PATH")),
    "xcodeVersion": nz(os.environ.get("XCODE_VERSION")),
    "os": nz(os.environ.get("OS_STRING")) or "unknown",
    "arch": nz(os.environ.get("ARCH")) or "unknown",
    "hostName": nz(os.environ.get("HOST_NAME")) or "unknown-host",
    "ramGB": int(os.environ.get("RAM_GB") or "0"),
    "logicalCPU": int(os.environ.get("LOGICAL_CPU") or "0"),
    "generatedAt": nz(os.environ.get("GENERATED_AT")) or "1970-01-01T00:00:00Z",
}
print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
)"

if [[ "$SELFTEST" -eq 1 ]]; then
  # Required non-null/non-empty scalar fields; xcode* may be null.
  # ramGB/logicalCPU must be positive integers on a real Mac probe.
  # Note: pass JSON via env — a heredoc would consume stdin and hide the payload.
  if ! JSON_OUT="$JSON_OUT" python3 - <<'PY'
import json, os, sys

raw = os.environ.get("JSON_OUT", "")
try:
    obj = json.loads(raw)
except Exception as e:
    print(f"selftest: JSON parse failed: {e}", file=sys.stderr)
    raise SystemExit(1)

required = [
    "schema",
    "swiftVersion",
    "os",
    "arch",
    "hostName",
    "ramGB",
    "logicalCPU",
    "generatedAt",
]
missing = [k for k in required if k not in obj]
if missing:
    print(f"selftest: missing keys: {missing}", file=sys.stderr)
    raise SystemExit(1)

if obj.get("schema") != "TatwoToolchainFingerprintV1":
    print(f"selftest: bad schema: {obj.get('schema')!r}", file=sys.stderr)
    raise SystemExit(1)

for key in ("swiftVersion", "os", "arch", "hostName", "generatedAt"):
    val = obj.get(key)
    if not isinstance(val, str) or not val.strip():
        print(f"selftest: field {key!r} must be non-empty string", file=sys.stderr)
        raise SystemExit(1)

for key in ("ramGB", "logicalCPU"):
    val = obj.get(key)
    if not isinstance(val, int) or isinstance(val, bool) or val <= 0:
        print(f"selftest: field {key!r} must be positive int (got {val!r})", file=sys.stderr)
        raise SystemExit(1)

# Optional Xcode: null or non-empty string only.
for key in ("xcodePath", "xcodeVersion"):
    val = obj.get(key, None)
    if val is None:
        continue
    if not isinstance(val, str) or not val.strip():
        print(f"selftest: field {key!r} must be null or non-empty string", file=sys.stderr)
        raise SystemExit(1)

print("selftest: fields OK")
print(raw)
raise SystemExit(0)
PY
  then
    printf 'SELFTEST FAIL\n' >&2
    exit 1
  fi
  printf 'SELFTEST PASS\n'
  exit 0
fi

printf '%s\n' "$JSON_OUT"
