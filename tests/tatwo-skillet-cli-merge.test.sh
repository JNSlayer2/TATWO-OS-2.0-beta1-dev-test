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
TEST_ROOT="$(mktemp -d "$TEST_PARENT/tatwo-skillet-cli-merge.XXXXXX")"

fail() {
  printf '%s\n' "not ok - $*" >&2
  printf '%s\n' "tatwo_test_root_preserved=$TEST_ROOT" >&2
  exit 1
}

pass() {
  printf '%s\n' "ok - $*"
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

runtime_digest() {
  local runtime="$1"
  if [ ! -d "$runtime" ]; then
    printf '%s\n' "absent"
    return
  fi
  (
    cd "$runtime"
    find . -type f -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' file; do
          printf '%s\0' "$file"
          shasum -a 256 "$file" | awk '{printf "%s\\0", $1}'
        done
  ) | shasum -a 256 | awk '{print $1}'
}

make_bound_set() {
  local store="$1" request_id="$2" epoch="$3" ledger="$4" set_root="$5"
  local source_device="${6:-book-device}"
  local target_device="${7:-mini-device}"
  local repository_root="$set_root/repositories/demo-skill"
  mkdir -p "$repository_root"
  "$CLI" skillet export-bound \
    --store "$store" \
    --repository demo-skill \
    --bundle "$repository_root/bundle" \
    --binding "$repository_root/authority-binding.json" \
    --request "$request_id" \
    --source-device "$source_device" \
    --target-device "$target_device" \
    --authority-epoch "$epoch" \
    --ledger-sequence "$ledger" \
    --catalog-revision 2026-07-25.1 \
    --receipt "$set_root/export.json" \
    --json >"$set_root/export.stdout.json"
  python3 - "$set_root/export.json" "$set_root/set.json" \
    "$request_id" "$epoch" "$ledger" "$source_device" "$target_device" <<'PY'
import json
import pathlib
import sys

receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
manifest = {
    "schemaVersion": 1,
    "requestID": sys.argv[3],
    "catalogRevision": "2026-07-25.1",
    "authorityEpoch": int(sys.argv[4]),
    "ledgerSequence": int(sys.argv[5]),
    "sourceDeviceID": sys.argv[6],
    "targetDeviceID": sys.argv[7],
    "repositories": [{
        "repositoryID": receipt["repositoryID"],
        "revisionID": receipt["revisionID"],
        "contentDigest": receipt["contentDigest"],
        "bundleDigest": receipt["bundleDigest"],
        "bundleRelativePath": "repositories/demo-skill/bundle",
        "bindingRelativePath": "repositories/demo-skill/authority-binding.json",
    }],
}
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
}

[ -x "$CLI" ] || fail "Skillet CLI is unavailable: $CLI"

SOURCE_STORE="$TEST_ROOT/source-store"
TARGET_STORE="$TEST_ROOT/target-store"
BOOK_RUNTIME_ROOT="$TEST_ROOT/book-runtime"
MINI_RUNTIME_ROOT="$TEST_ROOT/mini-runtime"
BASE_SOURCE="$TEST_ROOT/base-source"
BOOK_SOURCE="$TEST_ROOT/book-source"
MINI_SOURCE="$TEST_ROOT/mini-source"
mkdir -p "$BASE_SOURCE/notes"
cat >"$BASE_SOURCE/SKILL.md" <<'EOF'
---
name: skillet-cli-smoke
description: Real divergent merge and activation smoke.
---

# Skillet CLI smoke

This is the shared base revision.
EOF
printf '%s\n' "shared base" >"$BASE_SOURCE/notes/base.txt"
cp -R "$BASE_SOURCE" "$BOOK_SOURCE"
cp -R "$BASE_SOURCE" "$MINI_SOURCE"

"$CLI" skillet snapshot \
  --store "$SOURCE_STORE" \
  --repository demo-skill \
  --display-name "Demo Skill" \
  --summary "Real CLI merge smoke" \
  --source "$BASE_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/base-snapshot.json" \
  --json >"$TEST_ROOT/base-snapshot.stdout.json"

ARCHIFY_SOURCE="$TEST_ROOT/archify-source"
ARCHIFY_TRANSPORT="$TEST_ROOT/archify-transport"
mkdir -p "$ARCHIFY_SOURCE" "$ARCHIFY_TRANSPORT"
cat >"$ARCHIFY_SOURCE/SKILL.md" <<'EOF'
---
name: archify
description: MacBook-only repository preserved across authority-set sync.
---

# Archify

This repository exists only on the target device.
EOF
printf '%s\n' "target-only payload" >"$ARCHIFY_SOURCE/local.txt"
"$CLI" skillet snapshot \
  --store "$TARGET_STORE" \
  --repository archify \
  --display-name "Archify" \
  --summary "Target-only repository preservation fixture" \
  --source "$ARCHIFY_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/archify-snapshot.json" \
  --json >"$TEST_ROOT/archify-snapshot.stdout.json"
"$CLI" skillet export-bound \
  --store "$TARGET_STORE" \
  --repository archify \
  --bundle "$ARCHIFY_TRANSPORT/bundle" \
  --binding "$ARCHIFY_TRANSPORT/authority-binding.json" \
  --request request-archify-local \
  --source-device mini-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 1 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/archify-export.json" \
  --json >"$TEST_ROOT/archify-export.stdout.json"
"$CLI" skillet import-activate \
  --bundle "$ARCHIFY_TRANSPORT/bundle" \
  --binding "$ARCHIFY_TRANSPORT/authority-binding.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --request request-archify-local \
  --source-device mini-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 1 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/archify-activation.json" \
  --json >"$TEST_ROOT/archify-activation.stdout.json"
archify_revision_before="$(json_get "$TEST_ROOT/archify-activation.json" revisionID)"
archify_digest_before="$(json_get "$TEST_ROOT/archify-activation.json" contentDigest)"
archify_runtime_before="$(runtime_digest "$MINI_RUNTIME_ROOT/archify")"

INITIAL_SET="$TEST_ROOT/initial-set"
mkdir -p "$INITIAL_SET"
make_bound_set "$SOURCE_STORE" request-initial 1 1 "$INITIAL_SET"
"$CLI" skillet import-activate-set \
  --set-manifest "$INITIAL_SET/set.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --request request-initial \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 1 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/initial-activation.json" \
  --json >"$TEST_ROOT/initial-activation.stdout.json"
[ "$(json_get "$TEST_ROOT/initial-activation.json" activationState)" = "active" ] \
  || fail "initial authority-bound set did not activate"
[ "$(json_get "$TEST_ROOT/initial-activation.json" targetPreservedCount)" = "1" ] \
  || fail "initial activation did not enumerate the target-only repository"
[ "$(json_get "$TEST_ROOT/initial-activation.json" targetPreservedRepositories.0.repositoryID)" \
    = "archify" ] \
  || fail "initial activation receipt omitted archify"
[ "$(json_get "$TEST_ROOT/initial-activation.json" targetPreservedRepositories.0.revisionID)" \
    = "$archify_revision_before" ] \
  || fail "initial activation receipt changed the archify revision"
[ "$(json_get "$TEST_ROOT/initial-activation.json" targetPreservedRepositories.0.contentDigest)" \
    = "$archify_digest_before" ] \
  || fail "initial activation receipt changed the archify digest"
[ "$(json_get "$TEST_ROOT/initial-activation.json" targetPreservedRepositories.0.state)" \
    = "runtime-preserved" ] \
  || fail "initial activation receipt did not classify archify as runtime-preserved"
[ "$(json_get "$TEST_ROOT/initial-activation.json" targetPreservedRuntimeClosureCapability)" \
    = "target-preserved-runtime-closure-v1" ] \
  || fail "initial activation receipt lacks the runtime-closure capability marker"
[ "$(json_get "$TEST_ROOT/initial-activation.json" targetPreservedRuntimeClosed)" \
    = "true" ] \
  || fail "initial activation receipt did not prove runtime closure"
[ "$(runtime_digest "$MINI_RUNTIME_ROOT/archify")" = "$archify_runtime_before" ] \
  || fail "initial authority-bound set changed the target-only archify runtime"
pass "initial authority-bound set activates the shared base and preserves target-only archify"

NO_PROMOTE_STORE="$TEST_ROOT/no-promote-store"
NO_PROMOTE_RUNTIME_ROOT="$TEST_ROOT/no-promote-runtime"
NO_PROMOTE_SET="$TEST_ROOT/no-promote-set"
mkdir -p "$NO_PROMOTE_SET"
"$CLI" skillet snapshot \
  --store "$NO_PROMOTE_STORE" \
  --repository archify \
  --display-name "Archify" \
  --summary "Target-only repository remains store-only without explicit promotion" \
  --source "$ARCHIFY_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/no-promote-archify-snapshot.json" \
  --json >"$TEST_ROOT/no-promote-archify-snapshot.stdout.json"
make_bound_set "$SOURCE_STORE" request-no-promote-target 1 2 "$NO_PROMOTE_SET"
"$CLI" skillet import-activate-set \
  --set-manifest "$NO_PROMOTE_SET/set.json" \
  --store "$NO_PROMOTE_STORE" \
  --runtime-root "$NO_PROMOTE_RUNTIME_ROOT" \
  --request request-no-promote-target \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 2 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/no-promote-activation.json" \
  --json >"$TEST_ROOT/no-promote-activation.stdout.json"
[ "$(json_get "$TEST_ROOT/no-promote-activation.json" targetPreservedRepositories.0.state)" \
    = "store-preserved" ] \
  || fail "target-only repository changed runtime state without the promotion flag"
[ "$(json_get "$TEST_ROOT/no-promote-activation.json" targetPreservedRuntimeClosureCapability)" \
    = "target-preserved-runtime-closure-v1" ] \
  || fail "non-promoting activation receipt lacks the runtime-closure capability marker"
[ "$(json_get "$TEST_ROOT/no-promote-activation.json" targetPreservedRuntimeClosed)" \
    = "false" ] \
  || fail "store-only target repository incorrectly claimed runtime closure"
[ ! -e "$NO_PROMOTE_RUNTIME_ROOT/archify" ] \
  || fail "target-only repository entered runtime without the promotion flag"
pass "target-preserved runtime closure is explicit and opt-in"

PROMOTE_STORE="$TEST_ROOT/promote-store"
PROMOTE_RUNTIME_ROOT="$TEST_ROOT/promote-runtime"
PROMOTE_SET="$TEST_ROOT/promote-set"
mkdir -p "$PROMOTE_SET"
"$CLI" skillet snapshot \
  --store "$PROMOTE_STORE" \
  --repository archify \
  --display-name "Archify" \
  --summary "Target-only repository runtime promotion fixture" \
  --source "$ARCHIFY_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/promote-archify-snapshot.json" \
  --json >"$TEST_ROOT/promote-archify-snapshot.stdout.json"
make_bound_set "$SOURCE_STORE" request-promote-target 1 2 "$PROMOTE_SET"
"$CLI" skillet import-activate-set \
  --set-manifest "$PROMOTE_SET/set.json" \
  --store "$PROMOTE_STORE" \
  --runtime-root "$PROMOTE_RUNTIME_ROOT" \
  --request request-promote-target \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 2 \
  --catalog-revision 2026-07-25.1 \
  --activate-target-preserved \
  --receipt "$TEST_ROOT/promote-activation.json" \
  --json >"$TEST_ROOT/promote-activation.stdout.json"
[ "$(json_get "$TEST_ROOT/promote-activation.json" targetPreservedCount)" = "1" ] \
  || fail "target-preserved runtime promotion omitted archify"
[ "$(json_get "$TEST_ROOT/promote-activation.json" targetPreservedRepositories.0.repositoryID)" \
    = "archify" ] \
  || fail "target-preserved runtime promotion returned the wrong repository"
[ "$(json_get "$TEST_ROOT/promote-activation.json" targetPreservedRepositories.0.state)" \
    = "runtime-preserved" ] \
  || fail "target-preserved store repository was not promoted into runtime"
[ "$(json_get "$TEST_ROOT/promote-activation.json" targetPreservedRuntimeClosureCapability)" \
    = "target-preserved-runtime-closure-v1" ] \
  || fail "promoted activation receipt lacks the runtime-closure capability marker"
[ "$(json_get "$TEST_ROOT/promote-activation.json" targetPreservedRuntimeClosed)" \
    = "true" ] \
  || fail "promoted activation receipt did not prove runtime closure"
[ "$(runtime_digest "$PROMOTE_RUNTIME_ROOT/archify")" \
    = "$(runtime_digest "$ARCHIFY_SOURCE")" ] \
  || fail "promoted target-preserved runtime does not match its canonical snapshot"
"$CLI" skillet verify-active-set \
  --set-manifest "$PROMOTE_SET/set.json" \
  --store "$PROMOTE_STORE" \
  --runtime-root "$PROMOTE_RUNTIME_ROOT" \
  --request request-promote-target \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 2 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/promote-verify.json" \
  --json >"$TEST_ROOT/promote-verify.stdout.json"
[ "$(json_get "$TEST_ROOT/promote-verify.json" targetPreservedRepositories.0.state)" \
    = "runtime-preserved" ] \
  || fail "active-set verification did not retain target-preserved runtime evidence"
[ "$(json_get "$TEST_ROOT/promote-verify.json" targetPreservedRuntimeClosed)" \
    = "true" ] \
  || fail "active-set verification did not prove target-preserved runtime closure"
pass "explicit target-preserved promotion keeps target-only skills consumer-visible"

READBACK_MIRROR="$TEST_ROOT/readback-mirror"
READBACK_CONSUMER="$TEST_ROOT/readback-consumer"
READBACK_CODEX_LINK="$TEST_ROOT/readback-codex-skills"
READBACK_CLAUDE_LINK="$TEST_ROOT/readback-claude-skills"
mkdir -p "$READBACK_MIRROR/os" "$READBACK_CONSUMER"
printf '%s\n' "# Work OS" >"$READBACK_MIRROR/os/os.md"
printf '%s\n' "# Issue" >"$READBACK_MIRROR/os/issue.md"
printf '%s\n' "# TODO" >"$READBACK_MIRROR/os/TODO.md"
ln -s "$MINI_RUNTIME_ROOT" "$READBACK_CONSUMER/current"
ln -s "$READBACK_CONSUMER/current" "$READBACK_CODEX_LINK"
ln -s "$READBACK_CONSUMER/current" "$READBACK_CLAUDE_LINK"
python3 - "$READBACK_MIRROR" "$INITIAL_SET/set.json" \
  "$TEST_ROOT/readback-manifest.json" <<'PY'
import hashlib
import json
import pathlib
import sys

mirror = pathlib.Path(sys.argv[1])
set_manifest = pathlib.Path(sys.argv[2])

def item(item_id, relative_path):
    data = (mirror / relative_path).read_bytes()
    return {
        "id": item_id,
        "displayName": item_id,
        "mirrorRelativePath": relative_path,
        "sourceDigest": hashlib.sha256(data).hexdigest(),
        "byteCount": len(data),
    }

set_data = set_manifest.read_bytes()
manifest = {
    "schemaVersion": 1,
    "requestID": "request-initial",
    "catalogRevision": "2026-07-25.1",
    "authorityEpoch": 1,
    "ledgerSequence": 1,
    "authorityPrimary": "book",
    "sourceDeviceID": "book-device",
    "targetDeviceID": "mini-device",
    "items": [
        item("os.constitution", "os/os.md"),
        item("os.issue", "os/issue.md"),
        item("os.todo", "os/TODO.md"),
        {
            "id": "skills.skillet",
            "displayName": "Skillet",
            "mirrorRelativePath": "skillet/repositories",
            "sourceDigest": hashlib.sha256(set_data).hexdigest(),
            "byteCount": len(set_data),
            "repositoryCount": 1,
        },
    ],
}
pathlib.Path(sys.argv[3]).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n"
)
PY
"$CLI" skillet consumer-readback \
  --manifest "$TEST_ROOT/readback-manifest.json" \
  --mirror-root "$READBACK_MIRROR" \
  --set-manifest "$INITIAL_SET/set.json" \
  --activation-receipt "$TEST_ROOT/initial-activation.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --consumer-root "$READBACK_CONSUMER" \
  --codex-skills-link "$READBACK_CODEX_LINK" \
  --claude-skills-link "$READBACK_CLAUDE_LINK" \
  --request request-initial \
  --target mini \
  --source-device book-device \
  --target-device mini-device \
  --authority-primary book \
  --authority-epoch 1 \
  --ledger-sequence 1 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/consumer-readback.json" \
  --json >"$TEST_ROOT/consumer-readback.stdout.json"
