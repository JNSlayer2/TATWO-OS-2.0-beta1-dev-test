#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/tatwo-skills-consumer-projection.py"
PYTHON3="${TATWO_PYTHON3:-python3}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-skills-consumer-projection.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_symlink_target() {
  local link="$1" expected="$2" message="$3"
  [ -L "$link" ] || fail "$message: not a symlink"
  [ "$(readlink "$link")" = "$expected" ] \
    || fail "$message: expected raw target $expected, got $(readlink "$link")"
}

snapshot_digest() {
  "$PYTHON3" - "$1" <<'PY'
import hashlib
import os
import struct
import sys
import unicodedata

root = os.path.abspath(sys.argv[1])
files = []
for current, directories, names in os.walk(root, topdown=True, followlinks=False):
    kept = []
    for name in directories:
        path = os.path.join(current, name)
        if os.path.islink(path):
            raise SystemExit("symlink directory")
        if name.lower() == ".git":
            continue
        kept.append(name)
    directories[:] = kept
    for name in names:
        path = os.path.join(current, name)
        if os.path.islink(path) or not os.path.isfile(path):
            raise SystemExit("unsupported file")
        relative = unicodedata.normalize("NFC", os.path.relpath(path, root).replace(os.sep, "/"))
        with open(path, "rb") as handle:
            files.append((relative, handle.read()))
files.sort(key=lambda item: item[0].encode("utf-8"))
digest = hashlib.sha256()
for relative, data in files:
    encoded = relative.encode("utf-8")
    digest.update(struct.pack(">Q", len(encoded)))
    digest.update(encoded)
    digest.update(struct.pack(">Q", len(data)))
    digest.update(data)
print(digest.hexdigest())
PY
}

write_skill() {
  local root="$1" name="$2" body="$3"
  mkdir -p "$root/$name"
  cat >"$root/$name/SKILL.md" <<EOF
---
name: $name
description: Test native skill $name
---

$body
EOF
}

write_invalid_skill() {
  local root="$1" name="$2" body="$3"
  mkdir -p "$root/$name"
  printf '%s\n' "$body" >"$root/$name/SKILL.md"
}

[ -f "$HELPER" ] || fail "projection helper missing: $HELPER"

SOURCE="$TMP/source"
RUNTIME="$TMP/runtime"
CONSUMER="$TMP/consumer"
CODEX_HOME="$TMP/codex"
CLAUDE_HOME="$TMP/claude"
CODEX_LINK="$CODEX_HOME/skills"
CLAUDE_LINK="$CLAUDE_HOME/skills"
LEGACY_LINK="$TMP/legacy-skills"
mkdir -p "$SOURCE" "$RUNTIME" "$CODEX_HOME" "$CLAUDE_HOME"
write_skill "$SOURCE" alpha "# alpha source"
ln -s "$SOURCE" "$LEGACY_LINK"
ln -s "$LEGACY_LINK" "$CODEX_LINK"
ln -s "$SOURCE" "$CLAUDE_LINK"

BOOTSTRAP_RECEIPT="$TMP/bootstrap-receipt.json"
"$PYTHON3" "$HELPER" bootstrap \
  --source-root "$SOURCE" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --receipt "$BOOTSTRAP_RECEIPT"

assert_symlink_target "$CONSUMER/current" "$SOURCE" \
  "bootstrap current projection"
assert_symlink_target "$CODEX_LINK" "$CONSUMER/current" \
  "bootstrap Codex projection"
assert_symlink_target "$CLAUDE_LINK" "$CONSUMER/current" \
  "bootstrap Claude projection"
[ "$("$PYTHON3" -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$BOOTSTRAP_RECEIPT")" = "passed" ] \
  || fail "bootstrap receipt is not passed"

UNKNOWN="$TMP/unknown"
UNKNOWN_CONSUMER="$TMP/unknown-consumer"
UNKNOWN_CODEX="$TMP/unknown-codex/skills"
UNKNOWN_CLAUDE="$TMP/unknown-claude/skills"
mkdir -p "$UNKNOWN_CODEX" "$(dirname "$UNKNOWN_CLAUDE")"
ln -s "$SOURCE" "$UNKNOWN_CLAUDE"
if "$PYTHON3" "$HELPER" bootstrap \
  --source-root "$SOURCE" \
  --consumer-root "$UNKNOWN_CONSUMER" \
  --codex-skills-link "$UNKNOWN_CODEX" \
  --claude-skills-link "$UNKNOWN_CLAUDE" \
  --receipt "$UNKNOWN/receipt.json" >/dev/null 2>&1
then
  fail "bootstrap overwrote an unknown real native skills directory"
fi
[ -d "$UNKNOWN_CODEX" ] && [ ! -L "$UNKNOWN_CODEX" ] \
  || fail "unknown real native skills directory was mutated"
[ ! -e "$UNKNOWN_CONSUMER/current" ] \
  || fail "failed bootstrap mutated consumer current"

