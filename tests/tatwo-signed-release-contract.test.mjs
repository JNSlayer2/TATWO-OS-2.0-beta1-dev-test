#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scriptPath = path.join(root, "scripts", "tatwo-build-signed-release.sh");
const text = fs.readFileSync(scriptPath, "utf8");

for (const required of [
  "TATWO_DEVELOPER_ID_APPLICATION",
  "TATWO_NOTARY_KEYCHAIN_PROFILE",
  "TATWO_SPARKLE_KEY_ACCOUNT",
  "TATWO_RELEASE_SCHEMA_VERSION",
  "TATWO_RELEASE_PROTOCOL_VERSION",
  "TATWO_ROLLBACK_TARGET_VERSION",
  "status --porcelain=v1 --untracked-files=all",
  "Developer ID Application:",
  "generate_appcast",
  "sign_update",
  "generate_keys",
  "notarytool submit",
  "stapler staple",
  "stapler validate",
  "TatwoSignedReleaseManifestV1",
  "TatwoSignedReleaseReceiptV1",
  "APPCAST_SHA256",
  "APP_CDHASH",
  "TatwoPLGAnchorHelperSHA256",
  "updateEvidence",
  "appcastSHA256",
  "bundleCDHash",
  "MANIFEST_SIGNATURE_PATH",
  "activationRequiresUserApproval",
  "app_bundle_only",
  "userDataRollbackAllowed",
  "domainLedgerRollbackAllowed",
  "retainedEvidence",
  "retain_release_evidence_no_direct_delete",
]) {
  assert.ok(text.includes(required), `missing signed release contract: ${required}`);
}

assert.match(text, /--channel "\$TATWO_UPDATE_CHANNEL"/);
assert.match(text, /--maximum-deltas 0/);
assert.match(text, /--verify \\\n\s+"\$APPCAST_PATH"/);
assert.match(text, /--verify \\\n\s+"\$ARTIFACT_PATH"/);
assert.match(
  text,
  /xcrun stapler validate "\$APP_BUNDLE"[\s\S]+APPCAST_SHA256=[\s\S]+MANIFEST_SIGNATURE_PATH=/,
);
assert.doesNotMatch(text, /PRIVATE_KEY_SECRET|ed-key-file|-s <private/);
assert.doesNotMatch(
  text,
  /(^|[\s;&|])(rm|rmdir)(?:\s|$)|\/Applications\/Tatwo OS\.app/m,
);