python3 - "$TEST_ROOT/consumer-readback.json" <<'PY' \
  || fail "five-consumer readback omitted target-only archify"
import json
import pathlib
import sys

receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = {
    "skillet.runtime-loader": "skillet/archify",
    "codex.native-skills": ".codex/skills/archify",
    "claude.native-skills": ".claude/skills/archify",
}
for consumer_id, loaded_path in expected.items():
    matches = [
        record for record in receipt["readbacks"]
        if record["consumerID"] == consumer_id
        and record["loadedPath"] == loaded_path
        and record["expectedDigest"] == record["loadedDigest"]
    ]
    assert len(matches) == 1, (consumer_id, matches)
assert receipt["readbackCount"] == 12, receipt["readbackCount"]
PY
pass "five consumers independently read incoming and target-preserved runtimes"

python3 - "$TEST_ROOT/initial-activation.json" \
  "$TEST_ROOT/stale-initial-activation.json" <<'PY'
import json
import pathlib
import sys

receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
receipt["ledgerSequence"] = 0
pathlib.Path(sys.argv[2]).write_text(json.dumps(receipt))
PY
if "$CLI" skillet consumer-readback \
  --manifest "$TEST_ROOT/readback-manifest.json" \
  --mirror-root "$READBACK_MIRROR" \
  --set-manifest "$INITIAL_SET/set.json" \
  --activation-receipt "$TEST_ROOT/stale-initial-activation.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --consumer-root "$READBACK_CONSUMER" \
  --codex-skills-link "$READBACK_CODEX_LINK" \
  --claude-skills-link "$READBACK_CLAUDE_LINK" \
  --request request-initial \
  --target mini \
  --source-device book-device \
  --target-device mini-device \
  --authority-primary book \
  --authority-epoch 1 \
  --ledger-sequence 1 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/stale-consumer-readback.json" \
  --json >/dev/null 2>&1