write_skill "$RUNTIME" alpha "# alpha runtime"
write_skill "$RUNTIME" beta "# beta runtime"
write_skill "$RUNTIME" archify "# target-only archify runtime"
ALPHA_DIGEST="$(snapshot_digest "$RUNTIME/alpha")"
BETA_DIGEST="$(snapshot_digest "$RUNTIME/beta")"
ARCHIFY_DIGEST="$(snapshot_digest "$RUNTIME/archify")"
SET_MANIFEST="$TMP/set.json"
cat >"$SET_MANIFEST" <<EOF
{
  "schemaVersion": 1,
  "requestID": "request-projection",
  "catalogRevision": "2026-07-25.1",
  "authorityEpoch": 2,
  "ledgerSequence": 3,
  "sourceDeviceID": "book-device",
  "targetDeviceID": "mini-device",
  "repositories": [
    {
      "repositoryID": "alpha",
      "revisionID": "rev-$ALPHA_DIGEST",
      "contentDigest": "$ALPHA_DIGEST",
      "bundleDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bundleRelativePath": "repositories/alpha/bundle",
      "bindingRelativePath": "repositories/alpha/authority-binding.json"
    },
    {
      "repositoryID": "beta",
      "revisionID": "rev-$BETA_DIGEST",
      "contentDigest": "$BETA_DIGEST",
      "bundleDigest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "bundleRelativePath": "repositories/beta/bundle",
      "bindingRelativePath": "repositories/beta/authority-binding.json"
    }
  ]
}
EOF
SKILLET_ACTIVATION_RECEIPT="$TMP/skillet-activation.json"
cat >"$SKILLET_ACTIVATION_RECEIPT" <<EOF
{
  "schema": "TatwoSkilletSetActivationCLIOutputV1",
  "requestID": "request-projection",
  "sourceDeviceID": "book-device",
  "targetDeviceID": "mini-device",
  "authorityEpoch": 2,
  "ledgerSequence": 3,
  "catalogRevision": "2026-07-25.1",
  "activationState": "active",
  "targetPreservedRuntimeClosureCapability": "target-preserved-runtime-closure-v1",
  "targetPreservedRuntimeClosed": true,
  "repositoryCount": 2,
  "repositories": [
    {
      "repositoryID": "alpha",
      "revisionID": "rev-$ALPHA_DIGEST",
      "contentDigest": "$ALPHA_DIGEST",
      "requestID": "request-projection",
      "sourceDeviceID": "book-device",
      "targetDeviceID": "mini-device",
      "authorityEpoch": 2,
      "ledgerSequence": 3,
      "catalogRevision": "2026-07-25.1",
      "activationState": "active"
    },
    {
      "repositoryID": "beta",
      "revisionID": "rev-$BETA_DIGEST",
      "contentDigest": "$BETA_DIGEST",
      "requestID": "request-projection",
      "sourceDeviceID": "book-device",
      "targetDeviceID": "mini-device",
      "authorityEpoch": 2,
      "ledgerSequence": 3,
      "catalogRevision": "2026-07-25.1",
      "activationState": "active"
    }
  ],
  "targetPreservedCount": 1,
  "targetPreservedRepositories": [
    {
      "repositoryID": "archify",
      "revisionID": "rev-$ARCHIFY_DIGEST",
      "contentDigest": "$ARCHIFY_DIGEST",
      "state": "runtime-preserved"
    }
  ]
}
EOF

# The projection must not accept a stale top-level authority binding or a
# forged per-repository binding merely because repository digests still match.
STALE_ACTIVATION_RECEIPT="$TMP/skillet-activation-stale.json"
FORGED_ACTIVATION_RECEIPT="$TMP/skillet-activation-forged.json"
LEGACY_ACTIVATION_RECEIPT="$TMP/skillet-activation-legacy-no-runtime-closure.json"
"$PYTHON3" - "$SKILLET_ACTIVATION_RECEIPT" \
  "$STALE_ACTIVATION_RECEIPT" "$FORGED_ACTIVATION_RECEIPT" \
  "$LEGACY_ACTIVATION_RECEIPT" <<'PY'
import json
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text())
stale = json.loads(json.dumps(source))
stale["ledgerSequence"] = 2
pathlib.Path(sys.argv[2]).write_text(json.dumps(stale))
forged = json.loads(json.dumps(source))
forged["repositories"][0]["sourceDeviceID"] = "forged-device"
pathlib.Path(sys.argv[3]).write_text(json.dumps(forged))
legacy = json.loads(json.dumps(source))
legacy.pop("targetPreservedRuntimeClosureCapability")
legacy.pop("targetPreservedRuntimeClosed")
pathlib.Path(sys.argv[4]).write_text(json.dumps(legacy))
PY
for invalid_receipt in \
  "$STALE_ACTIVATION_RECEIPT" \
  "$FORGED_ACTIVATION_RECEIPT" \
  "$LEGACY_ACTIVATION_RECEIPT"
do
  if "$PYTHON3" "$HELPER" activate \
    --runtime-root "$RUNTIME" \
    --consumer-root "$CONSUMER" \
    --codex-skills-link "$CODEX_LINK" \
    --claude-skills-link "$CLAUDE_LINK" \
    --set-manifest "$SET_MANIFEST" \
    --activation-receipt "$invalid_receipt" \
    --request "request-projection" \
    --receipt "$TMP/invalid-binding-receipt.json" >/dev/null 2>&1
  then
    fail "activate accepted a stale or forged Skillet activation receipt"
  fi
done

INCOMPLETE="$TMP/incomplete-runtime"
write_skill "$INCOMPLETE" alpha "# alpha runtime"
if "$PYTHON3" "$HELPER" activate \
  --runtime-root "$INCOMPLETE" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$TMP/incomplete-receipt.json" >/dev/null 2>&1
then
  fail "activate accepted incomplete runtime repository coverage"
