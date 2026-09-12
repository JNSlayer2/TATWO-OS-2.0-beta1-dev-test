import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scriptPath = path.join(repoRoot, "script", "build_staging_app.sh");
const cefBundleScriptPath = path.join(repoRoot, "scripts", "tatwo-cef-bundle.sh");
// Fixtures live under the OS runtime scratch and are removed on exit; they
// used to accumulate 2 GB per run under staging/test-fixtures.
const fixtureBase = "/tmp/tatwo2-fixture/runtime/test-tmp/staging-reuse";
const createdFixtureRoots = [];
process.on("exit", () => {
  for (const root of createdFixtureRoots) {
    try { rmSync(root, { recursive: true, force: true }); } catch {}
  }
});

function run(command, args, options = {}) {
  return spawnSync(command, args, { cwd: repoRoot, encoding: "utf8", ...options });
}

function signingIdentity() {
  const result = run("security", ["find-identity", "-v", "-p", "codesigning"]);
  assert.equal(result.status, 0, result.stderr);
  const identities = [...result.stdout.matchAll(/^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"]+)"/gm)];
  const selected = identities.find((match) => match[2].startsWith("Apple Development:")) ?? identities[0];
  assert.ok(selected, "a fixed code-signing identity is required for fixture coverage");
  return { sha1: selected[1], name: selected[2] };
}

