import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const localInstallerPath = path.join(
  root,
  "scripts",
  "tatwo-install-local-app.sh",
);
const provenanceToolPath = path.join(
  root,
  "scripts",
  "tatwo-local-provenance.mjs",
);

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    ...options,
  });
  assert.equal(
    result.status,
    0,
    `${command} ${args.join(" ")}\n${result.stdout}${result.stderr}`,
  );
  return result.stdout.trim();
}

function git(repo, ...args) {
  return run("git", args, { cwd: repo });
}

function createSnapshotRepo() {
  const repo = fs.mkdtempSync(
    path.join(os.tmpdir(), "tatwo-source-snapshot-contract-"),
  );
  fs.mkdirSync(path.join(repo, "Sources"), { recursive: true });
  fs.writeFileSync(
    path.join(repo, ".gitignore"),
    ".build/\nignored-output/\n",
  );
  fs.writeFileSync(path.join(repo, "Package.swift"), "// package\n");
  fs.writeFileSync(path.join(repo, "Sources", "App.swift"), "let value = 1\n");
  git(repo, "init", "-q");
  git(repo, "config", "user.name", "Tatwo Contract");
  git(repo, "config", "user.email", "contract@tatwo.invalid");
  git(repo, "add", ".");
  git(repo, "commit", "-qm", "base");
  return repo;
}

function captureSourceSnapshot(repo) {
  const shell = [
    `source ${JSON.stringify(localInstallerPath)}`,
    `ROOT_DIR=${JSON.stringify(repo)}`,
    "resolve_pinned_node_binary",
    "capture_source_snapshot",
    'printf "source_commit=%s\\nsource_tree=%s\\nsource_dirty=%s\\n" "$SOURCE_COMMIT" "$SOURCE_TREE" "$SOURCE_DIRTY"',
  ].join("\n");
  const result = spawnSync("/bin/bash", ["-c", shell], {
    cwd: repo,
    encoding: "utf8",
  });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 0, output);
  return Object.fromEntries(
    result.stdout
      .trim()
      .split("\n")
      .filter((line) => line.includes("="))
      .map((line) => line.split(/=(.*)/su).slice(0, 2)),
  );
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function runProvenance(args, options = {}) {
  const result = spawnSync(process.execPath, [provenanceToolPath, ...args], {
    encoding: "utf8",
    ...options,
  });
  assert.equal(
    result.status,
    0,
    `${result.stdout}${result.stderr}`,
  );
  return result;
}