fi
assert_symlink_target "$CONSUMER/current" "$SOURCE" \
  "failed activate must preserve source projection"

# A content-addressed repository is not yet a loadable native skill. The
# projection must reject a target-preserved repository whose SKILL.md lacks
# the YAML name/description contract before it can rebind Codex or Claude.
refresh_archify_binding() {
  local digest
  digest="$(snapshot_digest "$RUNTIME/archify")"
  "$PYTHON3" - "$SKILLET_ACTIVATION_RECEIPT" "$digest" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
digest = sys.argv[2]
value = json.loads(path.read_text())
repository = value["targetPreservedRepositories"][0]
repository["revisionID"] = f"rev-{digest}"
repository["contentDigest"] = digest
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
PY
}

INVALID_NATIVE_CASE=0
assert_invalid_native_manifest() {
  local body="$1" expected="$2" label="$3"
  local stderr receipt
  INVALID_NATIVE_CASE=$((INVALID_NATIVE_CASE + 1))
  stderr="$TMP/invalid-native-manifest-$INVALID_NATIVE_CASE.stderr"
  receipt="$TMP/invalid-native-manifest-receipt-$INVALID_NATIVE_CASE.json"
  write_invalid_skill "$RUNTIME" archify "$body"
  refresh_archify_binding
  if "$PYTHON3" "$HELPER" activate \
    --runtime-root "$RUNTIME" \
    --consumer-root "$CONSUMER" \
    --codex-skills-link "$CODEX_LINK" \
    --claude-skills-link "$CLAUDE_LINK" \
    --set-manifest "$SET_MANIFEST" \
    --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
    --request "request-projection" \
    --receipt "$receipt" \
    >/dev/null 2>"$stderr"
  then
    fail "activate accepted invalid native manifest: $label"
  fi
  grep -q "$expected" "$stderr" \
    || fail "invalid native manifest did not identify $label"
  assert_symlink_target "$CONSUMER/current" "$SOURCE" \
    "invalid native manifest must preserve source projection: $label"
  [ ! -e "$receipt" ] \
    || fail "invalid native manifest produced a passed receipt: $label"
}

assert_invalid_native_manifest \
  "# target-only archify without frontmatter" \
  "YAML frontmatter" \
  "missing frontmatter"
assert_invalid_native_manifest \
  $'\n---\nname: archify\ndescription: Leading blank must fail closed\n---\n' \
  "missing YAML frontmatter" \
  "frontmatter not at byte zero"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: # comment-only value\n---\n' \
  "description must be a string" \
  "comment-only description"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: \"unterminated\n---\n' \
  "invalid quoted string" \
  "unterminated quoted description"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: Native fixture\nunexpected: true\n---\n' \
  "unsupported top-level field" \
  "unsupported top-level field"
assert_invalid_native_manifest \
  $'---\nname: archify\nname: duplicate\ndescription: Native fixture\n---\n' \
  "duplicates name" \
  "duplicate required field"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: Native fixture\342\200\250---\342\200\250name: forged\nunexpected: true\n---\n' \
  "unsafe line separator" \
  "unicode line-separator delimiter smuggling"
assert_invalid_native_manifest \
  $'---\fname: archify\ndescription: Native fixture\n---\n' \
  "unsafe line separator" \
  "form-feed first-delimiter smuggling"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: Native fixture\nmetadata:\n  owner: first\n  owner: second\n---\n' \
  "metadata duplicates owner" \
  "duplicate metadata key"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: Native fixture\n' \
  "unclosed YAML frontmatter" \
  "unclosed frontmatter"
assert_invalid_native_manifest \
  $'---\ndescription: Native fixture\n---\n' \
  "missing name" \
  "missing name"
assert_invalid_native_manifest \
  $'---\nname: archify\n---\n' \
  "missing description" \
  "missing description"
assert_invalid_native_manifest \
  $'---\nname: true\ndescription: Native fixture\n---\n' \
  "name must be a string" \
  "non-string name"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: broken:\n---\n' \
  "description must be a string" \
  "invalid trailing-colon plain scalar"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: Native fixture\nmetadata:\n  owner:\n    nested: value\n---\n' \
  "flat string mapping" \
  "nested metadata"
assert_invalid_native_manifest \
  $'---\nname: >-\n  archify\ndescription: Native fixture\n---\n' \
  "name must use an inline string" \
  "name block scalar"
assert_invalid_native_manifest \
  $'---\nname: "- forged"\ndescription: Native fixture\n---\n' \
  "normalized lowercase skill identifier" \
  "leading YAML indicator in quoted name"
assert_invalid_native_manifest \
  $'---\nname: "a\\u0000b"\ndescription: Native fixture\n---\n' \
  "name contains an unsafe character" \
  "escaped NUL in name"
assert_invalid_native_manifest \
  $'---\nname: Forged\ndescription: Native fixture\n---\n' \
  "normalized lowercase skill identifier" \
  "uppercase native skill name"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: Native fixture\nmetadata:\n---\n' \
  "metadata must not be empty" \
  "null metadata block"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: Native fixture\nmetadata:\n  owner: first\n     second: value\n---\n' \
  "flat string mapping" \
  "inconsistent metadata indentation"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: Native fixture\nmetadata:\n  owner:\n---\n' \
  "flat string mapping" \
  "null metadata value"
assert_invalid_native_manifest \
  $'---\nname: archify\ndescription: %tag value\n---\n' \
  "description must be a string" \
  "reserved YAML directive indicator"

