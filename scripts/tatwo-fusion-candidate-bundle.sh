#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_BRANCH="${TATWO_FUSION_BRANCH:-fusion/macbook-mini-20260718}"
BASE_COMMIT="${TATWO_FUSION_BASE_COMMIT:-89c9b275177adb06ad4c3ba50abc3192b3f0e751}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="${TATWO_FUSION_BUNDLE_ROOT:-$(
  mktemp -d "/private/tmp/tatwo-fusion-candidate-${STAMP}.XXXXXX"
)}"

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]]; then
  printf '%s\n' \
    'error: candidate transfer bundle requires a clean worktree' >&2
  exit 2
fi

BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
if [[ "$BRANCH" != "$EXPECTED_BRANCH" ]]; then
  printf 'error: expected branch %s, found %s\n' \
    "$EXPECTED_BRANCH" "$BRANCH" >&2
  exit 2
fi

HEAD_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
HEAD_TREE="$(git -C "$ROOT_DIR" rev-parse HEAD^{tree})"
git -C "$ROOT_DIR" merge-base --is-ancestor "$BASE_COMMIT" "$HEAD_COMMIT"

mkdir -p "$OUTPUT_ROOT"
if find "$OUTPUT_ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  printf 'error: candidate bundle root must be empty: %s\n' \
    "$OUTPUT_ROOT" >&2
  exit 2
fi

BUNDLE_PATH="$OUTPUT_ROOT/tatwo-fusion-${HEAD_COMMIT}.bundle"
MANIFEST_PATH="$OUTPUT_ROOT/tatwo-fusion-${HEAD_COMMIT}.json"
git -C "$ROOT_DIR" bundle create "$BUNDLE_PATH" HEAD "$BASE_COMMIT"
git -C "$ROOT_DIR" bundle verify "$BUNDLE_PATH" >/dev/null

BUNDLE_SHA256="$(shasum -a 256 "$BUNDLE_PATH" | awk '{print $1}')"
BUNDLE_BYTES="$(stat -f '%z' "$BUNDLE_PATH")"
TRACKED_FILES="$(git -C "$ROOT_DIR" ls-tree -r --name-only HEAD | wc -l | tr -d ' ')"

node - \
  "$MANIFEST_PATH" \
  "$BUNDLE_PATH" \
  "$BUNDLE_SHA256" \
  "$BUNDLE_BYTES" \
  "$BRANCH" \
  "$BASE_COMMIT" \
  "$HEAD_COMMIT" \
  "$HEAD_TREE" \
  "$TRACKED_FILES" \
  "$STAMP" <<'NODE'
import fs from "node:fs";
const [
  ,
  ,
  output,
  bundlePath,
  bundleSHA256,
  bundleBytes,
  branch,
  baseCommit,
  headCommit,
  headTree,
  trackedFiles,
  createdAt,
] = process.argv;
const manifest = {
  schema: "TatwoFusionCandidateTransferManifestV1",
  createdAt,
  branch,
  baseCommit,
  headCommit,
  headTree,
  trackedFiles: Number(trackedFiles),
  bundle: {
    path: bundlePath,
    sha256: bundleSHA256,
    bytes: Number(bundleBytes),
    gitBundleVerified: true,
  },
  transferPolicy: {
    source: "committed_git_objects_only",
    includesWorkingTreeState: false,
    includesApplicationSupport: false,
    includesAuthSessionToken: false,
    includesKeychainMaterial: false,
    includesLaunchAgentState: false,
    includesCaches: false,
  },
};
fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
NODE

printf 'candidate_bundle_status=passed\n'
printf 'candidate_bundle=%s\n' "$BUNDLE_PATH"
printf 'candidate_manifest=%s\n' "$MANIFEST_PATH"
printf 'candidate_commit=%s\n' "$HEAD_COMMIT"