then
  fail "consumer readback accepted a stale activation receipt"
fi
pass "consumer readback rejects stale activation evidence"

printf '%s\n' "book branch" >"$BOOK_SOURCE/notes/book-only.txt"
"$CLI" skillet snapshot \
  --store "$SOURCE_STORE" \
  --repository demo-skill \
  --source "$BOOK_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/book-snapshot.json" \
  --json >"$TEST_ROOT/book-snapshot.stdout.json"

printf '%s\n' "mini branch" >"$MINI_SOURCE/notes/mini-only.txt"
"$CLI" skillet snapshot \
  --store "$TARGET_STORE" \
  --repository demo-skill \
  --source "$MINI_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/mini-snapshot.json" \
  --json >"$TEST_ROOT/mini-snapshot.stdout.json"

TARGET_METADATA="$TARGET_STORE/repositories/demo-skill/repository.json"
pre_merge_canonical="$(json_get "$TARGET_METADATA" canonicalRevision)"
pre_merge_runtime_digest="$(runtime_digest "$MINI_RUNTIME_ROOT/demo-skill")"
[ -n "$pre_merge_canonical" ] || fail "target canonical revision is missing"

DIVERGENT_SET="$TEST_ROOT/divergent-set"
mkdir -p "$DIVERGENT_SET"
make_bound_set "$SOURCE_STORE" request-divergent 1 2 "$DIVERGENT_SET"
set +e
"$CLI" skillet import-activate-set \
  --set-manifest "$DIVERGENT_SET/set.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --request request-divergent \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 2 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/merge-pending.json" \
  --json >"$TEST_ROOT/merge-pending.stdout.json" \
  2>"$TEST_ROOT/merge-pending.stderr.log"