function xml(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function createFixture({
  adHoc = false,
  staleChatWorkdir = false,
  browserEngine = "webkit-legacy",
  omitBrowserEnginePin = false,
  omitGrokVendorVersionPin = false,
} = {}) {
  mkdirSync(fixtureBase, { recursive: true });
  const root = path.join(fixtureBase, `tatwo-staging-reuse-${Date.now()}-${randomUUID()}`);
  createdFixtureRoots.push(root);
  const app = path.join(root, "Tatwo Ultrawork Staging.app");
  const contents = path.join(app, "Contents");
  const macos = path.join(contents, "MacOS");
  const helpers = path.join(contents, "Helpers");
  const runtime = path.join(root, "runtime");
  const home = path.join(runtime, "home");
  const tmp = path.join(runtime, "tmp");
  const appSupport = path.join(runtime, "app-support");
  const state = path.join(runtime, "state");
  const codexHome = path.join(runtime, "codex-home");
  const anchorFile = path.join(runtime, "plg-anchor-identity-v1.json");
  const identity = signingIdentity();
  const bundleID = `com.tatwo.ultrawork.staging.fixture.${randomUUID().replaceAll("-", "")}`;
  const anchorService = `ai.tatwo.fixture.${randomUUID()}`;
  const anchorAccount = "staging.fixture";
  const gatewayPort = 46000 + Math.floor(Math.random() * 500);
  const appMCPPort = gatewayPort + 500;
  const chatWorkdir = staleChatWorkdir
    ? path.join(root, "stale-worktree")
    : repoRoot;
  for (const directory of [macos, helpers, home, tmp, appSupport, state, codexHome, chatWorkdir]) mkdirSync(directory, { recursive: true });
  const executable = path.join(macos, "TatwoUltraworkMacStaging");
  writeFileSync(executable, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const grokExecutionMarker = path.join(runtime, "forbidden-grok-execution.marker");
  const grokVendorRuntime = path.join(helpers, "TatwoGrokVendorRuntime");
  const grokSubscriptionRuntime = path.join(helpers, "TatwoGrokSubscriptionRuntime");
  const grokVendorRuntimeVersion = "grok fixture version (must never execute)";
  const grokSubscriptionRuntimeVersion = `tatwo-grok-subscription-v1 (${grokVendorRuntimeVersion})`;
  const trapRuntime = `#!/bin/sh
printf 'forbidden\\n' >${JSON.stringify(grokExecutionMarker)}
exit 97
`;
  writeFileSync(grokVendorRuntime, trapRuntime, { mode: 0o755 });
  writeFileSync(grokSubscriptionRuntime, trapRuntime, { mode: 0o755 });
  const grokVendorRuntimeSHA256 = createHash("sha256")
    .update(readFileSync(grokVendorRuntime))
    .digest("hex");
  const grokSubscriptionRuntimeSHA256 = createHash("sha256")
    .update(readFileSync(grokSubscriptionRuntime))
    .digest("hex");
  writeFileSync(anchorFile, `${JSON.stringify({ schema: "TatwoStagingPLGAnchorIdentityV1", service: anchorService, account: anchorAccount })}\n`);
  writeFileSync(path.join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TatwoUltraworkMacStaging</string>
<key>CFBundleIdentifier</key><string>${bundleID}</string>
<key>CFBundleShortVersionString</key><string>0.1.1-staging</string>
<key>CFBundleVersion</key><string>202608290001</string>
<key>TatwoStagingDeclaredBundlePath</key><string>${xml(app)}</string>
	<key>TatwoStagingAnchorIdentity</key><string>${anchorService}|${anchorAccount}</string>
	${omitBrowserEnginePin ? "" : `<key>TatwoBrowserEngine</key><string>${browserEngine}</string>`}
	<key>TatwoGrokSubscriptionRuntimeVersion</key><string>${xml(grokSubscriptionRuntimeVersion)}</string>
	<key>TatwoGrokSubscriptionRuntimeSHA256</key><string>${grokSubscriptionRuntimeSHA256}</string>
	${omitGrokVendorVersionPin ? "" : `<key>TatwoGrokVendorRuntimeVersion</key><string>${xml(grokVendorRuntimeVersion)}</string>`}
	<key>TatwoGrokVendorRuntimeSHA256</key><string>${grokVendorRuntimeSHA256}</string>
	<key>TatwoStagingRoot</key><string>${xml(root)}</string>
<key>LSEnvironment</key><dict>
<key>HOME</key><string>${xml(home)}</string>
<key>TATWO_STAGING_SCRATCH_HOME</key><string>${xml(home)}</string>
<key>TMPDIR</key><string>${xml(tmp)}</string>
<key>TATWO_ULTRAWORK_APP_SUPPORT</key><string>${xml(appSupport)}</string>
<key>TATWO_ULTRAWORK_STATE_DIR</key><string>${xml(state)}</string>
<key>TATWO_NATIVE_SUBSCRIPTION_HOME</key><string>${xml(path.join(appSupport, "model-subscriptions/openai"))}</string>
<key>TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME</key><string>${xml(path.join(appSupport, "model-subscriptions/claude"))}</string>
<key>TATWO_NATIVE_GROK_SUBSCRIPTION_HOME</key><string>${xml(path.join(appSupport, "model-subscriptions/grok"))}</string>
<key>CODEX_HOME</key><string>${xml(codexHome)}</string>
    <key>TATWO_ULTRAWORK_CHAT_WORKDIR</key><string>${xml(chatWorkdir)}</string>
</dict></dict></plist>\n`);
  const sign = run("codesign", ["--force", "--deep", "--timestamp=none", "--sign", adHoc ? "-" : identity.sha1, app]);
  assert.equal(sign.status, 0, sign.stderr);
  const receipt = {
    schema: "TatwoOSStagingBuildReceiptV1", createdAt: "20260829T000100Z",
    sourceCommit: "fixture", sourceDirty: false, sourceLabel: "fixture", appBundle: app,
    declaredAppBundle: app, bundleID, runtimeRoot: runtime, stagingHome: home,
    externalRuntimeAllowed: true, anchorIdentityFile: anchorFile, anchorService, anchorAccount,
    gatewayPort, appMCPPort, grokSubscriptionRuntimeSHA256,
    grokSubscriptionRuntimeVersion, grokVendorRuntimeSHA256,
    grokVendorRuntimeVersion,
  };
  if (!omitBrowserEnginePin) {
    receipt.browserEngine = browserEngine;
    receipt.cefEnabled = browserEngine === "chromium-cef";
  }
  if (!adHoc) Object.assign(receipt, { signingIdentitySHA1: identity.sha1, signingIdentityName: identity.name, signingMode: "fixed-identity" });
  const receiptPath = path.join(root, "staging-receipt.json");
  writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
  return {
    root,
    app,
    contents,
    receiptPath,
    runtime,
    home,
    tmp,
    identity,
    bundleID,
    chatWorkdir,
    grokExecutionMarker,
    grokSubscriptionRuntime,
    grokSubscriptionRuntimeSHA256,
    grokVendorRuntime,
    grokVendorRuntimeSHA256,
  };
}

function snapshotTree(root) {
  const result = [];
  function visit(current) {
    const stat = lstatSync(current);
    const relative = path.relative(root, current) || ".";
    if (stat.isDirectory()) {
      result.push([relative, "d", stat.mode & 0o777]);
      for (const child of readdirSync(current).sort()) visit(path.join(current, child));
    } else if (stat.isSymbolicLink()) {
      result.push([relative, "l", readlinkSync(current)]);
    } else {
      result.push([relative, "f", stat.mode & 0o777, createHash("sha256").update(readFileSync(current)).digest("hex")]);
    }
  }
  visit(root);
  return result;
}

function reuse(root, extraEnv = {}, dryRun = false, extraArgs = []) {
  const environment = {
    ...process.env,
    TATWO_BUILD_LOCK_TIMEOUT_SECONDS: "900",
    ...extraEnv,
  };
  if (!Object.hasOwn(extraEnv, "TATWO_STAGING_CHAT_WORKDIR")) {
    delete environment.TATWO_STAGING_CHAT_WORKDIR;
  }
  return run("/bin/bash", [
    scriptPath,
    "--reuse-in-place",
    root,
    ...(dryRun ? ["--dry-run"] : []),
    ...extraArgs,
  ], {
    env: environment,
  });
}

function topLevelApps(root) {
  return readdirSync(root).filter((entry) => entry.endsWith(".app"));
}

function createCEFArtifactFixture() {
  mkdirSync(fixtureBase, { recursive: true });
  const root = path.join(
    fixtureBase,
    `cef-five-helper-artifacts-${Date.now()}-${randomUUID()}`,
  );
  createdFixtureRoots.push(root);
  const app = path.join(root, "Tatwo Ultrawork Staging.app");
  const contents = path.join(app, "Contents");
  const macos = path.join(contents, "MacOS");
  const frameworks = path.join(contents, "Frameworks");
  const build = path.join(root, "build");
  const identity = signingIdentity();
  const bundleID = `com.tatwo.ultrawork.staging.cef-fixture.${randomUUID().replaceAll("-", "")}`;
  const mainExecutableName = "TatwoUltraworkMacStaging";
  const mainBundleName = "Tatwo Ultrawork Staging";
  const helperBaseName = `${mainBundleName} Helper`;
  const mainFrameworkLink =
    "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework";
  const helperFrameworkLink =
    "@executable_path/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework";
  const removableDescription = "CEF helper artifact fixture removable-volume boundary";
  const networkDescription = "CEF helper artifact fixture network-volume boundary";
  const helperVariants = [
    { suffix: "", bundleIDSuffix: "" },
    { suffix: " (Alerts)", bundleIDSuffix: ".alerts" },
    { suffix: " (GPU)", bundleIDSuffix: ".gpu" },
    { suffix: " (Plugin)", bundleIDSuffix: ".plugin" },
    { suffix: " (Renderer)", bundleIDSuffix: ".renderer" },
  ];

  mkdirSync(macos, { recursive: true });
  mkdirSync(frameworks, { recursive: true });
  mkdirSync(build, { recursive: true });
  const dylibSource = path.join(build, "cef_fixture.c");
  const dylib = path.join(build, "cef_fixture.dylib");
  const mainSource = path.join(build, "main.c");
  const mainTemplate = path.join(build, "cef_fixture_main");
  writeFileSync(dylibSource, "int tatwo_cef_fixture(void) { return 151; }\n");
  writeFileSync(
    mainSource,
    "extern int tatwo_cef_fixture(void); int main(void) { return tatwo_cef_fixture() == 151 ? 0 : 1; }\n",
  );
  const buildDylib = run("xcrun", [
    "clang",
    "-arch",
    "arm64",
    "-dynamiclib",
    "-install_name",
    mainFrameworkLink,
    dylibSource,
    "-o",
    dylib,
  ]);
  assert.equal(buildDylib.status, 0, `${buildDylib.stdout}\n${buildDylib.stderr}`);
  const buildMain = run("xcrun", [
    "clang",
    "-arch",
    "arm64",
    mainSource,
    dylib,
    "-o",
    mainTemplate,
  ]);
  assert.equal(buildMain.status, 0, `${buildMain.stdout}\n${buildMain.stderr}`);

  const mainExecutable = path.join(macos, mainExecutableName);
  copyFileSync(mainTemplate, mainExecutable);
  writeFileSync(path.join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${mainExecutableName}</string>
<key>CFBundleIdentifier</key><string>${bundleID}</string>
<key>CFBundleName</key><string>${mainBundleName}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1-staging</string>
<key>CFBundleVersion</key><string>202608300001</string>
<key>NSPrincipalClass</key><string>TatwoCEFApplication</string>
<key>TatwoBrowserEngine</key><string>chromium-cef</string>
</dict></plist>
`);
  writeFileSync(path.join(contents, "PkgInfo"), "APPL????");

  const framework = path.join(
    frameworks,
    "Chromium Embedded Framework.framework",
  );
  const frameworkResources = path.join(framework, "Resources");
  mkdirSync(path.join(frameworkResources, "en.lproj"), { recursive: true });
  copyFileSync(dylib, path.join(framework, "Chromium Embedded Framework"));
  writeFileSync(path.join(frameworkResources, "icudtl.dat"), "fixture icu\n");
  writeFileSync(path.join(frameworkResources, "resources.pak"), "fixture resources\n");
  writeFileSync(path.join(frameworkResources, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Chromium Embedded Framework</string>
<key>CFBundleIdentifier</key><string>${bundleID}.cef-framework</string>
<key>CFBundleName</key><string>Chromium Embedded Framework</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>151.0</string>
<key>CFBundleVersion</key><string>151</string>
</dict></plist>
`);

  const helperExecutables = new Map();
  for (const { suffix, bundleIDSuffix } of helperVariants) {
    const helperName = `${helperBaseName}${suffix}`;
    const helperApp = path.join(frameworks, `${helperName}.app`);
    const helperContents = path.join(helperApp, "Contents");
    const helperMacOS = path.join(helperContents, "MacOS");
    const helperExecutable = path.join(helperMacOS, helperName);
    mkdirSync(helperMacOS, { recursive: true });
    copyFileSync(mainTemplate, helperExecutable);
    const rewrite = run("/usr/bin/install_name_tool", [
      "-change",
      mainFrameworkLink,
      helperFrameworkLink,
      helperExecutable,
    ]);
    assert.equal(rewrite.status, 0, `${rewrite.stdout}\n${rewrite.stderr}`);
    writeFileSync(path.join(helperContents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${helperName}</string>
<key>CFBundleIdentifier</key><string>${bundleID}.cef-helper${bundleIDSuffix}</string>
<key>CFBundleName</key><string>${helperName}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1-staging</string>
<key>CFBundleVersion</key><string>202608300001</string>
<key>LSBackgroundOnly</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSRemovableVolumesUsageDescription</key><string>${removableDescription}</string>
<key>NSNetworkVolumesUsageDescription</key><string>${networkDescription}</string>
</dict></plist>
`);
    writeFileSync(path.join(helperContents, "PkgInfo"), "APPL????");
    helperExecutables.set(suffix || "base", helperExecutable);
  }

  for (const target of [
    framework,
    ...helperVariants.map(({ suffix }) =>
      path.join(frameworks, `${helperBaseName}${suffix}.app`)),
  ]) {
    const sign = run("codesign", [
      "--force",
      "--timestamp=none",
      "--sign",
      identity.sha1,
      target,
    ]);
    assert.equal(sign.status, 0, `${sign.stdout}\n${sign.stderr}`);
  }
  const signApp = run("codesign", [
    "--force",
    "--deep",
    "--timestamp=none",
    "--sign",
    identity.sha1,
    app,
  ]);
  assert.equal(signApp.status, 0, `${signApp.stdout}\n${signApp.stderr}`);

  return { root, app, helperExecutables };
}

test("dry-run preserves external runtime HOME and pinned fixed signing identity", () => {
  const fixture = createFixture();
  const before = snapshotTree(fixture.root);
  const result = reuse(fixture.root, {}, true);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.deepEqual(snapshotTree(fixture.root), before);
  assert.match(result.stdout, /^HOME_MODE=preserved-external-runtime-home$/m);
  assert.match(result.stdout, new RegExp(`^BUNDLE_RUNTIME_HOME=${fixture.home}$`, "m"));
  assert.match(result.stdout, new RegExp(`^STAGING_TMP=${fixture.tmp}$`, "m"));
  assert.match(result.stdout, new RegExp(`^SIGNING_IDENTITY_SHA1=${fixture.identity.sha1}$`, "m"));
  assert.match(result.stdout, /^TCC_IDENTITY_CONTINUITY=preserved$/m);
  assert.match(result.stdout, /^TCC_REAUTHORIZATION_REQUIRED=false$/m);
  assert.match(result.stdout, /^GROK_RUNTIME_REUSE_MODE=pinned-without-execution$/m);
  assert.equal(existsSync(fixture.grokExecutionMarker), false, "reuse dry-run must not execute either pinned Grok payload");
});

test("reuse Grok hash mismatch fails closed without executing the trap runtime", () => {
  const fixture = createFixture();
  const receipt = JSON.parse(readFileSync(fixture.receiptPath, "utf8"));
  receipt.grokVendorRuntimeSHA256 = "0".repeat(64);
  writeFileSync(fixture.receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
  const result = reuse(fixture.root, {}, true);
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /reuse Grok runtime receipt and signed Info\.plist hashes disagree/,
  );
  assert.equal(existsSync(fixture.grokExecutionMarker), false, "hash rejection must happen without executing Grok");
});

test("legacy signed plist preserves the vendor version through its exact wrapper-version pin", () => {
  const fixture = createFixture({ omitGrokVendorVersionPin: true });
  const result = reuse(fixture.root, {}, true);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /^GROK_RUNTIME_REUSE_MODE=pinned-without-execution$/m);
  assert.equal(existsSync(fixture.grokExecutionMarker), false);
});

test("reuse Grok missing pins, symlinks, and bundle escapes fail closed without execution", () => {
  const missingFixture = createFixture();
  const missingReceipt = JSON.parse(readFileSync(missingFixture.receiptPath, "utf8"));
  delete missingReceipt.grokVendorRuntimeVersion;
  writeFileSync(missingFixture.receiptPath, `${JSON.stringify(missingReceipt, null, 2)}\n`);
  const missingResult = reuse(missingFixture.root, {}, true);
  assert.notEqual(missingResult.status, 0);
  assert.match(missingResult.stderr, /missing grokVendorRuntimeVersion/);
  assert.equal(existsSync(missingFixture.grokExecutionMarker), false);

  const fixture = createFixture();
  const helperPath = path.join(repoRoot, "scripts", "tatwo-stage-model-runtimes.sh");
  const symlinkPath = path.join(fixture.contents, "Helpers", "ForbiddenGrokSymlink");
  symlinkSync(fixture.grokVendorRuntime, symlinkPath);
  const symlinkResult = run("/bin/bash", [
    "-c",
    `set -euo pipefail
source "$1"
tatwo_validate_pinned_grok_runtime_file "Grok symlink fixture" "$2" "$3" "$4"
`,
    "_",
    helperPath,
    symlinkPath,
    fixture.app,
    fixture.grokVendorRuntimeSHA256,
  ]);
  assert.notEqual(symlinkResult.status, 0);
  assert.match(symlinkResult.stderr, /must be a regular executable, not a symlink/);

  const unrelatedBundleRoot = path.join(fixture.root, "unrelated-bundle-root");
  mkdirSync(unrelatedBundleRoot);
  const escapeResult = run("/bin/bash", [
    "-c",
    `set -euo pipefail
source "$1"
tatwo_validate_pinned_grok_runtime_file "Grok escape fixture" "$2" "$3" "$4"
`,
    "_",
    helperPath,
    fixture.grokVendorRuntime,
    unrelatedBundleRoot,
    fixture.grokVendorRuntimeSHA256,
  ]);
  assert.notEqual(escapeResult.status, 0);
  assert.match(escapeResult.stderr, /escapes the signed staging bundle/);
  assert.equal(existsSync(fixture.grokExecutionMarker), false);
});

test("reuse actual model-runtime resolution copies only signed pinned Grok bytes without probing them", () => {
  const fixture = createFixture();
  const helperPath = path.join(repoRoot, "scripts", "tatwo-stage-model-runtimes.sh");
  const candidate = path.join(fixture.root, ".reuse-function-candidate", "payload");
  const fakeSources = path.join(fixture.root, "fake-model-runtime-sources");
  mkdirSync(fakeSources, { recursive: true });

  const subscription = path.join(fakeSources, "subscription");
  const codeModeHost = path.join(fakeSources, "code-mode-host");
  const notices = path.join(fakeSources, "THIRD_PARTY_NOTICES.txt");
  const claude = path.join(fakeSources, "claude");
  const claudeLicense = path.join(fakeSources, "CLAUDE-LICENSE.md");
  const callerTrap = path.join(fakeSources, "caller-supplied-grok-trap");
  for (const [destination, body] of [
    [subscription, "#!/bin/sh\nprintf 'subscription fixture 1\\n'\n"],
    [codeModeHost, "#!/bin/sh\nexit 0\n"],
    [claude, "#!/bin/sh\nprintf 'claude fixture 1\\n'\n"],
    [callerTrap, `#!/bin/sh\nprintf 'forbidden\\n' >${JSON.stringify(fixture.grokExecutionMarker)}\nexit 97\n`],
  ]) {
    writeFileSync(destination, body, { mode: 0o755 });
  }
  writeFileSync(notices, "fixture notices\n");
  writeFileSync(claudeLicense, "fixture license\n");

  const result = run("/bin/bash", [
    "-c",
    `set -euo pipefail
source "$1"
tatwo_resolve_model_runtimes_reusing_pinned_grok "$2" "$3" "$4" "$5"
tatwo_stage_model_runtimes "$2"
printf 'COPIED_VENDOR_SHA256=%s\\n' "$(shasum -a 256 "$2/Contents/Helpers/TatwoGrokVendorRuntime" | awk '{print $1}')"
printf 'COPIED_SUBSCRIPTION_SHA256=%s\\n' "$(shasum -a 256 "$2/Contents/Helpers/TatwoGrokSubscriptionRuntime" | awk '{print $1}')"
`,
    "_",
    helperPath,
    candidate,
    fixture.app,
    fixture.receiptPath,
    path.join(fixture.contents, "Info.plist"),
  ], {
    env: {
      ...process.env,
      TATWO_SUBSCRIPTION_RUNTIME_SOURCE: subscription,
      TATWO_SUBSCRIPTION_CODE_MODE_HOST_SOURCE: codeModeHost,
      TATWO_SUBSCRIPTION_THIRD_PARTY_NOTICES_SOURCE: notices,
      TATWO_CLAUDE_SUBSCRIPTION_RUNTIME_SOURCE: claude,
      TATWO_CLAUDE_SUBSCRIPTION_LICENSE_SOURCE: claudeLicense,
      TATWO_GROK_SUBSCRIPTION_RUNTIME_SOURCE: callerTrap,
      TATWO_GROK_VENDOR_RUNTIME_SOURCE: callerTrap,
    },
  });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(
    result.stdout,
    new RegExp(`^COPIED_VENDOR_SHA256=${fixture.grokVendorRuntimeSHA256}$`, "m"),
  );
  assert.match(
    result.stdout,
    new RegExp(`^COPIED_SUBSCRIPTION_SHA256=${fixture.grokSubscriptionRuntimeSHA256}$`, "m"),
  );
  assert.equal(existsSync(fixture.grokExecutionMarker), false, "actual reuse resolution must not execute any Grok source");
});

test("stale reuse plist Chat workdir fails closed without an explicit current-root override", () => {
  const fixture = createFixture({ staleChatWorkdir: true });
  const before = snapshotTree(fixture.root);
  const result = reuse(fixture.root, {}, true);
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /reuse Chat workdir does not match current build repo root/,
  );
  assert.match(result.stderr, /set TATWO_STAGING_CHAT_WORKDIR/);
  assert.deepEqual(snapshotTree(fixture.root), before);
});

