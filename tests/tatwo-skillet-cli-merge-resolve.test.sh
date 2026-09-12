#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFTPM_SCRATCH_PATH="${TATWO_SWIFTPM_SCRATCH_PATH:-$ROOT/.build/out}"
if [ -n "${TATWO_SKILLET_CLI:-}" ]; then
  CLI="$TATWO_SKILLET_CLI"
else
  BUILD_BIN_PATH="$(
    swift build \
      --package-path "$ROOT" \
      --scratch-path "$SWIFTPM_SCRATCH_PATH" \
      --show-bin-path
  )"
  CLI="$BUILD_BIN_PATH/tatwo-ultrawork"
fi
TEST_PARENT="${TATWO_TEST_TMP_ROOT:-${TMPDIR:-/tmp}/tatwo-skillet}"
mkdir -p "$TEST_PARENT"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/tatwo-skillet-cli-merge-resolve.XXXXXX")"

fail() {
  printf '%s\n' "not ok - $*" >&2
  printf '%s\n' "tatwo_test_root_preserved=$TEST_ROOT" >&2
  exit 1
}

pass() {
  printf '%s\n' "ok - $*"
}

expect_status() {
  local expected="$1" label="$2"
  shift 2
  local slug="${label//[^A-Za-z0-9._-]/-}"
  set +e
  "$@" >"$TEST_ROOT/$slug.stdout.log" 2>"$TEST_ROOT/$slug.stderr.log"
  local actual=$?
  set -e
  [ "$actual" = "$expected" ] \
    || fail "$label returned $actual instead of $expected"
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
for component in sys.argv[2].split("."):
    if isinstance(value, list):
        value = value[int(component)]
    else:
        value = value[component]
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

[ -x "$CLI" ] || fail "Skillet CLI is unavailable: $CLI"

TARGET_STORE="$TEST_ROOT/target-store"
SOURCE_STORE="$TEST_ROOT/source-store"
TARGET_RUNTIME="$TEST_ROOT/target-runtime"
TARGET_SOURCE="$TEST_ROOT/target-source"
SOURCE_SOURCE="$TEST_ROOT/source-source"
RESOLVED_SOURCE="$TEST_ROOT/resolved-source"
TRANSPORT="$TEST_ROOT/transport"
REPOSITORY_TRANSPORT="$TRANSPORT/repositories/unrelated-history"
mkdir -p \
  "$TARGET_SOURCE" \
  "$SOURCE_SOURCE" \
  "$RESOLVED_SOURCE" \
  "$TARGET_RUNTIME" \
  "$REPOSITORY_TRANSPORT"

cat >"$TARGET_SOURCE/SKILL.md" <<'EOF'
---
name: unrelated-history
description: Target canonical branch.
---

# Target canonical

target-only history
EOF

cat >"$SOURCE_SOURCE/SKILL.md" <<'EOF'
---
name: unrelated-history
description: Incoming proposed branch.
---

# Incoming proposed

source-only history
EOF

cat >"$RESOLVED_SOURCE/SKILL.md" <<'EOF'
---
name: unrelated-history
description: Human-resolved repository.
---

# Human resolution

target-only history
source-only history
EOF

"$CLI" skillet snapshot \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --source "$TARGET_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/target-snapshot.json" \
  --json >"$TEST_ROOT/target-snapshot.stdout.json"

"$CLI" skillet snapshot \
  --store "$SOURCE_STORE" \
  --repository unrelated-history \
  --source "$SOURCE_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/source-snapshot.json" \
  --json >"$TEST_ROOT/source-snapshot.stdout.json"

"$CLI" skillet export-bound \
  --store "$SOURCE_STORE" \
  --repository unrelated-history \
  --bundle "$REPOSITORY_TRANSPORT/bundle" \
  --binding "$REPOSITORY_TRANSPORT/authority-binding.json" \
  --request request-unrelated-history \
  --source-device source-device \
  --target-device target-device \
  --authority-epoch 1 \
  --ledger-sequence 1 \
  --catalog-revision 2026-07-27.1 \
  --receipt "$TEST_ROOT/export.json" \
  --json >"$TEST_ROOT/export.stdout.json"

python3 - "$TEST_ROOT/export.json" "$TRANSPORT/set.json" <<'PY'
import json
import pathlib
import sys

receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
manifest = {
    "schemaVersion": 1,
    "requestID": "request-unrelated-history",
    "catalogRevision": "2026-07-27.1",
    "authorityEpoch": 1,
    "ledgerSequence": 1,
    "sourceDeviceID": "source-device",
    "targetDeviceID": "target-device",
    "repositories": [{
        "repositoryID": receipt["repositoryID"],
        "revisionID": receipt["revisionID"],
        "contentDigest": receipt["contentDigest"],
        "bundleDigest": receipt["bundleDigest"],
        "bundleRelativePath": "repositories/unrelated-history/bundle",
        "bindingRelativePath": "repositories/unrelated-history/authority-binding.json",
    }],
}
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

set +e
"$CLI" skillet import-activate-set \
  --set-manifest "$TRANSPORT/set.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$TARGET_RUNTIME" \
  --request request-unrelated-history \
  --source-device source-device \
  --target-device target-device \
  --authority-epoch 1 \
  --ledger-sequence 1 \
  --catalog-revision 2026-07-27.1 \
  --receipt "$TEST_ROOT/merge-pending.json" \
  --json >"$TEST_ROOT/merge-pending.stdout.json" \
  2>"$TEST_ROOT/merge-pending.stderr.log"
import_status=$?
set -e
[ "$import_status" = "44" ] \
  || fail "unrelated history returned $import_status instead of merge-pending 44"

"$CLI" skillet merge-list \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --receipt "$TEST_ROOT/merge-list.json" \
  --json >"$TEST_ROOT/merge-list.stdout.json"
proposal_id="$(json_get "$TEST_ROOT/merge-list.json" proposals.0.id)"
canonical_revision="$(json_get "$TEST_ROOT/merge-list.json" proposals.0.canonicalRevisionID)"
proposed_revision="$(json_get "$TEST_ROOT/merge-list.json" proposals.0.proposedRevisionID)"
[ "$(json_get "$TEST_ROOT/merge-list.json" proposals.0.conflictArtifactIDs.0)" != "" ] \
  || fail "fixture did not create an unrelated-history conflict"

expect_status 1 "unsafe-repository" \
  "$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository ../unrelated-history \
  --proposal "$proposal_id" \
  --source "$RESOLVED_SOURCE" \
  --channel staging \
  --json
expect_status 1 "unsafe-proposal" \
  "$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --proposal ../"$proposal_id" \
  --source "$RESOLVED_SOURCE" \
  --channel staging \
  --json
expect_status 1 "release-channel" \
  "$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --source "$RESOLVED_SOURCE" \
  --channel stable \
  --json
pass "merge-resolve rejects unsafe identifiers and direct release channels"

expect_status 45 "canonical-source-reuse" \
  "$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --source "$TARGET_SOURCE" \
  --channel staging \
  --json
expect_status 45 "proposed-source-reuse" \
  "$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --source "$SOURCE_SOURCE" \
  --channel staging \
  --json
pass "merge-resolve requires a new canonical-parented resolution"

SYMLINK_SOURCE="$TEST_ROOT/symlink-source"
SECRET_SOURCE="$TEST_ROOT/secret-source"
mkdir -p "$SYMLINK_SOURCE" "$SECRET_SOURCE"
cp "$RESOLVED_SOURCE/SKILL.md" "$SYMLINK_SOURCE/SKILL.md"
ln -s "$TARGET_SOURCE/SKILL.md" "$SYMLINK_SOURCE/linked-skill.md"
cat >"$SECRET_SOURCE/SKILL.md" <<'EOF'
---
name: secret-resolution
description: Must be rejected by the Skillet content scanner.
---

EOF
printf '%s%s\n' \
  'sk-proj-' \
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
  >>"$SECRET_SOURCE/SKILL.md"
expect_status 1 "symlink-source" \
  "$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --source "$SYMLINK_SOURCE" \
  --channel staging \
  --json
expect_status 1 "secret-source" \
  "$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --source "$SECRET_SOURCE" \
  --channel staging \
  --json
pass "merge-resolve reuses the repository secret and symlink fail-closed scan"

STALE_STORE="$TEST_ROOT/stale-store"
cp -R "$TARGET_STORE" "$STALE_STORE"
STALE_SOURCE="$TEST_ROOT/stale-source"
mkdir -p "$STALE_SOURCE"
cat >"$STALE_SOURCE/SKILL.md" <<'EOF'
---
name: unrelated-history
description: Canonical advanced after the proposal.
---

# Advanced canonical
EOF
"$CLI" skillet snapshot \
  --store "$STALE_STORE" \
  --repository unrelated-history \
  --source "$STALE_SOURCE" \
  --channel staging \
  --receipt "$TEST_ROOT/stale-snapshot.json" \
  --json >"$TEST_ROOT/stale-snapshot.stdout.json"
expect_status 46 "stale-canonical" \
  "$CLI" skillet merge-resolve \
  --store "$STALE_STORE" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --source "$RESOLVED_SOURCE" \
  --channel staging \
  --json
pass "merge-resolve rejects a proposal after canonical advances"

"$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --source "$RESOLVED_SOURCE" \
  --channel staging \
  --receipt "$TEST_ROOT/merge-resolve.json" \
  --json >"$TEST_ROOT/merge-resolve.stdout.json"

resolved_revision="$(json_get "$TEST_ROOT/merge-resolve.json" resolvedRevisionID)"
[ "$resolved_revision" != "$canonical_revision" ] \
  || fail "merge resolution reused the canonical revision"
[ "$resolved_revision" != "$proposed_revision" ] \
  || fail "merge resolution reused the unrelated proposed revision"
[ "$(json_get "$TEST_ROOT/merge-resolve.json" canonicalActivationState)" = "unchanged" ] \
  || fail "merge-resolve changed canonical before approval"
[ "$(json_get "$TARGET_STORE/repositories/unrelated-history/repository.json" canonicalRevision)" \
    = "$canonical_revision" ] \
  || fail "merge-resolve advanced canonical before human approval"
[ "$(json_get "$TARGET_STORE/repositories/unrelated-history/revisions/$resolved_revision.json" parentRevisionID)" \
    = "$canonical_revision" ] \
  || fail "resolved revision is not parented to the target canonical"
pass "merge-resolve creates a detached, canonical-parented resolution"

"$CLI" skillet merge-approve \
  --store "$TARGET_STORE" \
  --runtime-root "$TARGET_RUNTIME" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --resolved-revision "$resolved_revision" \
  --decided-by test-human \
  --receipt "$TEST_ROOT/merge-approve.json" \
  --json >"$TEST_ROOT/merge-approve.stdout.json"

[ "$(json_get "$TEST_ROOT/merge-approve.json" status)" = "approved" ] \
  || fail "resolved unrelated-history proposal was not approved"
[ "$(json_get "$TARGET_STORE/repositories/unrelated-history/repository.json" canonicalRevision)" \
    = "$resolved_revision" ] \
  || fail "approval did not advance canonical to the resolved revision"
[ "$(json_get "$TEST_ROOT/merge-approve.json" runtimeActivationState)" = "unchanged" ] \
  || fail "approval changed runtime before a new authority-bound request"
pass "resolved unrelated history can be approved without runtime activation"

expect_status 46 "already-decided-proposal" \
  "$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository unrelated-history \
  --proposal "$proposal_id" \
  --source "$RESOLVED_SOURCE" \
  --channel staging \
  --json
pass "merge-resolve rejects an already-decided proposal"

printf '%s\n' "tatwo_test_root=$TEST_ROOT"