merge_status=$?
set -e
[ "$merge_status" = "44" ] \
  || fail "divergent authority-bound set returned $merge_status instead of 44"
[ "$(json_get "$TEST_ROOT/merge-pending.json" schema)" \
    = "TatwoSkilletSetMergePendingCLIOutputV1" ] \
  || fail "divergent set did not write a merge-pending receipt"
[ "$(json_get "$TEST_ROOT/merge-pending.json" activationState)" = "merge-pending" ] \
  || fail "divergent receipt falsely reports active"
[ "$(json_get "$TEST_ROOT/merge-pending.json" proposalCount)" = "1" ] \
  || fail "divergent receipt does not enumerate exactly one proposal"
[ "$(json_get "$TEST_ROOT/merge-pending.json" targetPreservedCount)" = "1" ] \
  || fail "merge-pending receipt omitted the target-only repository"
[ "$(json_get "$TEST_ROOT/merge-pending.json" targetPreservedRepositories.0.repositoryID)" \
    = "archify" ] \
  || fail "merge-pending receipt omitted archify"
[ "$(json_get "$TEST_ROOT/merge-pending.json" targetPreservedRepositories.0.revisionID)" \
    = "$archify_revision_before" ] \
  || fail "merge-pending receipt changed the archify revision"
[ "$(json_get "$TEST_ROOT/merge-pending.json" targetPreservedRepositories.0.contentDigest)" \
    = "$archify_digest_before" ] \
  || fail "merge-pending receipt changed the archify digest"
