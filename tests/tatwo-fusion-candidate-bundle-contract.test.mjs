#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = fs.readFileSync(
  path.join(root, "scripts", "tatwo-fusion-candidate-bundle.sh"),
  "utf8",
);

for (const required of [
  "status --porcelain=v1 --untracked-files=all",
  "merge-base --is-ancestor",
  "bundle create",
  "bundle verify",
  "TatwoFusionCandidateTransferManifestV1",
  "committed_git_objects_only",
  "includesWorkingTreeState: false",
  "includesApplicationSupport: false",
  "includesAuthSessionToken: false",
  "includesKeychainMaterial: false",
  "includesLaunchAgentState: false",
  "includesCaches: false",
]) {
  assert.ok(script.includes(required), `missing candidate transfer guard: ${required}`);
}

assert.doesNotMatch(script, /tar\s|ditto\s|cp\s+-R|rsync|rm -rf/);