test("local app installer builds, stages, ad-hoc signs, verifies, and atomically activates the canonical App", () => {
  const localInstaller = read("scripts/tatwo-install-local-app.sh");

  assert.notEqual(
    fs.statSync(localInstallerPath).mode & 0o111,
    0,
    "the direct installer entrypoint must be executable",
  );

  for (const required of [
    "scripts/tatwo-main-app-contract.sh",
    "scripts/tatwo-safe-app-bundle.sh",
    'APP_DIR="${TATWO_INSTALL_TARGET_DIR:-${TATWO_ULTRAWORK_APP_DIR:-/Applications}}"',
    'PRODUCT_NAME="TatwoUltraworkMac"',
    'CLI_PRODUCT="tatwo-ultrawork"',
    'RESOURCE_BUNDLE_GLOB="TatwoUltrawork_*.bundle"',
    'BUILD_JOBS="${TATWO_ULTRAWORK_BUILD_JOBS:-2}"',
    'PROVENANCE_ROOT="${TATWO_ULTRAWORK_PROVENANCE_ROOT:-${TATWO_ULTRAWORK_BUILD_PATH:-$INSTALLER_STATE_DIR/candidate-runs}}"',
    'PROVENANCE_TOOL="$ROOT_DIR/scripts/tatwo-local-provenance.mjs"',
    'ANCHOR_HELPER_SOURCE_RELATIVE="Tools/TatwoPLGAnchorHelper/main.c"',
    "scripts/tatwo-stage-model-runtimes.sh",
    "scripts/tatwo-cef-bundle.sh",
    "tatwo_resolve_model_runtimes",
    "stage_model_runtimes",
    "TatwoSubscriptionRuntimeVersion",
    "TatwoClaudeSubscriptionRuntimeVersion",
    "TatwoGrokVendorRuntimeVersion",
    "resolve_pinned_node_binary",
    "verify_pinned_node_binary_unchanged",
    "run_pinned_node",
    "TatwoProvenanceNodeSHA256",
    "TatwoProvenanceNodeCDHash",
    "TatwoProvenanceNodeVersion",
    'TATWO_MAIN_APP_BUNDLE_ID',
    "CFBundleIdentifier",
    "CFBundleName",
    "CFBundleExecutable",
    "CFBundleShortVersionString",
    "CFBundlePackageType",
    "LSMinimumSystemVersion",
    "TatwoSourceDirty",
    "TatwoSourceSnapshotSHA256",
    "TatwoSourceTreeManifestSHA256",
    "TatwoBuildInputManifestSHA256",
    "TatwoBuildOutputManifestSHA256",
    "TatwoBundleContentManifestSHA256",
    "TatwoMainExecutableSHA256",
    "TatwoCandidateID",
    "TatwoBrowserEngine",
    "chromium-cef",
    "TatwoCEFApplication",
    "TatwoCEFHelper",
    "tatwo_cef_stage_app_artifacts",
    "tatwo_cef_sign_nested_artifacts",
    "verify_cef_app_artifacts",
    'plutil -replace TatwoSourceDirty -bool "$SOURCE_DIRTY"',
    "source_dirty=${SOURCE_DIRTY:-}",
    'say "source_dirty=$SOURCE_DIRTY"',
    'run_pinned_node "$PROVENANCE_TOOL" source-snapshot',
    'run_pinned_node "$PROVENANCE_TOOL" extract-source',
    '--package-path "$SOURCE_WORKSPACE"',
    'capture_build_output_manifest',
    'embed_authority_provenance_inputs',
    'capture_bundle_content_manifest',
    'verify_bundle_content_manifest_unchanged "post_sign"',
    'capture_staged_bundle_identity',
    'verify_staged_bundle_unchanged "pre_activation"',
    "verify_installed_readback",
    'CANDIDATE_LIFECYCLE_STATE="uninitialized"',
    "candidate_context_is_complete",
    "mark_staged_candidate_verified",
    "require_verified_staged_candidate_context",
    "write_staged_candidate_receipt",
    "invalidate_install_receipt_pointer",
    'TATWO_INSTALL_STAGE_ONLY',
    'verify_source_snapshot_unchanged "build"',
    'verify_source_snapshot_unchanged "staging"',
    '--native-source "$ANCHOR_HELPER_SOURCE_RELATIVE"',
    'run_in_build_environment /usr/bin/xcrun --sdk macosx clang',
    'run_in_build_environment /usr/bin/xcrun --sdk macosx strip',
    'local PLG anchor helper source must be a regular non-symlink file',
    "tatwo_embed_sparkle_framework",
    "codesign -s - --deep --force",
    'codesign -s - --force --timestamp=none "$STAGED_BUNDLE"',
    "tatwo_verify_staged_app_bundle",
    "tatwo_activate_staged_app_bundle",
    "TATWO_ULTRAWORK_ARCHIVE_ROOT",
    "bundle_content_manifest_sha256=${BUNDLE_CONTENT_MANIFEST_SHA256:-}",
    "main_executable_sha256=${MAIN_EXECUTABLE_SHA256:-}",
    "embedded_provenance_sha256=${EMBEDDED_PROVENANCE_SHA256:-}",
    "schema=TatwoLocalAppInstallReceiptV3",
    "forensic_staged_bundle_manifest_sha256=${STAGED_BUNDLE_MANIFEST_SHA256:-}",
    "forensic_staged_bundle_identity_sha256=${STAGED_BUNDLE_IDENTITY_SHA256:-}",
    "schema=TatwoLocalAppStagedCandidateReceiptV1",
    "artifact_class=staged-candidate",
    "promotion_contract=fresh-shell-fail-closed",
    "candidate_bundle=$STAGED_BUNDLE",
    "stage_only=1",
    "schema=TatwoLocalAppInstallReceiptPointerV1",
    "receipt_id=$INSTALL_RECEIPT_ID",
    "receipt_nonce=$INSTALL_RECEIPT_NONCE",
    "receipt_filename=$INSTALL_RECEIPT_FILENAME",
    "receipt_sha256=$receipt_sha256",
    "receipt_tx_selftest_fresh_shell_fail_closed=passed",
    "receipt_tx_selftest_artifact_classes=passed",
    "receipt_tx_selftest_incomplete_receipt_fail_closed=passed",
    "receipt_tx_selftest_prior_pointer_preserved=passed",
    "receipt_tx_selftest_stale_pointer_and_anchor_invalidated=passed",
  ]) {
    assert.match(localInstaller, new RegExp(required.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")));
  }

  const markVerifiedIndex = localInstaller.indexOf(
    "if ! mark_staged_candidate_verified; then",
  );
  const stageOnlyBranchIndex = localInstaller.indexOf(
    'if [[ "${TATWO_INSTALL_STAGE_ONLY:-}" == "1" ]]; then',
    markVerifiedIndex,
  );
  assert.notEqual(
    markVerifiedIndex,
    -1,
    "main must establish verified staged-Candidate state",
  );
  assert.notEqual(
    stageOnlyBranchIndex,
    -1,
    "main must retain an explicit stage-only/full-install branch",
  );
  assert.ok(
    markVerifiedIndex < stageOnlyBranchIndex,
    "main must classify the staged Candidate before either receipt path",
  );
  assert.match(
    localInstaller,
    /activate_staged_bundle\(\) \{[\s\S]*?require_verified_staged_candidate_context[\s\S]*?ensure_install_receipt_identity/u,
    "activation must fail closed before allocating an installed receipt identity",
  );
  assert.match(
    localInstaller,
    /write_install_receipt_pointer\(\) \{[\s\S]*?CANDIDATE_LIFECYCLE_STATE[\s\S]*?installed-app-readback-verified/u,
    "the installed pointer must require same-process installed readback",
  );

  assert.match(
    localInstaller,
    /swift build[\s\S]*--package-path "\$SOURCE_WORKSPACE"[\s\S]*--product "\$CLI_PRODUCT"[\s\S]*-c release/,
  );
  assert.match(localInstaller, /--jobs "\$BUILD_JOBS"/);
  assert.match(
    localInstaller,
    /run_pinned_node "\$PROVENANCE_TOOL" build-input-manifest/g,
  );
  assert.match(
    localInstaller,
    /run_pinned_node "\$PROVENANCE_TOOL" bundle-content-manifest[\s\S]*--main-executable "Contents\/MacOS\/\$PRODUCT_NAME"/u,
  );
  assert.match(
    localInstaller,
    /run_pinned_node "\$PROVENANCE_TOOL" verify-bundle-content-manifest/g,
  );
  assert.match(
    localInstaller,
    /"\$BUILD_OUTPUT_MANIFEST_SHA256"[\s\S]*"\$BUNDLE_CONTENT_MANIFEST_SHA256"[\s\S]*"\$MAIN_EXECUTABLE_SHA256"[\s\S]*"\$NODE_BINARY_SHA256"/u,
  );
  assert.match(
    localInstaller,
    /final_receipt="\$INSTALLER_STATE_DIR\/receipts\/\$INSTALL_RECEIPT_FILENAME"/u,
  );
  assert.match(
    localInstaller,
    /write_install_receipt_pointer "\$final_receipt" "\$receipt_pointer"/u,
  );
  assert.doesNotMatch(
    localInstaller,
    /^staged_bundle_(?:manifest|identity)_sha256=/mu,
    "V3 receipt fields must advertise their forensic-only role",
  );
  assert.doesNotMatch(localInstaller, /command -v node/u);
  assert.doesNotMatch(localInstaller, /^\s*(?:if ! )?node\b/mu);
  assert.doesNotMatch(localInstaller, /^\s*xcrun clang\b/mu);
  assert.doesNotMatch(localInstaller, /^\s*strip -S\b/mu);
  assert.match(
    localInstaller,
    /swift build[\s\S]*--product "\$PRODUCT_NAME"[\s\S]*-c release/,
  );
  assert.match(
    localInstaller,
    /STAGED_BUNDLE="\$STAGE_ROOT\/\$TATWO_MAIN_APP_BUNDLE_FILENAME"/,
  );
  assert.match(
    localInstaller,
    /find "\$BUILD_BIN_PATH" -maxdepth 1 -type d -name "\$RESOURCE_BUNDLE_GLOB"/,
  );
  assert.match(
    localInstaller,
    /install_app_local=not_activated_build_failed/,
  );

  for (const forbidden of [
    "TATWO_VERIFIED_PRODUCTION_APP_BUNDLE",
    "notarytool",
    "spctl --assess",
    "LaunchAgents",
    "launchctl",
  ]) {
    assert.doesNotMatch(localInstaller, new RegExp(forbidden.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")));
  }
});

test("formal local installer builds and verifies the same pinned CEF bundle contract as staging", () => {
  const localInstaller = read("scripts/tatwo-install-local-app.sh");
  const stagingBuilder = read("script/build_staging_app.sh");
  const cefBundle = read("scripts/tatwo-cef-bundle.sh");

  assert.match(
    localInstaller,
    /source "\$ROOT_DIR\/scripts\/tatwo-cef-bundle\.sh"/u,
  );
  assert.match(
    stagingBuilder,
    /source "\$ROOT_DIR\/scripts\/tatwo-cef-bundle\.sh"/u,
  );
  assert.match(localInstaller, /TATWO_ENABLE_CEF="\$\{TATWO_ENABLE_CEF:-0\}"/u);
  assert.match(localInstaller, /--product TatwoCEFHelper/u);
  assert.match(localInstaller, /"TatwoCEFHelper"/u);
  assert.match(localInstaller, /<key>TatwoBrowserEngine<\/key><string>chromium-cef<\/string>/u);
  assert.match(localInstaller, /<key>NSPrincipalClass<\/key><string>\$APP_PRINCIPAL_CLASS<\/string>/u);
  assert.match(localInstaller, /<key>TatwoCEFArchiveSHA256<\/key><string>\$CEF_ARCHIVE_SHA256<\/string>/u);
  assert.match(cefBundle, /tatwo_cef_stage_app_artifacts\(\)/u);
  assert.match(cefBundle, /tatwo_cef_sign_nested_artifacts\(\)/u);
  assert.match(cefBundle, /verify_cef_app_artifacts\(\)/u);

  const stageIndex = localInstaller.indexOf("|| ! stage_cef_artifacts");
  const manifestIndex = localInstaller.indexOf("|| ! capture_bundle_content_manifest");
  assert.ok(
    stageIndex >= 0 && manifestIndex > stageIndex,
    "CEF framework and helpers must be present before the bundle provenance manifest scans the Candidate",
  );
  const adHocNestedIndex = localInstaller.indexOf(
    'tatwo_cef_sign_nested_artifacts "$STAGED_BUNDLE" - adhoc',
  );
  const adHocAppIndex = localInstaller.indexOf(
    'codesign -s - --deep --force --timestamp=none "$STAGED_BUNDLE"',
  );
  assert.ok(
    adHocNestedIndex >= 0 && adHocAppIndex > adHocNestedIndex,
    "ad-hoc signing must sign the CEF framework/helpers before the whole App",
  );
  const verifyIndex = localInstaller.indexOf("verify_cef_app_artifacts");
  const stageOnlyIndex = localInstaller.indexOf(
    'if [[ "${TATWO_INSTALL_STAGE_ONLY:-}" == "1" ]]; then',
    localInstaller.indexOf("if ! mark_staged_candidate_verified; then"),
  );
  assert.ok(
    verifyIndex >= 0 && stageOnlyIndex > verifyIndex,
    "CEF artifacts must verify before the stage-only/full-install gate",
  );
});

test("install receipt pointer selects one exact nonce-bound V3 receipt without second-granularity matching", () => {
  const runSelftest = () => {
    const isolatedRoot = fs.mkdtempSync(
      path.join(os.tmpdir(), "tatwo-receipt-pointer-contract-"),
    );
    try {
      const result = spawnSync("/bin/bash", [localInstallerPath], {
        cwd: root,
        encoding: "utf8",
        env: {
          ...process.env,
          TATWO_FORCE_ADHOC: "1",
          TATWO_INSTALL_RECEIPT_TX_SELFTEST: "1",
          TATWO_ULTRAWORK_APP_DIR: path.join(isolatedRoot, "Applications"),
          TATWO_ULTRAWORK_LOCAL_APP_STATE_DIR: path.join(isolatedRoot, "state"),
        },
      });
      const output = `${result.stdout}${result.stderr}`;
      assert.equal(result.status, 0, output);
      assert.match(output, /^receipt_tx_selftest_exact_pointer=passed$/mu);
      assert.match(
        output,
        /^receipt_tx_selftest_fresh_shell_fail_closed=passed$/mu,
      );
      assert.match(
        output,
        /^receipt_tx_selftest_artifact_classes=passed$/mu,
      );
      assert.match(
        output,
        /^receipt_tx_selftest_incomplete_receipt_fail_closed=passed$/mu,
      );
      assert.match(
        output,
        /^receipt_tx_selftest_prior_pointer_preserved=passed$/mu,
      );
      assert.match(
        output,
        /^receipt_tx_selftest_stale_pointer_and_anchor_invalidated=passed$/mu,
      );
      for (const marker of [
        "receipt_tx_selftest_anchor_generation_chain=passed",
        "receipt_tx_selftest_anchor_injection_reason=passed",
        "receipt_tx_selftest_anchor_failure_atomic=passed",
        "receipt_tx_selftest_anchor_activation_rollback=passed",
        "receipt_tx_selftest_authority_metadata_restore=passed",
        "receipt_activation_transaction_selftest=passed",
      ]) {
        assert.match(
          output,
          new RegExp(`^${marker.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}$`, "mu"),
        );
      }
      assert.doesNotMatch(output, /^local_internal_device_identity=failed$/mu);
      assert.doesNotMatch(output, /FileNotFoundError/u);
      assert.match(
        output,
        /^activation=local_internal_anchor_commit_failed$/mu,
      );
      assert.match(
        output,
        /^install_app_local=rolled_back_after_local_internal_anchor_failure$/mu,
      );
      assert.doesNotMatch(
        output,
        /^install_app_local=anchor_commit_and_rollback_failed$/mu,
      );
      assert.match(
        output,
        /^install_receipt_filename=local-app-install-[0-9a-f]{64}\.txt$/mu,
      );
      const receiptID = /^install_receipt_id=([0-9a-f]{64})$/mu.exec(
        output,
      )?.[1];
      const receiptNonce = /^install_receipt_nonce=([0-9a-f]{64})$/mu.exec(
        output,
      )?.[1];
      assert.ok(receiptID, output);
      assert.ok(receiptNonce, output);
      assert.equal(
        receiptID,
        sha256(
          Buffer.from(
            `${"a".repeat(64)}\n${receiptNonce}\n`,
            "utf8",
          ),
        ),
        "receipt_id must be sha256(candidate_id + newline + nonce + newline)",
      );
      return receiptID;
    } finally {
      fs.rmSync(isolatedRoot, { recursive: true, force: true });
    }
  };

  const first = runSelftest();
  const second = runSelftest();
  assert.notEqual(
    first,
    second,
    "two receipts created in the same second must have distinct exact IDs",
  );
});

test("ambient PATH node shim cannot enter the provenance root of trust", () => {
  const isolatedRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "tatwo-pinned-node-contract-"),
  );
  try {
    const fakeBin = path.join(isolatedRoot, "ambient-bin");
    const marker = path.join(isolatedRoot, "ambient-node-ran");
    fs.mkdirSync(fakeBin);
    fs.writeFileSync(
      path.join(fakeBin, "node"),
      `#!/bin/sh\nprintf 'ambient\\n' > ${JSON.stringify(marker)}\nexit 0\n`,
      { mode: 0o755 },
    );
    const result = spawnSync("/bin/bash", [localInstallerPath], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${fakeBin}:${process.env.PATH}`,
        TATWO_FORCE_ADHOC: "1",
        TATWO_INSTALL_DRY_RUN: "1",
        TATWO_INSTALL_STAGE_ONLY: "1",
        TATWO_INSTALL_RECEIPT_TX_SELFTEST: "0",
        TATWO_ULTRAWORK_APP_DIR: path.join(isolatedRoot, "Applications"),
        TATWO_ULTRAWORK_LOCAL_APP_STATE_DIR: path.join(isolatedRoot, "state"),
        TATWO_ULTRAWORK_BUILD_PATH: path.join(isolatedRoot, "build"),
      },
    });
    const output = `${result.stdout}${result.stderr}`;
    assert.equal(result.status, 0, output);
    assert.match(
      output,
      /^provenance_node_binary=\/(?:opt\/homebrew|usr\/local)\/Cellar\/node\/[^/]+\/bin\/node$/mu,
    );
    assert.match(output, /^provenance_node_sha256=[0-9a-f]{64}$/mu);
    assert.match(output, /^provenance_node_cdhash=[0-9a-f]{40}$/mu);
    assert.equal(fs.existsSync(marker), false);
  } finally {
    fs.rmSync(isolatedRoot, { recursive: true, force: true });
  }
});

test("explicit Node override fails closed without executing it", () => {
  const isolatedRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "tatwo-untrusted-node-contract-"),
  );
  try {
    const fakeNode = path.join(isolatedRoot, "node");
    const marker = path.join(isolatedRoot, "untrusted-node-ran");
    fs.writeFileSync(
      fakeNode,
      `#!/bin/sh\nprintf 'untrusted\\n' > ${JSON.stringify(marker)}\nexit 0\n`,
      { mode: 0o755 },
    );
    const result = spawnSync("/bin/bash", [localInstallerPath], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        TATWO_FORCE_ADHOC: "1",
        TATWO_INSTALL_DRY_RUN: "1",
        TATWO_INSTALL_RECEIPT_TX_SELFTEST: "0",
        TATWO_ULTRAWORK_APP_DIR: path.join(isolatedRoot, "Applications"),
        TATWO_ULTRAWORK_LOCAL_APP_STATE_DIR: path.join(isolatedRoot, "state"),
        TATWO_ULTRAWORK_BUILD_PATH: path.join(isolatedRoot, "build"),
        TATWO_ULTRAWORK_NODE_BINARY: fakeNode,
      },
    });
    const output = `${result.stdout}${result.stderr}`;
    assert.notEqual(result.status, 0, output);
    assert.match(output, /^provenance_node_resolution=override_forbidden$/mu);
    assert.match(
      output,
      /^install_app_local=not_activated_preflight_failed$/mu,
    );
    assert.equal(fs.existsSync(marker), false);
  } finally {
    fs.rmSync(isolatedRoot, { recursive: true, force: true });
  }
});

test("sanitized build environment rejects ambient PATH toolchain shims", () => {
  const isolatedRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "tatwo-sanitized-build-env-contract-"),
  );
  try {
    const fakeBin = path.join(isolatedRoot, "ambient-bin");
    const marker = path.join(isolatedRoot, "ambient-xcrun-ran");
    fs.mkdirSync(fakeBin);
    fs.writeFileSync(
      path.join(fakeBin, "xcrun"),
      `#!/bin/sh\nprintf 'ambient\\n' > ${JSON.stringify(marker)}\nexit 97\n`,
      { mode: 0o755 },
    );
    const shell = [
      `source ${JSON.stringify(localInstallerPath)}`,
      `RUN_ROOT=${JSON.stringify(path.join(isolatedRoot, "run"))}`,
      `BUILD_HOME=${JSON.stringify(path.join(isolatedRoot, "home"))}`,
      `BUILD_TMPDIR=${JSON.stringify(path.join(isolatedRoot, "tmp"))}`,
      'BUILD_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"',
      'BUILD_SDKROOT="$(DEVELOPER_DIR="$BUILD_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-path)"',
      'mkdir -p "$RUN_ROOT" "$BUILD_HOME" "$BUILD_TMPDIR"',
      `PATH=${JSON.stringify(`${fakeBin}:${process.env.PATH}`)}`,
      "export PATH",
      "run_in_build_environment /bin/sh -c 'printf \"sanitized_path=%s\\nxcrun=%s\\n\" \"$PATH\" \"$(command -v xcrun)\"'",
    ].join("\n");
    const result = spawnSync("/bin/bash", ["-c", shell], {
      cwd: root,
      encoding: "utf8",
    });
    const output = `${result.stdout}${result.stderr}`;
    assert.equal(result.status, 0, output);
    assert.match(
      output,
      /^sanitized_path=\/usr\/bin:\/bin:\/usr\/sbin:\/sbin$/mu,
    );
    assert.match(output, /^xcrun=\/usr\/bin\/xcrun$/mu);
    assert.equal(fs.existsSync(marker), false);
  } finally {
    fs.rmSync(isolatedRoot, { recursive: true, force: true });
  }
});