[ "$(json_get "$TEST_ROOT/merge-pending.json" targetPreservedRepositories.0.state)" \
    = "runtime-preserved" ] \
  || fail "merge-pending receipt changed the archify runtime state"
proposal_id="$(json_get "$TEST_ROOT/merge-pending.json" proposalIDs.0)"
printf '%s\n' "$proposal_id" | grep -Eq '^merge-[0-9a-f]{64}$' \
  || fail "merge proposal id is not content-addressed"
[ "$(json_get "$TARGET_METADATA" canonicalRevision)" = "$pre_merge_canonical" ] \
  || fail "merge-pending advanced target canonical before human approval"
[ "$(runtime_digest "$MINI_RUNTIME_ROOT/demo-skill")" = "$pre_merge_runtime_digest" ] \
  || fail "merge-pending changed the active runtime"
proposed_revision="$(json_get "$TEST_ROOT/merge-pending.json" repositories.0.proposedRevisionID)"
python3 - "$TARGET_METADATA" "$proposed_revision" <<'PY' \
  || fail "incoming branch revision was not preserved in the target store"
import json
import pathlib
import sys

metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert sys.argv[2] in metadata["revisionIDs"]
PY
[ -f "$TARGET_STORE/repositories/demo-skill/merge-proposals/$proposal_id/proposal.json" ] \
  || fail "target store does not contain the durable merge proposal"
pass "real CLI exits 44 and preserves divergent history without runtime activation"

"$CLI" skillet merge-list \
  --store "$TARGET_STORE" \
  --repository demo-skill \
  --receipt "$TEST_ROOT/merge-list.json" \
  --json >"$TEST_ROOT/merge-list.stdout.json"
[ "$(json_get "$TEST_ROOT/merge-list.json" proposalCount)" = "1" ] \
  || fail "merge-list does not expose the pending proposal"
merged_revision="$(json_get "$TEST_ROOT/merge-list.json" proposals.0.mergedRevisionID)"
[ -n "$merged_revision" ] \
  || fail "non-overlapping divergent edits did not produce a clean merged revision"
set +e
"$CLI" skillet merge-resolve \
  --store "$TARGET_STORE" \
  --repository demo-skill \
  --proposal "$proposal_id" \
  --source "$BOOK_SOURCE" \
  --channel staging \
  --json >"$TEST_ROOT/clean-proposal-resolve.stdout.json" \
  2>"$TEST_ROOT/clean-proposal-resolve.stderr.log"
clean_resolve_status=$?
set -e
[ "$clean_resolve_status" = "45" ] \
  || fail "clean deterministic proposal accepted an unnecessary manual resolution"
pass "clean deterministic proposal rejects merge-resolve and proceeds by approval"

"$CLI" skillet merge-approve \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --repository demo-skill \
  --proposal "$proposal_id" \
  --decided-by sol-mainline \
  --receipt "$TEST_ROOT/merge-approve.json" \
  --json >"$TEST_ROOT/merge-approve.stdout.json"
[ "$(json_get "$TEST_ROOT/merge-approve.json" status)" = "approved" ] \
  || fail "merge proposal was not approved"
[ "$(json_get "$TEST_ROOT/merge-approve.json" runtimeActivationState)" = "unchanged" ] \
  || fail "merge approval did not explicitly preserve runtime state"
[ "$(json_get "$TEST_ROOT/merge-approve.json" runtimeBefore.state)" = "present" ] \
  || fail "merge approval did not read the active runtime before deciding"
[ "$(json_get "$TEST_ROOT/merge-approve.json" runtimeBefore.contentDigest)" \
    = "$(json_get "$TEST_ROOT/merge-approve.json" runtimeAfter.contentDigest)" ] \
  || fail "merge approval runtime readback digests differ"
[ "$(json_get "$TEST_ROOT/merge-approve.json" runtimeBefore.fileCount)" -gt 0 ] \
  || fail "merge approval runtime readback did not enumerate files"