# Defense-in-depth branches that the snapshot layer normally rejects first
# still need direct regression coverage.
"$PYTHON3" - "$HELPER" "$TMP" <<'PY'
import importlib.util
import pathlib
import sys

sys.dont_write_bytecode = True
helper_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "tatwo_skills_consumer_projection",
    helper_path,
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

symlink_root = root / "direct-symlink-manifest"
symlink_root.mkdir()
target = root / "direct-symlink-target.md"
target.write_text(
    "---\nname: symlinked\ndescription: Symlink fixture\n---\n",
    encoding="utf-8",
)
(symlink_root / "SKILL.md").symlink_to(target)
try:
    module.validate_native_skill_manifest(str(symlink_root), "symlinked")
except module.ProjectionError as error:
    assert "missing regular SKILL.md" in str(error)
else:
    raise SystemExit("symlinked SKILL.md was accepted")

binary_root = root / "direct-non-utf8-manifest"
binary_root.mkdir()
(binary_root / "SKILL.md").write_bytes(
    b"---\nname: binary\ndescription: \xff\n---\n"
)
try:
    module.validate_native_skill_manifest(str(binary_root), "binary")
except module.ProjectionError as error:
    assert "not readable UTF-8" in str(error)
else:
    raise SystemExit("non-UTF-8 SKILL.md was accepted")

for index, separator in enumerate(module.UNSAFE_NATIVE_LINE_SEPARATORS):
    separator_root = root / f"direct-unsafe-separator-{index}"
    separator_root.mkdir()
    (separator_root / "SKILL.md").write_text(
        "---\n"
        "name: separator\n"
        f"description: before{separator}after\n"
        "---\n",
        encoding="utf-8",
    )
    try:
        module.validate_native_skill_manifest(
            str(separator_root),
            "separator",
        )
    except module.ProjectionError as error:
        assert "unsafe line separator" in str(error)
    else:
        raise SystemExit(f"unsafe separator U+{ord(separator):04X} was accepted")

inline_boundary_control_root = root / "direct-inline-boundary-control"
inline_boundary_control_root.mkdir()
(inline_boundary_control_root / "SKILL.md").write_text(
    "---\n"
    "name: inline-boundary-control\n"
    "description: boundary control\x1f\n"
    "---\n",
    encoding="utf-8",
)
try:
    module.validate_native_skill_manifest(
        str(inline_boundary_control_root),
        "inline-boundary-control",
    )
except module.ProjectionError as error:
    assert "unsafe" in str(error)
else:
    raise SystemExit("inline boundary control U+001F was accepted")

block_boundary_control_root = root / "direct-block-boundary-control"
block_boundary_control_root.mkdir()
(block_boundary_control_root / "SKILL.md").write_text(
    "---\n"
    "name: block-boundary-control\n"
    "description: >-\n"
    "  boundary control\x1f\n"
    "---\n",
    encoding="utf-8",
)
try:
    module.validate_native_skill_manifest(
        str(block_boundary_control_root),
        "block-boundary-control",
    )
except module.ProjectionError as error:
    assert "unsafe" in str(error)
else:
    raise SystemExit("block-scalar boundary control U+001F was accepted")

block_unsafe_root = root / "direct-block-unsafe-character"
block_unsafe_root.mkdir()
(block_unsafe_root / "SKILL.md").write_text(
    "---\n"
    "name: block-unsafe\n"
    "description: >-\n"
    "  before\u202eafter\n"
    "---\n",
    encoding="utf-8",
)
try:
    module.validate_native_skill_manifest(
        str(block_unsafe_root),
        "block-unsafe",
    )
except module.ProjectionError as error:
    assert "description contains an unsafe character" in str(error)
else:
    raise SystemExit("unsafe block-scalar description was accepted")

fullwidth_root = root / "direct-fullwidth-name"
fullwidth_root.mkdir()
(fullwidth_root / "SKILL.md").write_text(
    "---\n"
    "name: ａbc\n"
    "description: Fullwidth identifier fixture\n"
    "---\n",
    encoding="utf-8",
)
try:
    module.validate_native_skill_manifest(
        str(fullwidth_root),
        "fullwidth",
    )
except module.ProjectionError as error:
    assert "normalized lowercase skill identifier" in str(error)
else:
    raise SystemExit("NFKC-unstable native skill name was accepted")

alias_root = root / "direct-portable-alias"
alias_root.mkdir()
(alias_root / "SKILL.md").write_text(
    "---\n"
    "name: 刺青網頁\n"
    "description: Portable repository aliases may retain a native display name\n"
    "metadata: {}\n"
    "---\n",
    encoding="utf-8",
)
alias = module.validate_native_skill_manifest(
    str(alias_root),
    "tattoo-web",
)
assert alias["nativeSkillName"] == "刺青網頁"

crlf_root = root / "direct-crlf-manifest"
crlf_root.mkdir()
(crlf_root / "SKILL.md").write_bytes(
    b"---\r\nname: crlf\r\ndescription: CRLF fixture\r\n---\r\n"
)
assert module.validate_native_skill_manifest(
    str(crlf_root),
    "crlf",
)["nativeSkillName"] == "crlf"
PY

mkdir -p "$RUNTIME/archify"
cat >"$RUNTIME/archify/SKILL.md" <<'EOF'
---
name: archify
description: >-
  Target-only archify runtime
  loaded by native clients.