test("explicit current-root override retargets a stale reuse plist without changing the fixed slot", () => {
  const fixture = createFixture({ staleChatWorkdir: true });
  const before = snapshotTree(fixture.root);
  const result = reuse(
    fixture.root,
    { TATWO_STAGING_CHAT_WORKDIR: repoRoot },
    true,
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /^REUSE_DRY_RUN=PASS$/m);
  assert.ok(
    result.stdout.includes(`CHAT_WORKDIR=${repoRoot}\n`),
    result.stdout,
  );
  assert.match(
    result.stdout,
    /^CHAT_WORKDIR_SOURCE=explicit-reuse-override$/m,
  );
  assert.deepEqual(snapshotTree(fixture.root), before);
  assert.deepEqual(topLevelApps(fixture.root), ["Tatwo Ultrawork Staging.app"]);
});

test("ad-hoc reuse fails closed before an unapproved signing migration", () => {
  const fixture = createFixture({ adHoc: true });
  const before = snapshotTree(fixture.root);
  const result = reuse(fixture.root, {}, true);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /^TCC_IDENTITY_CONTINUITY=blocked-adhoc-migration$/m);
  assert.match(result.stderr, /^TCC_REAUTHORIZATION_REQUIRED=true$/m);
  assert.match(result.stderr, /explicit human approval with --allow-signing-migration/);
  assert.deepEqual(snapshotTree(fixture.root), before);
});