[ "$(json_get "$TARGET_METADATA" canonicalRevision)" = "$merged_revision" ] \
  || fail "merge approval did not advance canonical to the merged revision"
[ "$(runtime_digest "$MINI_RUNTIME_ROOT/demo-skill")" = "$pre_merge_runtime_digest" ] \
  || fail "merge approval activated runtime without a new authority-bound request"
pass "human approval advances canonical while runtime remains unchanged"

"$CLI" skillet merge-approve \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --repository demo-skill \
  --proposal "$proposal_id" \
  --decided-by replay-operator \
  --receipt "$TEST_ROOT/merge-approve-replay.json" \
  --json >"$TEST_ROOT/merge-approve-replay.stdout.json"
[ "$(json_get "$TEST_ROOT/merge-approve-replay.json" decision.id)" \
    = "$(json_get "$TEST_ROOT/merge-approve.json" decision.id)" ] \
  || fail "approved merge replay did not return the original decision receipt"
[ "$(json_get "$TEST_ROOT/merge-approve-replay.json" status)" = "approved" ] \
  || fail "approved merge replay was not idempotent"
pass "approved merge replay is idempotent and does not return a stale status"

APPROVED_TO_BOOK_SET="$TEST_ROOT/approved-to-book-set"
mkdir -p "$APPROVED_TO_BOOK_SET"
make_bound_set \
  "$TARGET_STORE" request-approved-to-book 1 3 "$APPROVED_TO_BOOK_SET" \
  mini-device book-device
"$CLI" skillet import-activate-set \
  --set-manifest "$APPROVED_TO_BOOK_SET/set.json" \
  --store "$SOURCE_STORE" \
  --runtime-root "$BOOK_RUNTIME_ROOT" \
  --request request-approved-to-book \
  --source-device mini-device \
  --target-device book-device \
  --authority-epoch 1 \
  --ledger-sequence 3 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/book-convergence-activation.json" \
  --json >"$TEST_ROOT/book-convergence-activation.stdout.json"
"$CLI" skillet verify-active-set \
  --set-manifest "$APPROVED_TO_BOOK_SET/set.json" \
  --store "$SOURCE_STORE" \
  --runtime-root "$BOOK_RUNTIME_ROOT" \
  --request request-approved-to-book \
  --source-device mini-device \
  --target-device book-device \
  --authority-epoch 1 \
  --ledger-sequence 3 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/book-convergence-verify.json" \
  --json >"$TEST_ROOT/book-convergence-verify.stdout.json"
[ -f "$BOOK_RUNTIME_ROOT/demo-skill/notes/book-only.txt" ] \
  || fail "book runtime is missing its original branch after approved merge convergence"
[ -f "$BOOK_RUNTIME_ROOT/demo-skill/notes/mini-only.txt" ] \
  || fail "book runtime is missing the mini branch after approved merge convergence"
[ "$(json_get "$TEST_ROOT/book-convergence-activation.json" activationState)" = "active" ] \
  || fail "approved merged canonical did not activate on the source book"
[ "$(json_get "$SOURCE_STORE/repositories/demo-skill/repository.json" canonicalRevision)" \
    = "$merged_revision" ] \
  || fail "source book canonical did not converge to the approved merged revision"
pass "approved merge returns to the source book without a second proposal"

ROUNDTRIP_TO_MINI_SET="$TEST_ROOT/roundtrip-to-mini-set"
mkdir -p "$ROUNDTRIP_TO_MINI_SET"
make_bound_set \
  "$SOURCE_STORE" request-roundtrip-to-mini 1 4 "$ROUNDTRIP_TO_MINI_SET" \
  book-device mini-device
"$CLI" skillet import-activate-set \
  --set-manifest "$ROUNDTRIP_TO_MINI_SET/set.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --request request-roundtrip-to-mini \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 4 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/mini-roundtrip-activation.json" \
  --json >"$TEST_ROOT/mini-roundtrip-activation.stdout.json"
"$CLI" skillet verify-active-set \
  --set-manifest "$ROUNDTRIP_TO_MINI_SET/set.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --request request-roundtrip-to-mini \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 4 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/mini-roundtrip-verify.json" \
  --json >"$TEST_ROOT/mini-roundtrip-verify.stdout.json"
[ -f "$MINI_RUNTIME_ROOT/demo-skill/notes/book-only.txt" ] \
  || fail "mini runtime is missing the book branch after roundtrip convergence"
[ -f "$MINI_RUNTIME_ROOT/demo-skill/notes/mini-only.txt" ] \
  || fail "mini runtime is missing its original branch after roundtrip convergence"
[ "$(json_get "$TARGET_METADATA" canonicalRevision)" = "$merged_revision" ] \
  || fail "mini canonical regressed after the converged roundtrip"
[ "$(json_get "$TEST_ROOT/mini-roundtrip-activation.json" activationState)" = "active" ] \
  || fail "mini did not activate the converged roundtrip"
pass "book and mini accept the same approved merged revision bidirectionally"