license: Proprietary
compatibility: macOS native clients
allowed-tools: Read Write
metadata:
  short-description: Native block scalar fixture
---

# target-only archify runtime
EOF
refresh_archify_binding

snapshot_recovery_inventory() {
  local destination="$1"
  local recovered="$CONSUMER/.tatwo-binding/recovered"
  mkdir -p "$recovered"
  find "$recovered" -type f -name '*.json' -print \
    | LC_ALL=C sort >"$destination"
}

assert_single_new_recovery() {
  local before="$1" expected_reason="$2" label="$3"
  local after="$before.after" added="$before.added" count recovery
  snapshot_recovery_inventory "$after"
  LC_ALL=C comm -13 "$before" "$after" >"$added"
  count="$(wc -l <"$added" | tr -d ' ')"
  [ "$count" = "1" ] \
    || fail "$label: expected one new rollback receipt, got $count"
  recovery="$(cat "$added")"
  "$PYTHON3" - "$recovery" "$expected_reason" <<'PY' \
    || fail "$label: rollback receipt did not prove the expected recovery"
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["phase"] == "rolled-back"
assert value["recoveryReason"] == sys.argv[2]
PY
}

# A native-manifest parser failure after current/Codex/Claude links have been
# rebound must roll all three links back and must not leave a passed receipt.
# Exercise both incoming repositories and target-preserved repositories.
assert_post_link_native_rollback() {
  local repository_id="$1"
  local receipt="$TMP/post-link-failure-$repository_id-receipt.json"
  local recovered_before="$TMP/post-link-failure-$repository_id-recovered-before.txt"
  local status
  snapshot_recovery_inventory "$recovered_before"
  set +e
  TATWO_TEST_MODE=1 \
  TATWO_TEST_INVALIDATE_NATIVE_MANIFEST_AFTER_LINK="$repository_id" \
    "$PYTHON3" "$HELPER" activate \
      --runtime-root "$RUNTIME" \
      --consumer-root "$CONSUMER" \
      --codex-skills-link "$CODEX_LINK" \
      --claude-skills-link "$CLAUDE_LINK" \
      --set-manifest "$SET_MANIFEST" \
      --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
      --request "request-projection" \
      --receipt "$receipt" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] \
    || fail "post-link native-manifest invalidation unexpectedly succeeded: $repository_id"
  assert_symlink_target "$CONSUMER/current" "$SOURCE" \
    "post-link native-manifest failure must roll back current: $repository_id"
  assert_symlink_target "$CODEX_LINK" "$CONSUMER/current" \
    "post-link native-manifest failure must roll back Codex: $repository_id"
  assert_symlink_target "$CLAUDE_LINK" "$CONSUMER/current" \
    "post-link native-manifest failure must roll back Claude: $repository_id"
  [ "$(realpath "$CODEX_LINK")" = "$(realpath "$SOURCE")" ] \
    || fail "post-link native-manifest failure left Codex on runtime: $repository_id"
  [ "$(realpath "$CLAUDE_LINK")" = "$(realpath "$SOURCE")" ] \
    || fail "post-link native-manifest failure left Claude on runtime: $repository_id"
  [ ! -e "$receipt" ] \
    || fail "post-link native-manifest failure left a passed receipt: $repository_id"
  [ ! -e "$CONSUMER/.tatwo-binding/transaction.json" ] \
    || fail "post-link native-manifest rollback left an active journal: $repository_id"
  assert_single_new_recovery \
    "$recovered_before" "projection failed" \
    "post-link native-manifest rollback: $repository_id"
}

assert_post_link_native_rollback alpha
assert_post_link_native_rollback archify

CRASH_RECOVERY_BEFORE="$TMP/crash-recovery-before.txt"
snapshot_recovery_inventory "$CRASH_RECOVERY_BEFORE"
set +e
TATWO_TEST_MODE=1 \
TATWO_TEST_CRASH_AFTER_CURRENT_SWAP=1 \
  "$PYTHON3" "$HELPER" activate \
    --runtime-root "$RUNTIME" \
    --consumer-root "$CONSUMER" \
    --codex-skills-link "$CODEX_LINK" \
    --claude-skills-link "$CLAUDE_LINK" \
    --set-manifest "$SET_MANIFEST" \
    --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
    --request "request-projection" \
    --receipt "$TMP/activate-receipt.json" >/dev/null 2>&1
crash_status=$?
set -e
[ "$crash_status" -ne 0 ] || fail "crash injection unexpectedly succeeded"
[ -f "$CONSUMER/.tatwo-binding/transaction.json" ] \
  || fail "crash injection left no durable transaction journal"

ACTIVATE_RECEIPT="$TMP/activate-receipt.json"
"$PYTHON3" "$HELPER" activate \
  --runtime-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$ACTIVATE_RECEIPT"

assert_symlink_target "$CONSUMER/current" "$RUNTIME" \
  "runtime current projection"
assert_symlink_target "$CODEX_LINK" "$CONSUMER/current" \
  "runtime Codex projection"
assert_symlink_target "$CLAUDE_LINK" "$CONSUMER/current" \
  "runtime Claude projection"
[ "$(realpath "$CODEX_LINK")" = "$(realpath "$RUNTIME")" ] \
  || fail "Codex native link did not resolve to runtime"
[ "$(realpath "$CLAUDE_LINK")" = "$(realpath "$RUNTIME")" ] \
  || fail "Claude native link did not resolve to runtime"
