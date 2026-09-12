#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${AGENT_KERNEL_DRIVER_BIN:-$ROOT/.build/debug/agent-kernel-driver}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/task" "$TMP/bin"
cat >"$TMP/task/task.md" <<'EOF'
Context engine driver selftest.
STEP 1 :: write output.txt first
STEP 2 :: append output.txt second
EOF
cat >"$TMP/bin/codex" <<'EOF'
#!/bin/bash
printf '%s\n' '{"actual":"codex","effort":"exam","message":"ok"}'
EOF
chmod +x "$TMP/bin/codex"

AGENT_KERNEL_CODEX_BIN="$TMP/bin/codex" "$BIN" run \
  --task "$TMP/task" --store "$TMP/store" --transport codex \
  --run context-selftest --context compacted --context-budget 128

python3 - "$TMP/store/context-selftest" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifests = sorted(root.glob("turns/*/prompt_manifest.json"))
assert len(manifests) == 2, manifests
for path in manifests:
    value = json.loads(path.read_text())
    assert set(value) == {
        "windowTurnIDs", "checkpointHash", "assembled_input_tokens",
        "bytes", "payloadDigest",
    }
    assert value["assembled_input_tokens"] <= 128
    assert len(value["payloadDigest"]) == 64
print("CONTEXT_MANIFESTS=2")
PY