BOOK_CONFLICT_SOURCE="$TEST_ROOT/book-conflict-source"
MINI_CONFLICT_SOURCE="$TEST_ROOT/mini-conflict-source"
cp -R "$BOOK_RUNTIME_ROOT/demo-skill" "$BOOK_CONFLICT_SOURCE"
cp -R "$MINI_RUNTIME_ROOT/demo-skill" "$MINI_CONFLICT_SOURCE"
printf '%s\n' "book conflicting edit" >"$BOOK_CONFLICT_SOURCE/notes/base.txt"
printf '%s\n' "mini conflicting edit" >"$MINI_CONFLICT_SOURCE/notes/base.txt"
"$CLI" skillet snapshot \
  --store "$SOURCE_STORE" \
  --repository demo-skill \
  --source "$BOOK_CONFLICT_SOURCE" \
  --channel staging \
  --receipt "$TEST_ROOT/book-conflict-snapshot.json" \
  --json >"$TEST_ROOT/book-conflict-snapshot.stdout.json"
"$CLI" skillet snapshot \
  --store "$TARGET_STORE" \
  --repository demo-skill \
  --source "$MINI_CONFLICT_SOURCE" \
  --channel staging \
  --receipt "$TEST_ROOT/mini-conflict-snapshot.json" \
  --json >"$TEST_ROOT/mini-conflict-snapshot.stdout.json"

CONFLICT_SET="$TEST_ROOT/conflict-set"
mkdir -p "$CONFLICT_SET"
make_bound_set \
  "$SOURCE_STORE" request-conflict 1 5 "$CONFLICT_SET" \
  book-device mini-device
set +e
"$CLI" skillet import-activate-set \
  --set-manifest "$CONFLICT_SET/set.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --request request-conflict \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 5 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/conflict-pending.json" \
  --json >"$TEST_ROOT/conflict-pending.stdout.json" \
  2>"$TEST_ROOT/conflict-pending.stderr.log"
conflict_import_status=$?
set -e
[ "$conflict_import_status" = "44" ] \
  || fail "conflicting authority-bound set returned $conflict_import_status instead of 44"
conflict_proposal_id="$(json_get "$TEST_ROOT/conflict-pending.json" proposalIDs.0)"
[ "$(json_get "$TEST_ROOT/conflict-pending.json" repositories.0.conflictCount)" != "0" ] \
  || fail "overlapping edits did not create a conflict artifact"

proposal_directory_count_before="$(
  find "$TARGET_STORE/repositories/demo-skill/merge-proposals" \
    -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
)"
set +e
"$CLI" skillet import-activate-set \
  --set-manifest "$CONFLICT_SET/set.json" \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --request request-conflict \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 1 \
  --ledger-sequence 5 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/conflict-pending-replay.json" \
  --json >"$TEST_ROOT/conflict-pending-replay.stdout.json" \
  2>"$TEST_ROOT/conflict-pending-replay.stderr.log"
conflict_replay_status=$?
set -e
[ "$conflict_replay_status" = "44" ] \
  || fail "same divergent bundle replay returned $conflict_replay_status instead of 44"
[ "$(json_get "$TEST_ROOT/conflict-pending-replay.json" proposalIDs.0)" \
    = "$conflict_proposal_id" ] \
  || fail "same divergent bundle replay produced a different proposal id"
proposal_directory_count_after="$(
  find "$TARGET_STORE/repositories/demo-skill/merge-proposals" \
    -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
)"
[ "$proposal_directory_count_after" = "$proposal_directory_count_before" ] \
  || fail "same divergent bundle replay created a duplicate proposal directory"
if find "$TARGET_STORE/repositories/demo-skill" \
  -name '.merge-proposal-staging-*' -print -quit | grep -q .; then
  fail "same divergent bundle replay left nested proposal staging behind"
fi
pass "same divergent bundle replay is idempotent and leaves no nested staging"

set +e
"$CLI" skillet merge-approve \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --repository demo-skill \
  --proposal "$conflict_proposal_id" \
  --decided-by conflict-operator \
  --receipt "$TEST_ROOT/conflict-approve.json" \
  --json >"$TEST_ROOT/conflict-approve.stdout.json" \
  2>"$TEST_ROOT/conflict-approve.stderr.log"
conflict_approve_status=$?
set -e
[ "$conflict_approve_status" = "45" ] \
  || fail "unresolved conflict returned $conflict_approve_status instead of 45"
grep -q "unresolved conflicts" "$TEST_ROOT/conflict-approve.stdout.json" \
  || fail "unresolved conflict exit does not explain the human resolution requirement"
pass "unresolved conflict uses dedicated exit 45"

STALE_ADVANCE_SOURCE="$TEST_ROOT/stale-advance-source"
cp -R "$MINI_CONFLICT_SOURCE" "$STALE_ADVANCE_SOURCE"
printf '%s\n' "advance canonical after proposal" \
  >"$STALE_ADVANCE_SOURCE/notes/stale-advance.txt"
"$CLI" skillet snapshot \
  --store "$TARGET_STORE" \
  --repository demo-skill \
  --source "$STALE_ADVANCE_SOURCE" \
  --channel staging \
  --receipt "$TEST_ROOT/stale-advance-snapshot.json" \
  --json >"$TEST_ROOT/stale-advance-snapshot.stdout.json"