[ -f "$CODEX_LINK/archify/SKILL.md" ] \
  || fail "Codex native projection omitted target-only archify"
[ -f "$CLAUDE_LINK/archify/SKILL.md" ] \
  || fail "Claude native projection omitted target-only archify"
[ "$("$PYTHON3" -c 'import json,sys; print(json.load(open(sys.argv[1]))["targetPreservedCount"])' "$ACTIVATE_RECEIPT")" = "1" ] \
  || fail "projection receipt omitted target-preserved repository count"
[ "$("$PYTHON3" -c 'import json,sys; print(json.load(open(sys.argv[1]))["targetPreservedRepositories"][0]["repositoryID"])' "$ACTIVATE_RECEIPT")" = "archify" ] \
  || fail "projection receipt omitted target-only archify"
"$PYTHON3" - "$ACTIVATE_RECEIPT" <<'PY' \
  || fail "projection receipt omitted native manifest validation evidence"
import json
import re
import sys

value = json.load(open(sys.argv[1]))
repositories = value["repositories"] + value["targetPreservedRepositories"]
assert len(repositories) == 3
assert {repository["repositoryID"] for repository in repositories} == {
    "alpha",
    "archify",
    "beta",
}
for repository in repositories:
    assert repository["nativeManifestStatus"] == "valid"
    assert repository["nativeSkillName"] == repository["repositoryID"]
    assert re.fullmatch(
        r"[0-9a-f]{64}",
        repository["nativeManifestDigest"],
    )
PY
assert_single_new_recovery \
  "$CRASH_RECOVERY_BEFORE" "interrupted projection transaction" \
  "activation retry crash recovery"

activate_receipt_digest_before="$(shasum -a 256 "$ACTIVATE_RECEIPT" | awk '{print $1}')"
"$PYTHON3" "$HELPER" activate \
  --runtime-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$ACTIVATE_RECEIPT" >/dev/null
[ "$(shasum -a 256 "$ACTIVATE_RECEIPT" | awk '{print $1}')" = "$activate_receipt_digest_before" ] \
  || fail "idempotent activation rewrote its immutable receipt"
[ ! -f "$CONSUMER/.tatwo-binding/transaction.json" ] \
  || fail "idempotent activation left a new transaction journal"

# V1 additive compatibility: a pre-native-evidence immutable receipt/state
# remains valid only when all three new evidence keys are absent together.
# Idempotent activation must preserve those legacy bytes; partial evidence
# must fail closed.
LEGACY_NATIVE_RECEIPT_COPY="$TMP/activate-receipt-legacy-native.json"
LEGACY_NATIVE_STATE_COPY="$TMP/state-legacy-native.json"
"$PYTHON3" - "$ACTIVATE_RECEIPT" \
  "$CONSUMER/.tatwo-binding/state.json" \
  "$LEGACY_NATIVE_RECEIPT_COPY" "$LEGACY_NATIVE_STATE_COPY" <<'PY'
import json
import os
import pathlib
import sys

evidence_keys = (
    "nativeManifestStatus",
    "nativeSkillName",
    "nativeManifestDigest",
)
for source_raw, destination_raw in (
    (sys.argv[1], sys.argv[3]),
    (sys.argv[2], sys.argv[4]),
):
    source = pathlib.Path(source_raw)
    destination = pathlib.Path(destination_raw)
    value = json.loads(source.read_text())
    for collection in (
        value["repositories"],
        value["targetPreservedRepositories"],
    ):
        for repository in collection:
            for key in evidence_keys:
                repository.pop(key)
    destination.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(destination, source.stat().st_mode)
    os.replace(destination, source)
    destination.write_bytes(source.read_bytes())
PY
legacy_native_receipt_digest="$(shasum -a 256 "$ACTIVATE_RECEIPT" | awk '{print $1}')"
"$PYTHON3" "$HELPER" activate \
  --runtime-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$ACTIVATE_RECEIPT" >/dev/null
[ "$(shasum -a 256 "$ACTIVATE_RECEIPT" | awk '{print $1}')" = "$legacy_native_receipt_digest" ] \
  || fail "legacy native-evidence activation rewrote immutable receipt"

"$PYTHON3" - "$ACTIVATE_RECEIPT" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["repositories"][0]["nativeManifestStatus"] = "valid"
replacement = path.with_name(path.name + ".partial-native")
replacement.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
os.chmod(replacement, path.stat().st_mode)
os.replace(replacement, path)
PY
if "$PYTHON3" "$HELPER" activate \
  --runtime-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$ACTIVATE_RECEIPT" >/dev/null 2>&1
then
  fail "activation accepted partial native evidence in immutable receipt"
fi
cp "$LEGACY_NATIVE_RECEIPT_COPY" "$ACTIVATE_RECEIPT"

"$PYTHON3" - "$CONSUMER/.tatwo-binding/state.json" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["targetPreservedRepositories"][0]["nativeSkillName"] = "archify"
replacement = path.with_name(path.name + ".partial-native")
replacement.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
os.chmod(replacement, path.stat().st_mode)
os.replace(replacement, path)
PY
if "$PYTHON3" "$HELPER" activate \
  --runtime-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$ACTIVATE_RECEIPT" >/dev/null 2>&1
then
  fail "activation accepted partial native evidence in projection state"
fi
cp "$LEGACY_NATIVE_STATE_COPY" "$CONSUMER/.tatwo-binding/state.json"