test("explicit ad-hoc to fixed identity migration reports one-time TCC reauthorization", () => {
  const fixture = createFixture({ adHoc: true });
  const result = reuse(
    fixture.root,
    {},
    true,
    ["--allow-signing-migration"],
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /^HOME_MODE=preserved-external-runtime-home$/m);
  assert.match(result.stdout, /^PREVIOUS_SIGNATURE_MODE=adhoc$/m);
  assert.match(result.stdout, /^TCC_IDENTITY_CONTINUITY=migration-from-adhoc-requires-reauthorization$/m);
  assert.match(result.stdout, /^TCC_REAUTHORIZATION_REQUIRED=true$/m);
});

test("reuse preserves a receipt-pinned Chromium engine when --enable-cef is omitted", () => {
  const fixture = createFixture({ browserEngine: "chromium-cef" });
  const before = snapshotTree(fixture.root);
  const result = reuse(fixture.root, {}, true);
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /^BROWSER_ENGINE=chromium-cef$/m);
  assert.match(result.stdout, /^ENGINE_MIGRATION=none$/m);
  assert.deepEqual(snapshotTree(fixture.root), before);
});

test("reuse rejects an unapproved WebKit to Chromium engine migration", () => {
  const fixture = createFixture();
  const before = snapshotTree(fixture.root);
  const result = reuse(fixture.root, {}, true, ["--enable-cef"]);
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /Chromium migration requires --allow-engine-migration/,
  );
  assert.deepEqual(snapshotTree(fixture.root), before);
});