set +e
"$CLI" skillet merge-approve \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --repository demo-skill \
  --proposal "$conflict_proposal_id" \
  --decided-by stale-operator \
  --receipt "$TEST_ROOT/stale-approve.json" \
  --json >"$TEST_ROOT/stale-approve.stdout.json" \
  2>"$TEST_ROOT/stale-approve.stderr.log"
stale_approve_status=$?
set -e
[ "$stale_approve_status" = "46" ] \
  || fail "stale merge proposal returned $stale_approve_status instead of 46"
grep -q "no longer matches the canonical head" "$TEST_ROOT/stale-approve.stdout.json" \
  || fail "stale proposal exit does not explain the canonical-head mismatch"
pass "stale merge proposal uses dedicated exit 46"

stale_canonical_before_reject="$(json_get "$TARGET_METADATA" canonicalRevision)"
"$CLI" skillet merge-reject \
  --store "$TARGET_STORE" \
  --runtime-root "$MINI_RUNTIME_ROOT" \
  --repository demo-skill \
  --proposal "$conflict_proposal_id" \
  --decided-by stale-operator \
  --receipt "$TEST_ROOT/stale-reject.json" \
  --json >"$TEST_ROOT/stale-reject.stdout.json"
[ "$(json_get "$TEST_ROOT/stale-reject.json" status)" = "rejected" ] \
  || fail "stale merge proposal could not be rejected"
[ "$(json_get "$TEST_ROOT/stale-reject.json" decision.stalenessReason)" != "" ] \
  || fail "stale rejection receipt omitted the staleness reason"
[ "$(json_get "$TARGET_METADATA" canonicalRevision)" = "$stale_canonical_before_reject" ] \
  || fail "stale rejection moved canonical"
pass "stale merge proposal can be rejected without activating anything"

OWNER_TARGET_STORE="$TEST_ROOT/owner-target-store"
OWNER_RUNTIME="$TEST_ROOT/owner-runtime"
OWNER_SOURCE="$TEST_ROOT/owner-mini-source"
mkdir -p "$OWNER_TARGET_STORE" "$OWNER_RUNTIME" "$OWNER_SOURCE/notes"
printf '%s\n' "---" "name: owner-target" "---" "owner-target-only" \
  >"$OWNER_SOURCE/SKILL.md"
printf '%s\n' "owner-target-only" >"$OWNER_SOURCE/notes/owner-target.txt"
"$CLI" skillet snapshot \
  --store "$OWNER_TARGET_STORE" \
  --repository demo-skill \
  --source "$OWNER_SOURCE" \
  --channel stable \
  --receipt "$TEST_ROOT/owner-target-snapshot.json" \
  --json >"$TEST_ROOT/owner-target-snapshot.stdout.json" \
  || fail "owner-target snapshot failed"

OWNER_SET="$TEST_ROOT/owner-apply-set"
mkdir -p "$OWNER_SET"
make_bound_set "$SOURCE_STORE" request-owner-apply 3 4 "$OWNER_SET"
set +e
"$CLI" skillet import-activate-set \
  --set-manifest "$OWNER_SET/set.json" \
  --store "$OWNER_TARGET_STORE" \
  --runtime-root "$OWNER_RUNTIME" \
  --request request-owner-apply \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 3 \
  --ledger-sequence 4 \
  --catalog-revision 2026-07-25.1 \
  --receipt "$TEST_ROOT/owner-park.json" \
  --json >"$TEST_ROOT/owner-park.stdout.json" \
  2>"$TEST_ROOT/owner-park.stderr.log"
owner_park_status=$?
set -e
[ "$owner_park_status" = "44" ] \
  || fail "non-owner divergent set returned $owner_park_status instead of 44"
pass "non-owner CLI path still parks divergent history"

"$CLI" skillet import-activate-set \
  --set-manifest "$OWNER_SET/set.json" \
  --store "$OWNER_TARGET_STORE" \
  --runtime-root "$OWNER_RUNTIME" \
  --request request-owner-apply \
  --source-device book-device \
  --target-device mini-device \
  --authority-epoch 3 \
  --ledger-sequence 4 \
  --catalog-revision 2026-07-25.1 \
  --owner-initiated \
  --activate-target-preserved \
  --receipt "$TEST_ROOT/owner-apply.json" \
  --json >"$TEST_ROOT/owner-apply.stdout.json" \
  2>"$TEST_ROOT/owner-apply.stderr.log" \
  || fail "owner-initiated divergent set failed to auto-apply"
[ "$(json_get "$TEST_ROOT/owner-apply.json" activationState)" = "active" ] \
  || fail "owner-initiated apply did not report active"
owner_archive="$(
  find "$OWNER_TARGET_STORE/repositories/demo-skill/receipts" -name 'archive-*.json' | head -1
)"
[ -n "$owner_archive" ] \
  || fail "owner-initiated apply did not write an archive receipt"
[ "$(json_get "$owner_archive" kind)" = "archive" ] \
  || fail "owner-initiated archive receipt has the wrong kind"
pass "owner-initiated CLI conflict auto-applies with archive receipt"

printf '%s\n' "tatwo_skillet_cli_merge_test=passed"
printf '%s\n' "tatwo_test_root_preserved=$TEST_ROOT"