"$PYTHON3" "$HELPER" verify \
  --expected-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$TMP/verify-receipt.json"

# A device activated before target-preserved receipts existed has neither
# targetPreservedCount nor targetPreservedRepositories in its projection state
# and immutable origin activation receipt. Re-enrollment must safely normalize
# that legacy empty set instead of making the governed CLI upgrade impossible.
LEGACY_RUNTIME="$TMP/legacy-runtime"
LEGACY_CONSUMER="$TMP/legacy-consumer"
LEGACY_CODEX_LINK="$TMP/legacy-codex/skills"
LEGACY_CLAUDE_LINK="$TMP/legacy-claude/skills"
LEGACY_ACTIVATE_RECEIPT="$TMP/legacy-activate-receipt.json"
LEGACY_SKILLET_ACTIVATION_RECEIPT="$TMP/legacy-skillet-activation.json"
mkdir -p "$LEGACY_RUNTIME" "$(dirname "$LEGACY_CODEX_LINK")" \
  "$(dirname "$LEGACY_CLAUDE_LINK")"
cp -R "$RUNTIME/alpha" "$LEGACY_RUNTIME/alpha"
cp -R "$RUNTIME/beta" "$LEGACY_RUNTIME/beta"
ln -s "$SOURCE" "$LEGACY_CODEX_LINK"
ln -s "$SOURCE" "$LEGACY_CLAUDE_LINK"
"$PYTHON3" - "$SKILLET_ACTIVATION_RECEIPT" \
  "$LEGACY_SKILLET_ACTIVATION_RECEIPT" <<'PY'
import json
import pathlib
import sys

receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
receipt["targetPreservedCount"] = 0
receipt["targetPreservedRepositories"] = []
pathlib.Path(sys.argv[2]).write_text(json.dumps(receipt))
PY
"$PYTHON3" "$HELPER" bootstrap \
  --source-root "$SOURCE" \
  --consumer-root "$LEGACY_CONSUMER" \
  --codex-skills-link "$LEGACY_CODEX_LINK" \
  --claude-skills-link "$LEGACY_CLAUDE_LINK" \
  --receipt "$TMP/legacy-bootstrap-receipt.json" >/dev/null
"$PYTHON3" "$HELPER" activate \
  --runtime-root "$LEGACY_RUNTIME" \
  --consumer-root "$LEGACY_CONSUMER" \
  --codex-skills-link "$LEGACY_CODEX_LINK" \
  --claude-skills-link "$LEGACY_CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$LEGACY_SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$LEGACY_ACTIVATE_RECEIPT" >/dev/null
"$PYTHON3" - "$LEGACY_CONSUMER/.tatwo-binding/state.json" \
  "$LEGACY_ACTIVATE_RECEIPT" <<'PY'
import json
import os
import pathlib
import sys

for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    value = json.loads(path.read_text())
    value.pop("targetPreservedCount", None)
    value.pop("targetPreservedRepositories", None)
    replacement = path.with_name(path.name + ".legacy")
    replacement.write_text(json.dumps(value))
    os.replace(replacement, path)
PY
"$PYTHON3" "$HELPER" enroll \
  --source-root "$SOURCE" \
  --runtime-root "$LEGACY_RUNTIME" \
  --consumer-root "$LEGACY_CONSUMER" \
  --codex-skills-link "$LEGACY_CODEX_LINK" \
  --claude-skills-link "$LEGACY_CLAUDE_LINK" \
  --receipt "$TMP/legacy-adopt-runtime-receipt.json" >/dev/null
"$PYTHON3" - "$TMP/legacy-adopt-runtime-receipt.json" \
  "$LEGACY_CONSUMER/.tatwo-binding/state.json" <<'PY'
import json
import sys

for path in sys.argv[1:]:
    value = json.load(open(path, encoding="utf-8"))
    if value.get("targetPreservedCount") != 0:
        raise SystemExit("legacy adoption target-preserved count")
    if value.get("targetPreservedRepositories") != []:
        raise SystemExit("legacy adoption target-preserved repositories")
PY
"$PYTHON3" - "$LEGACY_CONSUMER/.tatwo-binding/state.json" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value.pop("targetPreservedRepositories")
replacement = path.with_name(path.name + ".partial")
replacement.write_text(json.dumps(value))
os.replace(replacement, path)
PY
if "$PYTHON3" "$HELPER" enroll \
  --source-root "$SOURCE" \
  --runtime-root "$LEGACY_RUNTIME" \
  --consumer-root "$LEGACY_CONSUMER" \
  --codex-skills-link "$LEGACY_CODEX_LINK" \
  --claude-skills-link "$LEGACY_CLAUDE_LINK" \
  --receipt "$TMP/partial-target-preserved-adopt-receipt.json" >/dev/null 2>&1
then
  fail "runtime adoption accepted partial target-preserved state evidence"
fi

# Re-enrollment must keep an already activated runtime live, while repairing a
# native entrypoint that still resolves to one of the explicitly enrolled roots.
rm "$CLAUDE_LINK"
ln -s "$SOURCE" "$CLAUDE_LINK"
ADOPT_RECEIPT="$TMP/adopt-runtime-receipt.json"
"$PYTHON3" "$HELPER" enroll \
  --source-root "$SOURCE" \
  --runtime-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --receipt "$ADOPT_RECEIPT"
assert_symlink_target "$CONSUMER/current" "$RUNTIME" \
  "runtime adoption current projection"