test("reuse rejects an unpinned legacy receipt without explicit Chromium migration", () => {
  const fixture = createFixture({ omitBrowserEnginePin: true });
  const before = snapshotTree(fixture.root);
  const result = reuse(fixture.root, {}, true);
  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /does not pin browserEngine and cefEnabled/,
  );
  assert.deepEqual(snapshotTree(fixture.root), before);
});

test("explicit migration upgrades an unpinned legacy receipt to Chromium", () => {
  const fixture = createFixture({ omitBrowserEnginePin: true });
  const before = snapshotTree(fixture.root);
  const result = reuse(
    fixture.root,
    {},
    true,
    ["--enable-cef", "--allow-engine-migration"],
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /^BROWSER_ENGINE=chromium-cef$/m);
  assert.match(
    result.stdout,
    /^ENGINE_MIGRATION=unversioned-to-chromium-cef$/m,
  );
  assert.deepEqual(snapshotTree(fixture.root), before);
});

test("same-slot preflight rejects a second top-level App", () => {
  const fixture = createFixture();
  mkdirSync(path.join(fixture.root, "Forbidden Second.app"));
  const result = reuse(fixture.root, {}, true);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /second staging App exists under the fixed root/);
});

test("contract pins lock metadata, jobs, atomic commit, rollback roles, and never opens reuse", () => {
  const source = readFileSync(scriptPath, "utf8");
  assert.match(source, /BUILD_LOCK_DIR="\/tmp\/tatwo-build\.lock"/);
  assert.match(source, /com\.tatwo\.build\.owner-pid/);
  assert.match(source, /com\.tatwo\.build\.started-epoch/);
  assert.match(source, /com\.tatwo\.build\.source-label/);
  assert.match(source, /com\.tatwo\.build\.command/);
  assert.match(source, /timed out waiting/);
  assert.match(source, /! kill -0 "\$owner_pid"/);
  assert.match(source, /--jobs 2/);
  assert.match(source, /APP_BUNDLE="\$REUSE_CANDIDATE_ROOT\/payload"/);
  assert.match(source, /commitPoint": "rollback-manifest-atomic-replace"/);
  assert.match(source, /archivedContentsRole": "previous_committed_contents"/);
  assert.match(source, /archivedContentsRole": "failed_candidate_contents"/);
  assert.match(source, /REUSE_COMMITTED=true/);
  assert.match(source, /--reuse-in-place never opens the App/);
});

test("CEF staging contract is explicit, fail-closed, cache-isolated, and cleans generated work", () => {
  const source = readFileSync(scriptPath, "utf8");
  const cefSource = readFileSync(cefBundleScriptPath, "utf8");
  const combinedSource = `${source}\n${cefSource}`;
  const packageSource = readFileSync(path.join(repoRoot, "Package.swift"), "utf8");
  const bridgeSource = readFileSync(
    path.join(
      repoRoot,
      "Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm",
    ),
    "utf8",
  );

  assert.match(source, /source "\$ROOT_DIR\/scripts\/tatwo-cef-bundle\.sh"/);
  assert.match(source, /tatwo_cef_initialize_runtime_configuration/);
  assert.match(cefSource, /if \[\[ "\$enable_cef" != "true" \]\]; then/);
  assert.match(cefSource, /CEF_VERSION="\$\(json_string "\$CEF_PIN_FILE" cefVersion\)"/);

  const lock = source.indexOf("acquire_build_lock");
  const prepare = source.lastIndexOf("prepare_cef_runtime", source.indexOf('if [[ "$REUSE_IN_PLACE" == "true" ]]; then', lock));
  assert.ok(lock >= 0 && prepare > lock, "--enable-cef must prepare the verified runtime after taking the build lock");
  assert.match(cefSource, /CEF_PREPARED=true/);
  assert.match(source, /--enable-cef did not activate the verified CEF runtime/);
  assert.match(cefSource, /export TATWO_ENABLE_CEF=1/);
  assert.match(source, /export TATWO_ENABLE_CEF=0/);

  assert.match(
    source,
    /TATWO_SWIFT_SCRATCH_BASE="\$\{TATWO_SWIFT_SCRATCH_PATH:-\$STAGING_ROOT\/swift-scratch\}"/,
  );
  assert.match(source, /cef-\$CEF_ARCHIVE_SHA256/);
  assert.match(source, /no-cef/);
  assert.match(source, /manifest-cache contamination/);
  assert.match(source, /cleanup_cef_work/);
  assert.match(cefSource, /CEF_EXTRACT_WORK/);
  assert.match(cefSource, /CEF_WRAPPER_WORK/);
  assert.match(cefSource, /refusing to clean unexpected CEF work path/);

  assert.match(source, /--product TatwoCEFHelper/);
  assert.match(source, /tatwo_cef_stage_app_artifacts/);
  assert.match(source, /tatwo_cef_sign_nested_artifacts/);
  assert.match(cefSource, /Chromium Embedded Framework\.framework/);
  assert.match(source, /TatwoBrowserEngine/);
  assert.match(source, /json_optional_boolean/);
  assert.match(source, /ALLOW_ENGINE_MIGRATION/);
  assert.match(source, /receipt-pinned engine/);
  assert.match(source, /TatwoCEFArchiveSHA256/);
  assert.match(source, /BROWSER_ENGINE="chromium-cef"/);
  assert.match(source, /TatwoStagingRoot/);
  assert.match(source, /verify_cef_app_artifacts/);
  assert.match(cefSource, /CEF_ARTIFACTS_VERIFIED/);
  assert.match(source, /--verify-cef-artifact-fixture/);
  assert.match(cefSource, /\/usr\/bin\/otool -L \/dev\/fd\/9 9<"\$executable"/);
  assert.doesNotMatch(
    combinedSource,
    /otool -L "\$CEF_HELPER_EXECUTABLE"/,
    "parenthesized CEF helper names must not be passed directly to otool",
  );
  assert.doesNotMatch(
    combinedSource,
    /otool -L "\$helper_executable"/,
    "production verification must inspect parenthesized helpers through an unambiguous file descriptor",
  );
  assert.match(
    cefSource,
    /helper_name_suffixes=\("" " \(Alerts\)" " \(GPU\)" " \(Plugin\)" " \(Renderer\)"\)/,
  );
  assert.match(
    cefSource,
    /helper_bundle_id_suffixes=\("" "\.alerts" "\.gpu" "\.plugin" "\.renderer"\)/,
  );
  assert.match(
    cefSource,
    /for helper_index in "\$\{!helper_name_suffixes\[@\]\}"/,
  );
  assert.match(
    cefSource,
    /helper_executable="\$helper_macos\/\$helper_name"/,
  );
  assert.match(
    cefSource,
    /helper_bundle_id="\$bundle_id\.cef-helper\$\{helper_bundle_id_suffixes\[\$helper_index\]\}"/,
  );
  assert.match(
    cefSource,
    /cp "\$build_bin_path\/TatwoCEFHelper" "\$helper_executable"/,
  );
  assert.match(
    cefSource,
    /tatwo_cef_sign_nested_artifacts\(\)/,
  );
  assert.match(
    cefSource,
    /"\$helper_info" \\\n\s+NSRemovableVolumesUsageDescription \\\n\s+"\$expected_removable_description"/,
  );
  assert.match(
    cefSource,
    /"\$helper_info" \\\n\s+NSNetworkVolumesUsageDescription \\\n\s+"\$expected_network_description"/,
  );
  assert.match(cefSource, /framework_resources\/icudtl\.dat/);
  assert.match(cefSource, /framework_resources\/resources\.pak/);
  assert.match(cefSource, /\/usr\/bin\/install_name_tool/);
  assert.match(
    cefSource,
    /@executable_path\/\.\.\/\.\.\/\.\.\/Chromium Embedded Framework\.framework\/Chromium Embedded Framework/,
  );
  assert.match(
    cefSource,
    /CEF helper variant cannot resolve the app-bundled Chromium framework/,
  );
  assert.match(cefSource, /required CEF helper variant is missing/);
  assert.match(
    cefSource,
    /helper_bundle_id="\$expected_bundle_id\.cef-helper\$\{helper_bundle_id_suffixes\[\$helper_index\]\}"/,
  );
  assert.match(
    cefSource,
    /"\$helper_info" CFBundleExecutable "\$helper_name"/,
  );
  assert.match(
    cefSource,
    /"\$helper_info" CFBundleIdentifier "\$helper_bundle_id"/,
  );
  assert.match(
    cefSource,
    /codesign --verify --strict "\$helper_app"/,
  );
  assert.match(
    cefSource,
    /assert_bundle_uses_signing_identity \\\n\s+"\$helper_app"/,
  );
  assert.match(cefSource, /assert_macho_contains_architecture "\$main_executable" arm64/);
  assert.match(cefSource, /assert_macho_contains_architecture "\$helper_executable" arm64/);
  assert.match(cefSource, /assert_macho_contains_architecture "\$framework_executable" arm64/);
  assert.ok(
    source.indexOf('verify_cef_app_artifacts "$APP_BUNDLE"')
      < source.indexOf('if [[ "$REUSE_IN_PLACE" == "true" ]]; then', source.indexOf('verify_cef_app_artifacts "$APP_BUNDLE"')),
    "candidate CEF artifacts must be verified before the reuse swap",
  );
  assert.ok(
    source.lastIndexOf('verify_cef_app_artifacts "$REUSE_TARGET_APP_BUNDLE"')
      > source.indexOf("REUSE_SWAP_COMPLETED=true"),
    "fixed-slot CEF artifacts must be reverified after the atomic swap",
  );

  assert.match(packageSource, /TATWO_ENABLE_CEF/);
  assert.match(packageSource, /TATWO_ENABLE_CEF must be exactly 0 or 1/);
  assert.match(packageSource, /TATWO_ENABLE_CEF=1 requires a verified/);
  assert.match(packageSource, /TatwoCEFBridgeUnavailable\.m/);
  assert.match(packageSource, /Chromium Embedded Framework/);
  assert.match(
    bridgeSource,
    /ResolveCEFHelperExecutablePath\(helperExecutablePath\)/,
  );
  assert.match(
    bridgeSource,
    /CefString\(&settings\.browser_subprocess_path\)\s*=\s*\n\s*ToCefString\(resolved_helper_executable_path\)/,
    "macOS must pass CEF the bundle-declared base helper executable so role-specific sibling lookup does not depend on the mismatched staging executable name",
  );
  assert.match(bridgeSource, /CefScopedSandboxContext sandbox_context/);
  assert.match(
    bridgeSource,
    /CefExecuteProcess\(main_args, application, nullptr\)/,
    "the third CefExecuteProcess argument is Windows-only; the scoped macOS sandbox context owns its own lifetime",
  );
});

test("real five-helper CEF bundles pass production verification while direct otool reproduces the parenthesized executable truncation", { timeout: 120_000 }, () => {
  const fixture = createCEFArtifactFixture();
  const alertsExecutable = fixture.helperExecutables.get(" (Alerts)");
  assert.ok(alertsExecutable);

  const directOtool = run("/usr/bin/otool", ["-L", alertsExecutable]);
  assert.notEqual(
    directOtool.status,
    0,
    "the active Apple otool must reproduce its archive-member ambiguity for the regression fixture",
  );
  assert.match(
    directOtool.stderr,
    /Tatwo Ultrawork Staging Helper\s+\(No such file or directory\)/,
  );

  const verification = run("/bin/bash", [
    scriptPath,
    "--verify-cef-artifact-fixture",
    fixture.app,
  ]);
  assert.equal(
    verification.status,
    0,
    `${verification.stdout}\n${verification.stderr}`,
  );
  assert.match(verification.stdout, /^CEF_ARTIFACTS_VERIFIED=/m);
  assert.match(verification.stdout, /^CEF_ARTIFACT_FIXTURE_VERIFIED=/m);
  assert.equal(
    [...fixture.helperExecutables.values()].length,
    5,
    "fixture must contain the complete CEF helper role set",
  );
});

test("CEF pin, bridge, helper, and backend are present and not ignored candidates", () => {
  const requiredPaths = [
    "Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json",
    "Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h",
    "Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm",
    "Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridgeUnavailable.m",
    "Apps/TatwoUltraworkMac/Sources/TatwoCEFHelper/main.swift",
    "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChromiumCEFBackend.swift",
  ];
  for (const relativePath of requiredPaths) {
    assert.ok(existsSync(path.join(repoRoot, relativePath)), `missing CEF candidate source: ${relativePath}`);
  }
  const ignored = run("git", ["check-ignore", "--", ...requiredPaths]);
  assert.notEqual(
    ignored.status,
    0,
    `CEF candidate paths must be commit-visible, not ignored:\n${ignored.stdout}\n${ignored.stderr}`,
  );
});

test("real same-slot swap commits, verifies signing, then injected post-receipt failure rolls back bytes and Contents", { timeout: 900_000 }, () => {
  const fixture = createFixture();
  const success = reuse(fixture.root);
  assert.equal(success.status, 0, `${success.stdout}\n${success.stderr}`);
  assert.deepEqual(topLevelApps(fixture.root), ["Tatwo Ultrawork Staging.app"]);
  const verify = run("codesign", ["--verify", "--deep", "--strict", fixture.app]);
  assert.equal(verify.status, 0, verify.stderr);
  const successReceipt = JSON.parse(readFileSync(fixture.receiptPath, "utf8"));
  assert.equal(successReceipt.signingIdentitySHA1, fixture.identity.sha1);
  assert.equal(successReceipt.tccIdentityContinuity, "preserved");
  const successManifestPath = path.join(fixture.root, "archives", readdirSync(path.join(fixture.root, "archives")).sort().at(-1), "rollback-manifest.json");
  const successManifest = JSON.parse(readFileSync(successManifestPath, "utf8"));
  assert.deepEqual({ state: successManifest.state, role: successManifest.archivedContentsRole, rollback: successManifest.rollbackAvailable, commit: successManifest.commitPoint }, { state: "committed", role: "previous_committed_contents", rollback: true, commit: "rollback-manifest-atomic-replace" });

  const beforeReceipt = readFileSync(fixture.receiptPath);
  const beforeContents = snapshotTree(fixture.contents);
  const failure = reuse(fixture.root, { TATWO_TEST_INJECT_REUSE_FAILURE_AFTER_RECEIPT_REPLACE: "1" });
  assert.equal(failure.status, 86, `${failure.stdout}\n${failure.stderr}`);
  assert.match(failure.stderr, /injected reuse failure immediately after receipt os\.replace/);
  assert.deepEqual(readFileSync(fixture.receiptPath), beforeReceipt, "receipt rollback must be byte-for-byte");
  assert.deepEqual(snapshotTree(fixture.contents), beforeContents, "live Contents tree must be completely restored");
  assert.deepEqual(topLevelApps(fixture.root), ["Tatwo Ultrawork Staging.app"]);
  const latestArchive = readdirSync(path.join(fixture.root, "archives")).sort().at(-1);
  const rollbackManifest = JSON.parse(readFileSync(path.join(fixture.root, "archives", latestArchive, "rollback-manifest.json"), "utf8"));
  assert.equal(rollbackManifest.state, "rolled_back");
  assert.equal(rollbackManifest.archivedContentsRole, "failed_candidate_contents");
  assert.equal(rollbackManifest.commitPoint, "rollback-manifest-atomic-replace");
  assert.ok(snapshotTree(rollbackManifest.archivedContents).length > 1);
});
