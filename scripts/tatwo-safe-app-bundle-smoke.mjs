#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helperPath = path.join(repoRoot, "scripts", "tatwo-safe-app-bundle.sh");
const smokeRoot =
  process.env.TATWO_SAFE_BUNDLE_SMOKE_ROOT ??
  path.join(process.env.HOME || "", "Library/Application Support/tatwo2/sandboxes/tatwo-safe-app-bundle-smoke-20260719");
const runID = `run-${new Date().toISOString().replaceAll(":", "-")}-${process.pid}`;
const runRoot = path.join(smokeRoot, runID);

fs.mkdirSync(smokeRoot, { recursive: true });
fs.mkdirSync(runRoot, { recursive: false });

function writeBundle(bundlePath, marker) {
  const executable = path.join(bundlePath, "Contents", "MacOS", "TatwoUltraworkMac");
  const resources = path.join(
    bundlePath,
    "Contents",
    "Resources",
    "TatwoUltraworkMac_TatwoUltraworkMac.bundle"
  );
  fs.mkdirSync(path.dirname(executable), { recursive: true });
  fs.mkdirSync(resources, { recursive: true });
  fs.writeFileSync(executable, `#!/usr/bin/env bash\nprintf '%s\\n' ${JSON.stringify(marker)}\n`);
  fs.chmodSync(executable, 0o755);
  fs.writeFileSync(
    path.join(bundlePath, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>TatwoUltraworkMac</string>
  <key>CFBundleIdentifier</key>
  <string>com.tatwo.ultrawork.smoke</string>
  <key>CFBundleName</key>
  <string>TatwoUltraworkMac</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.0-smoke</string>
</dict>
</plist>
`
  );
  fs.writeFileSync(path.join(resources, "marker.txt"), `${marker}\n`);
  execFileSync(
    "/usr/bin/codesign",
    ["--force", "--deep", "--sign", "-", bundlePath],
    { stdio: "pipe" },
  );
}

function readOnlyReceipt(caseRoot) {
  const receiptDir = path.join(caseRoot, "state", "deployment-receipts");
  const receipts = fs.readdirSync(receiptDir).filter((name) => name.endsWith(".json"));
  assert.equal(receipts.length, 1, `expected one receipt in ${receiptDir}`);
  return JSON.parse(fs.readFileSync(path.join(receiptDir, receipts[0]), "utf8"));
}

function runSuccessCase() {
  const caseRoot = path.join(runRoot, "successful-activation-hidden-rollback");
  const appsRoot = path.join(caseRoot, "Applications");
  const activeBundle = path.join(appsRoot, "TatwoUltraworkMac.app");
  const stagedBundle = path.join(caseRoot, "stage", "TatwoUltraworkMac.app");
  const stateDir = path.join(caseRoot, "state");
  fs.mkdirSync(appsRoot, { recursive: true });
  writeBundle(activeBundle, "previous");
  writeBundle(stagedBundle, "candidate");

  const shell = `
set -u
source "$HELPER_PATH"
tatwo_refresh_launchservices() { :; }
tatwo_activate_staged_app_bundle \
  "$STAGED_BUNDLE" \
  "$ACTIVE_BUNDLE" \
  "$STATE_DIR" \
  "TatwoUltraworkMac" \
  "TatwoUltraworkMac_*.bundle"
`;

  execFileSync("/bin/bash", ["-c", shell], {
    env: {
      ...process.env,
      HELPER_PATH: helperPath,
      STAGED_BUNDLE: stagedBundle,
      ACTIVE_BUNDLE: activeBundle,
      STATE_DIR: stateDir,
    },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  const receipt = readOnlyReceipt(caseRoot);
  assert.equal(receipt.outcome, "passed");
  assert.match(receipt.archivedBundle, /bundle-archives\.noindex/);
  assert.match(receipt.archivedBundle, /\.bundle-archive$/);
  assert.doesNotMatch(receipt.archivedBundle, /\.app$/);
  assert.equal(fs.existsSync(receipt.archivedBundle), true);
  assert.equal(
    fs.existsSync(path.join(stateDir, "bundle-archives.noindex", ".metadata_never_index")),
    true,
  );
  assert.equal(
    fs.readFileSync(
      path.join(
        activeBundle,
        "Contents",
        "Resources",
        "TatwoUltraworkMac_TatwoUltraworkMac.bundle",
        "marker.txt",
      ),
      "utf8",
    ).trim(),
    "candidate",
  );

  return {
    case: "successful-activation-hidden-rollback",
    exitCode: 0,
    receipt,
  };
}

function runHealthFailureCase(name, { hasPrevious, failRestore }) {
  const caseRoot = path.join(runRoot, name);
  const appsRoot = path.join(caseRoot, "Applications");
  const activeBundle = path.join(appsRoot, "TatwoUltraworkMac.app");
  const stagedBundle = path.join(caseRoot, "stage", "TatwoUltraworkMac.app");
  const stateDir = path.join(caseRoot, "state");
  fs.mkdirSync(appsRoot, { recursive: true });
  if (hasPrevious) {
    writeBundle(activeBundle, "previous");
  }
  writeBundle(stagedBundle, "candidate");

  const restoreFailureFunction = failRestore
    ? `
mv() {
  if [[ "$1" == *"-previous-"* && "$2" == "$ACTIVE_BUNDLE" ]]; then
    return 73
  fi
  command mv "$@"
}
`
    : "";

  const shell = `
set -u
source "$HELPER_PATH"
verify_calls=0
tatwo_verify_staged_app_bundle() {
  verify_calls=$((verify_calls + 1))
  [[ "$verify_calls" -eq 1 ]]
}
${restoreFailureFunction}
tatwo_activate_staged_app_bundle \
  "$STAGED_BUNDLE" \
  "$ACTIVE_BUNDLE" \
  "$STATE_DIR" \
  "TatwoUltraworkMac" \
  "TatwoUltraworkMac_*.bundle"
`;

  let exitCode = 0;
  try {
    execFileSync("/bin/bash", ["-c", shell], {
      env: {
        ...process.env,
        HELPER_PATH: helperPath,
        STAGED_BUNDLE: stagedBundle,
        ACTIVE_BUNDLE: activeBundle,
        STATE_DIR: stateDir,
      },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    exitCode = error.status ?? 1;
  }
  assert.notEqual(exitCode, 0, `${name} must fail closed after injected health failure`);

  const receipt = readOnlyReceipt(caseRoot);
  assert.equal(receipt.schema, "TatwoSafeAppInstallReceiptV1");
  assert.equal(receipt.outcome, "failed");
  assert.equal(receipt.userDataWriteCount, 0);
  assert.equal(receipt.domainLedgerWriteCount, 0);

  if (hasPrevious && !failRestore) {
    assert.equal(receipt.rollbackPerformed, true);
    assert.match(receipt.detail, /previous verified bundle restored/);
    assert.equal(
      fs.readFileSync(
        path.join(
          activeBundle,
          "Contents",
          "Resources",
          "TatwoUltraworkMac_TatwoUltraworkMac.bundle",
          "marker.txt"
        ),
        "utf8"
      ).trim(),
      "previous"
    );
  } else if (!hasPrevious) {
    assert.equal(receipt.rollbackPerformed, false);
    assert.match(receipt.detail, /no previous bundle was available to restore/);
    assert.doesNotMatch(receipt.detail, /restored/);
    assert.equal(fs.existsSync(activeBundle), false);
  } else {
    assert.equal(receipt.rollbackPerformed, false);
    assert.match(receipt.detail, /previous bundle restoration failed/);
    assert.equal(fs.existsSync(activeBundle), false);
    assert.equal(
      fs.existsSync(receipt.archivedBundle),
      true,
      "failed restore must preserve the archived previous bundle"
    );
  }

  return {
    case: name,
    exitCode,
    receipt,
  };
}

const cases = [
  runSuccessCase(),
  runHealthFailureCase("previous-bundle-rollback-success", {
    hasPrevious: true,
    failRestore: false,
  }),
  runHealthFailureCase("no-previous-bundle-no-false-restore", {
    hasPrevious: false,
    failRestore: false,
  }),
  runHealthFailureCase("rollback-move-failure-reported", {
    hasPrevious: true,
    failRestore: true,
  }),
];

const summary = {
  schema: "TatwoSafeAppBundleSmokeReceiptV1",
  observedAt: new Date().toISOString(),
  ok: true,
  runRoot,
  mutationScope: "sandbox_bundle_only",
  productionAppWriteCount: 0,
  launchAgentWriteCount: 0,
  authMaterialReadCount: 0,
  cases,
};
const summaryPath = path.join(runRoot, "tatwo-safe-app-bundle-smoke.json");
fs.writeFileSync(summaryPath, `${JSON.stringify(summary, null, 2)}\n`, { flag: "wx" });
process.stdout.write(`${JSON.stringify({ ok: true, runRoot, summaryPath }, null, 2)}\n`);