assert_symlink_target "$CODEX_LINK" "$CONSUMER/current" \
  "runtime adoption Codex reprojection"
assert_symlink_target "$CLAUDE_LINK" "$CONSUMER/current" \
  "runtime adoption Claude reprojection"
"$PYTHON3" - "$ADOPT_RECEIPT" "$CONSUMER/.tatwo-binding/state.json" "$ACTIVATE_RECEIPT" <<'PY'
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
state = json.load(open(sys.argv[2], encoding="utf-8"))
expected_origin = sys.argv[3]
if receipt.get("operation") != "adopt-runtime":
    raise SystemExit("adoption receipt operation")
if receipt.get("desiredRootDigestMode") != "runtime-adoption-v1":
    raise SystemExit("adoption receipt digest mode")
if receipt.get("originActivationReceiptPath") != expected_origin:
    raise SystemExit("adoption origin receipt")
if receipt.get("requestID") != "request-projection":
    raise SystemExit("adoption request binding")
if state.get("mode") != "runtime-adopted":
    raise SystemExit("adoption state mode")
if state.get("originActivationReceiptPath") != expected_origin:
    raise SystemExit("adoption state origin receipt")
PY

# A second enrollment adopts from the prior adoption state without losing the
# original activation receipt or switching consumers back to canonical source.
SECOND_ADOPT_RECEIPT="$TMP/adopt-runtime-receipt-2.json"
"$PYTHON3" "$HELPER" enroll \
  --source-root "$SOURCE" \
  --runtime-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --receipt "$SECOND_ADOPT_RECEIPT" >/dev/null
[ "$("$PYTHON3" -c 'import json,sys; print(json.load(open(sys.argv[1]))["adoptedFromMode"])' "$SECOND_ADOPT_RECEIPT")" = "runtime-adopted" ] \
  || fail "second enrollment did not adopt the prior runtime-adopted state"
[ "$("$PYTHON3" -c 'import json,sys; print(json.load(open(sys.argv[1]))["originActivationReceiptPath"])' "$SECOND_ADOPT_RECEIPT")" = "$ACTIVATE_RECEIPT" ] \
  || fail "second enrollment lost the original activation receipt"
assert_symlink_target "$CONSUMER/current" "$RUNTIME" \
  "second runtime adoption preserved runtime"

# An explicitly enrolled runtime path is necessary but not sufficient: unknown
# native roots and unmanaged current directories remain fail-closed.
UNKNOWN_RUNTIME_NATIVE="$TMP/unknown-runtime-native"
mkdir -p "$UNKNOWN_RUNTIME_NATIVE"
rm "$CLAUDE_LINK"
ln -s "$UNKNOWN_RUNTIME_NATIVE" "$CLAUDE_LINK"
if "$PYTHON3" "$HELPER" enroll \
  --source-root "$SOURCE" \
  --runtime-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --receipt "$TMP/unknown-native-adopt-receipt.json" >/dev/null 2>&1
then
  fail "runtime adoption accepted an unknown native skills root"
fi
assert_symlink_target "$CONSUMER/current" "$RUNTIME" \
  "failed runtime adoption must preserve current runtime"
assert_symlink_target "$CLAUDE_LINK" "$UNKNOWN_RUNTIME_NATIVE" \
  "failed runtime adoption mutated the unknown native root"

REAL_CURRENT_CONSUMER="$TMP/real-current-consumer"
REAL_CURRENT_CODEX="$TMP/real-current-codex/skills"
REAL_CURRENT_CLAUDE="$TMP/real-current-claude/skills"
mkdir -p "$REAL_CURRENT_CONSUMER/current" \
  "$(dirname "$REAL_CURRENT_CODEX")" "$(dirname "$REAL_CURRENT_CLAUDE")"
ln -s "$SOURCE" "$REAL_CURRENT_CODEX"
ln -s "$SOURCE" "$REAL_CURRENT_CLAUDE"
if "$PYTHON3" "$HELPER" enroll \
  --source-root "$SOURCE" \
  --runtime-root "$RUNTIME" \
  --consumer-root "$REAL_CURRENT_CONSUMER" \
  --codex-skills-link "$REAL_CURRENT_CODEX" \
  --claude-skills-link "$REAL_CURRENT_CLAUDE" \
  --receipt "$TMP/real-current-enroll-receipt.json" >/dev/null 2>&1
then
  fail "enrollment accepted an unmanaged real current directory"
fi
[ -d "$REAL_CURRENT_CONSUMER/current" ] \
  && [ ! -L "$REAL_CURRENT_CONSUMER/current" ] \
  || fail "failed enrollment mutated the unmanaged current directory"

rm "$CLAUDE_LINK"
ln -s "$SOURCE" "$CLAUDE_LINK"
if "$PYTHON3" "$HELPER" verify \
  --expected-root "$RUNTIME" \
  --consumer-root "$CONSUMER" \
  --codex-skills-link "$CODEX_LINK" \
  --claude-skills-link "$CLAUDE_LINK" \
  --set-manifest "$SET_MANIFEST" \
  --activation-receipt "$SKILLET_ACTIVATION_RECEIPT" \
  --request "request-projection" \
  --receipt "$TMP/drift-receipt.json" >/dev/null 2>&1
then
  fail "verify accepted Claude native-link drift"
fi

printf 'tatwo_skills_consumer_projection_test=passed\n'