test("forced ad-hoc dry-run cannot select or execute the Developer ID signing path", () => {
  const isolatedRoot = path.join(
    os.tmpdir(),
    `tatwo-local-app-install-contract-${process.pid}`,
  );
  const result = spawnSync("/bin/bash", [localInstallerPath], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      TATWO_FORCE_ADHOC: "1",
      TATWO_INSTALL_DRY_RUN: "1",
      TATWO_INSTALL_STAGE_ONLY: "1",
      TATWO_INSTALL_RECEIPT_TX_SELFTEST: "0",
      TATWO_ULTRAWORK_APP_DIR: path.join(isolatedRoot, "Applications"),
      TATWO_ULTRAWORK_LOCAL_APP_STATE_DIR: path.join(isolatedRoot, "state"),
      TATWO_ULTRAWORK_BUILD_PATH: path.join(isolatedRoot, "build"),
    },
  });
  const output = `${result.stdout}${result.stderr}`;

  assert.equal(result.status, 0, output);
  // Protection intent: on a Mac without a certificate (forced here), the
  // installer must never accidentally enter the formal signing path.
  assert.match(output, /^signing=ad-hoc$/mu);
  assert.match(output, /^signing_force_adhoc=1$/mu);
  assert.match(output, /^plan_touch_applications=no$/mu);
  assert.match(output, /^plan_sign=codesign -s - /mu);
  assert.match(output, /^install_app_local=dry_run_plan_only$/mu);
  assert.doesNotMatch(output, /^signing=developer-id /mu);
  assert.doesNotMatch(output, /^signing=apple-development /mu);
  assert.doesNotMatch(output, /^developer_id_sign=/mu);
  assert.doesNotMatch(output, /^apple_development_sign=/mu);
  assert.doesNotMatch(output, /--options runtime/mu);
  assert.doesNotMatch(output, /^plan_sparkle_sign=.* secure$/mu);
  assert.doesNotMatch(
    output,
    /^plan_(?:helper_)?sign=.*--sign "Developer ID Application:/mu,
  );
});

