#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");

const contract = read("scripts/tatwo-main-app-contract.sh");
for (const required of [
  'TATWO_MAIN_APP_NAME="Tatwo Ultrawork"',
  'TATWO_MAIN_APP_BUNDLE_ID="com.tatwo.ultrawork"',
  'TATWO_MAIN_APP_SUPPORT_NAME="Tatwo Ultrawork"',
]) {
  assert.ok(contract.includes(required), `missing canonical main App contract: ${required}`);
}

const productionBuilder = read("script/build_production_app.sh");
const signedRelease = read("scripts/tatwo-build-signed-release.sh");
const installer = read("scripts/install-tatwo-ultrawork.sh");
const localRunner = read("script/build_and_run.sh");
const legacyInstaller = read("scripts/install-j2-temp.sh");
const safeActivation = read("scripts/tatwo-safe-app-bundle.sh");
const chromiumBackend = read(
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChromiumCEFBackend.swift",
);
const moduleManifest = JSON.parse(read("Modules/App/module.json"));

for (const text of [productionBuilder, signedRelease, installer]) {
  assert.match(text, /tatwo-main-app-contract\.sh/);
  assert.doesNotMatch(text, /Tatwo OS\.app/);
}

assert.match(productionBuilder, /TATWO_MAIN_APP_BUNDLE_FILENAME/);
assert.match(productionBuilder, /TATWO_MAIN_APP_BUNDLE_ID/);
assert.match(productionBuilder, /TATWO_MAIN_APP_NAME/);
assert.match(signedRelease, /Tatwo-Ultrawork-/);
assert.match(installer, /TATWO_ULTRAWORK_APP_DIR:-\/Applications/);
assert.match(installer, /TATWO_VERIFIED_PRODUCTION_APP_BUNDLE/);
assert.match(installer, /TATWO_VERIFIED_SIGNED_RELEASE_MANIFEST/);
assert.match(installer, /TATWO_VERIFIED_SIGNED_RELEASE_MANIFEST_SIGNATURE/);
assert.match(installer, /TATWO_VERIFIED_SIGNED_RELEASE_RECEIPT/);
assert.match(installer, /TATWO_VERIFIED_SIGNED_RELEASE_APPCAST/);
assert.match(installer, /production-release-promotion-v1/);
assert.match(installer, /production-release-promotion-archives\.noindex/);
assert.match(installer, /manifestSignatureVerified !== true/);
assert.match(installer, /appcastSignatureVerified !== true/);
assert.match(installer, /production promotion manifest signature is invalid/);
assert.match(installer, /Authority=Developer ID Application:/);
assert.match(installer, /spctl --assess/);
assert.doesNotMatch(installer, /codesign --force --deep --sign -/);
assert.match(installer, /TATWO_MAIN_APP_SUPPORT_NAME/);
assert.match(installer, /TATWO_ULTRAWORK_STATE_DIR:-\$APP_SUPPORT_DIR\/state/);
assert.match(safeActivation, /TATWO_ULTRAWORK_ARCHIVE_ROOT/);
assert.match(safeActivation, /tatwo_real_path/);
assert.match(safeActivation, /tatwo_same_filesystem/);
assert.match(safeActivation, /bundle-archives\.noindex/);
assert.match(safeActivation, /\.bundle-archive/);
assert.match(safeActivation, /\.metadata_never_index/);
assert.doesNotMatch(safeActivation, /archive_root="\$app_dir\/\.tatwo-archives"/);
assert.match(
  chromiumBackend,
  /productionBundleIdentifier = "com\.tatwo\.ultrawork"/,
  "CEF production authorization must match TATWO_MAIN_APP_BUNDLE_ID",
);

for (const stagingOnly of [localRunner, legacyInstaller]) {
  assert.match(stagingOnly, /Tatwo Ultrawork Staging/);
  assert.match(stagingOnly, /com\.tatwo\.ultrawork\.staging/);
  assert.match(stagingOnly, /TATWO_ULTRAWORK_STAGING_ROOT/);
  assert.doesNotMatch(stagingOnly, /BUNDLE_ID="com\.tatwo\.ultrawork"/);
  assert.doesNotMatch(stagingOnly, /\$HOME\/Library\/Application Support\/Tatwo Ultrawork/);
  assert.doesNotMatch(stagingOnly, /\$HOME\/\.codex/);
}
assert.doesNotMatch(localRunner, /pkill -x "\$PRODUCT_NAME"/);
assert.doesNotMatch(legacyInstaller, /\$HOME\/\.local\/bin/);

assert.equal(
  moduleManifest.locations.install.path,
  "${TATWO_APP_DIR}/Tatwo Ultrawork.app",
);
assert.equal(
  moduleManifest.locations.data.path,
  "${TATWO_APP_SUPPORT_DIR}",
);