test("dirty provenance uses an isolated index, includes untracked source, and excludes ignored output", () => {
  const repo = createSnapshotRepo();
  try {
    const indexPath = path.join(repo, ".git", "index");
    const indexBefore = fs.readFileSync(indexPath);
    const indexHashBefore = sha256(indexBefore);
    const headTree = git(repo, "rev-parse", "HEAD^{tree}");

    fs.writeFileSync(
      path.join(repo, "Sources", "App.swift"),
      "let value = 2\n",
    );
    fs.writeFileSync(
      path.join(repo, "Sources", "NewFeature.swift"),
      "let newFeature = true\n",
    );
    fs.mkdirSync(path.join(repo, ".build", "out"), { recursive: true });
    fs.writeFileSync(
      path.join(repo, ".build", "out", "generated.o"),
      "ignored build output\n",
    );
    fs.mkdirSync(path.join(repo, "ignored-output"), { recursive: true });
    fs.writeFileSync(
      path.join(repo, "ignored-output", "runtime.log"),
      "ignored runtime output\n",
    );

    const dirtySnapshot = captureSourceSnapshot(repo);
    assert.equal(dirtySnapshot.source_commit, git(repo, "rev-parse", "HEAD"));
    assert.equal(dirtySnapshot.source_dirty, "true");
    assert.notEqual(dirtySnapshot.source_tree, headTree);

    fs.rmSync(path.join(repo, ".build"), { recursive: true });
    fs.rmSync(path.join(repo, "ignored-output"), { recursive: true });
    const withoutIgnoredOutput = captureSourceSnapshot(repo);
    assert.equal(
      withoutIgnoredOutput.source_tree,
      dirtySnapshot.source_tree,
      "Git-ignored build/runtime output must not affect source provenance",
    );

    fs.rmSync(path.join(repo, "Sources", "NewFeature.swift"));
    const withoutUntrackedSource = captureSourceSnapshot(repo);
    assert.notEqual(
      withoutUntrackedSource.source_tree,
      dirtySnapshot.source_tree,
      "non-ignored untracked source must be present in the snapshot tree",
    );

    const indexAfter = fs.readFileSync(indexPath);
    assert.deepEqual(indexAfter, indexBefore);
    assert.equal(sha256(indexAfter), indexHashBefore);
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});

test("installer fails closed when source changes during the build phase", () => {
  const repo = createSnapshotRepo();
  try {
    const shell = [
      `source ${JSON.stringify(localInstallerPath)}`,
      `ROOT_DIR=${JSON.stringify(repo)}`,
      "resolve_pinned_node_binary",
      "capture_source_snapshot",
      'printf "let drift = true\\n" >> "$ROOT_DIR/Sources/App.swift"',
      'if verify_source_snapshot_unchanged "build"; then',
      '  printf "unexpected_source_drift_pass\\n"',
      "  exit 0",
      "fi",
      "exit 7",
    ].join("\n");
    const result = spawnSync("/bin/bash", ["-c", shell], {
      cwd: repo,
      encoding: "utf8",
      env: {
        ...process.env,
        TATWO_PROVENANCE_TMPDIR: "/tmp/tatwo2-fixture/runtime/test-tmp/provenance-tests",
      },
    });
    const output = `${result.stdout}${result.stderr}`;

    assert.notEqual(result.status, 0, output);
    assert.match(output, /^source_snapshot_capture=passed$/mu);
    assert.match(output, /^source_snapshot_build=changed$/mu);
    assert.equal(result.status, 7, output);
    assert.doesNotMatch(output, /^unexpected_source_drift_pass$/mu);
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});

test("verify_installed_readback rejects installed embedded provenance tamper", () => {
  const isolatedRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "tatwo-installed-readback-contract-"),
  );
  try {
    const stagedBundle = path.join(
      isolatedRoot,
      "staged",
      "Tatwo Ultrawork.app",
    );
    const installedBundle = path.join(
      isolatedRoot,
      "installed",
      "Tatwo Ultrawork.app",
    );
    const stagedMain = path.join(
      stagedBundle,
      "Contents",
      "MacOS",
      "TatwoUltraworkMac",
    );
    const stagedResources = path.join(
      stagedBundle,
      "Contents",
      "Resources",
    );
    fs.mkdirSync(path.dirname(stagedMain), { recursive: true });
    fs.mkdirSync(stagedResources, { recursive: true });
    fs.copyFileSync("/bin/echo", stagedMain);
    fs.chmodSync(stagedMain, 0o755);
    fs.writeFileSync(
      path.join(stagedBundle, "Contents", "Info.plist"),
      "<plist><dict><key>CFBundleExecutable</key><string>TatwoUltraworkMac</string></dict></plist>\n",
    );
    fs.writeFileSync(
      path.join(stagedResources, "TatwoCandidateProvenance.json"),
      '{"schema":"TatwoCandidateEmbeddedProvenanceV1"}\n',
    );
    const embeddedManifest = path.join(
      stagedResources,
      "TatwoBundleContentManifestV1.json",
    );
    runProvenance([
      "bundle-content-manifest",
      "--bundle", stagedBundle,
      "--main-executable", "Contents/MacOS/TatwoUltraworkMac",
      "--output", embeddedManifest,
    ], {
      env: {
        ...process.env,
        TATWO_PROVENANCE_TMPDIR: isolatedRoot,
      },
    });
    const stagedManifest = path.join(
      isolatedRoot,
      "staged-bundle-manifest.json",
    );
    runProvenance([
      "fs-manifest",
      "--root", stagedBundle,
      "--path", ".",
      "--output", stagedManifest,
    ], {
      env: {
        ...process.env,
        TATWO_PROVENANCE_TMPDIR: isolatedRoot,
      },
    });
    fs.mkdirSync(path.dirname(installedBundle), { recursive: true });
    fs.cpSync(stagedBundle, installedBundle, {
      recursive: true,
      verbatimSymlinks: true,
    });
    fs.appendFileSync(
      path.join(
        installedBundle,
        "Contents",
        "Resources",
        "TatwoCandidateProvenance.json",
      ),
      "tamper\n",
    );

    const provenanceDir = path.join(isolatedRoot, "readback");
    const stagedIdentity = path.join(isolatedRoot, "staged-identity.json");
    fs.mkdirSync(provenanceDir, { recursive: true });
    fs.writeFileSync(stagedIdentity, "{}\n");
    const shell = [
      `source ${JSON.stringify(localInstallerPath)}`,
      `PROVENANCE_DIR=${JSON.stringify(provenanceDir)}`,
      `APP_BUNDLE=${JSON.stringify(installedBundle)}`,
      `STAGED_BUNDLE_MANIFEST_PATH=${JSON.stringify(stagedManifest)}`,
      `STAGED_BUNDLE_IDENTITY_PATH=${JSON.stringify(stagedIdentity)}`,
      `STAGED_BUNDLE_IDENTITY_SHA256=${JSON.stringify(
        sha256(fs.readFileSync(stagedIdentity)),
      )}`,
      "resolve_pinned_node_binary",
      "if verify_installed_readback; then",
      '  printf "unexpected_installed_readback_pass\\n"',
      "  exit 0",
      "fi",
      "exit 23",
    ].join("\n");
    const result = spawnSync("/bin/bash", ["-c", shell], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        TATWO_PROVENANCE_TMPDIR: isolatedRoot,
      },
    });
    const output = `${result.stdout}${result.stderr}`;

    assert.equal(result.status, 23, output);
    assert.match(
      output,
      /installed bundle manifest is not an exact staged Candidate readback/u,
    );
    assert.match(output, /^installed_readback=mismatch_manifest$/mu);
    assert.doesNotMatch(output, /^installed_readback=passed$/mu);
    assert.doesNotMatch(output, /^unexpected_installed_readback_pass$/mu);
  } finally {
    fs.rmSync(isolatedRoot, { recursive: true, force: true });
  }
});

test("dry-run signing selection prefers Developer ID over Apple Development", () => {
  const isolatedRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "tatwo-signing-priority-contract-"),
  );
  try {
    const result = spawnSync("/bin/bash", [localInstallerPath], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        TATWO_INSTALL_DRY_RUN: "1",
        TATWO_INSTALL_STAGE_ONLY: "1",
        TATWO_INSTALL_RECEIPT_TX_SELFTEST: "0",
        TATWO_INSTALL_TEST_CODESIGN_IDENTITIES: [
          '1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Local Test (TEAMLOCAL1)"',
          '2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Release Test (TEAMRELEAS)"',
          "2 valid identities found",
        ].join("\n"),
        TATWO_ULTRAWORK_APP_DIR: path.join(isolatedRoot, "Applications"),
        TATWO_ULTRAWORK_LOCAL_APP_STATE_DIR: path.join(isolatedRoot, "state"),
        TATWO_ULTRAWORK_BUILD_PATH: path.join(isolatedRoot, "build"),
      },
    });
    const output = `${result.stdout}${result.stderr}`;

    assert.equal(result.status, 0, output);
    assert.match(output, /^signing_identity_source=test-fixture$/mu);
    assert.match(
      output,
      /^signing=developer-id Developer ID Application: Release Test \(TEAMRELEAS\)$/mu,
    );
    assert.match(output, /^install_mode=local_developer_id$/mu);
    assert.match(output, /^plan_sign=.*--options runtime --timestamp/mu);
    assert.match(output, /^plan_sparkle_sign=.* secure$/mu);
    assert.doesNotMatch(output, /^signing=apple-development /mu);
  } finally {
    fs.rmSync(isolatedRoot, { recursive: true, force: true });
  }
});

test("dry-run signing selection falls back to stable Apple Development without hardened runtime", () => {
  const isolatedRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), "tatwo-signing-local-development-contract-"),
  );
  try {
    const result = spawnSync("/bin/bash", [localInstallerPath], {
      cwd: root,
      encoding: "utf8",
      env: {
        ...process.env,
        TATWO_INSTALL_DRY_RUN: "1",
        TATWO_INSTALL_STAGE_ONLY: "1",
        TATWO_INSTALL_RECEIPT_TX_SELFTEST: "0",
        TATWO_INSTALL_TEST_CODESIGN_IDENTITIES:
          '1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Local Test (TEAMLOCAL1)"',
        TATWO_ULTRAWORK_APP_DIR: path.join(isolatedRoot, "Applications"),
        TATWO_ULTRAWORK_LOCAL_APP_STATE_DIR: path.join(isolatedRoot, "state"),
        TATWO_ULTRAWORK_BUILD_PATH: path.join(isolatedRoot, "build"),
      },
    });
    const output = `${result.stdout}${result.stderr}`;

    assert.equal(result.status, 0, output);
    assert.match(
      output,
      /^signing=apple-development Apple Development: Local Test \(TEAMLOCAL1\)$/mu,
    );
    assert.match(output, /^signing_stability=fixed-local-identity$/mu);
    assert.match(
      output,
      /^tcc_reauthorization=one-time-migration-if-previously-adhoc$/mu,
    );
    assert.match(output, /^install_mode=local_apple_development$/mu);
    assert.match(
      output,
      /^plan_sign=codesign --force --timestamp=none --sign /mu,
    );
    assert.match(
      output,
      /^plan_sparkle_sign=tatwo_codesign_embedded_sparkle local-development$/mu,
    );
    assert.match(output, /^plan_hardened_runtime=disabled-local-development$/mu);
    assert.match(output, /^plan_tcc_identity=fixed-apple-development$/mu);
    assert.doesNotMatch(output, /--options runtime/mu);
    assert.doesNotMatch(output, /^signing=ad-hoc$/mu);
  } finally {
    fs.rmSync(isolatedRoot, { recursive: true, force: true });
  }
});

test("production installer keeps its production gate and exposes a separate local-App mode", () => {
  const installer = read("scripts/install-tatwo-ultrawork.sh");

  assert.match(installer, /TATWO_VERIFIED_PRODUCTION_APP_BUNDLE/);
  assert.match(installer, /TATWO_VERIFIED_SIGNED_RELEASE_MANIFEST/);
  assert.match(installer, /TATWO_VERIFIED_SIGNED_RELEASE_MANIFEST_SIGNATURE/);
  assert.match(installer, /TATWO_VERIFIED_SIGNED_RELEASE_RECEIPT/);
  assert.match(installer, /TATWO_VERIFIED_SIGNED_RELEASE_APPCAST/);
  assert.match(installer, /production-release-promotion-v1/);
  assert.match(installer, /Authority=Developer ID Application:/);
  assert.match(installer, /--install-app-local\|install-app-local/);
  assert.match(
    installer,
    /scripts\/tatwo-install-local-app\.sh/,
  );
});
