#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const helper = path.join(root, "scripts", "tatwo-embed-sparkle-framework.sh");
const packageText = fs.readFileSync(path.join(root, "Package.swift"), "utf8");
const coordinatorText = fs.readFileSync(
  path.join(
    root,
    "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac",
    "TatwoSparkleUpdateCoordinator.swift",
  ),
  "utf8",
);

assert.match(packageText, /exact:\s*"2\.9\.4"/);
assert.match(packageText, /\.product\(name:\s*"Sparkle",\s*package:\s*"Sparkle"\)/);
assert.match(coordinatorText, /^import Sparkle$/m);
assert.match(coordinatorText, /scheduledCheckInterval:\s*TimeInterval\s*=\s*6\s*\*\s*60\s*\*\s*60/);
assert.match(coordinatorText, /feedMissingOrInsecure/);
assert.match(coordinatorText, /publicKeyMissing/);
assert.match(coordinatorText, /channelMissingOrInvalid/);
assert.match(
  fs.readFileSync(helper, "utf8"),
  /tatwo_sanitize_bundle_rpaths/,
);
assert.match(
  fs.readFileSync(helper, "utf8"),
  /unsafe runtime search path remains in staged app/,
);

for (const relative of [
  "script/build_and_run.sh",
  "script/build_production_app.sh",
  "script/build_staging_app.sh",
  "scripts/install-j2-temp.sh",
]) {
  const text = fs.readFileSync(path.join(root, relative), "utf8");
  assert.match(text, /tatwo_embed_sparkle_framework/);
  assert.match(text, /tatwo_configure_sparkle_info_plist/);
  assert.doesNotMatch(text, /https:\/\/[^<\s"]+appcast/i);
}
const productionInstaller = fs.readFileSync(
  path.join(root, "scripts/install-tatwo-ultrawork.sh"),
  "utf8",
);
assert.match(productionInstaller, /TATWO_VERIFIED_PRODUCTION_APP_BUNDLE/);
assert.match(
  productionInstaller,
  /TATWO_VERIFIED_SIGNED_RELEASE_MANIFEST_SIGNATURE/,
);
assert.match(productionInstaller, /appcastSignatureVerified !== true/);
assert.match(productionInstaller, /production-release-promotion-v1/);
assert.match(productionInstaller, /codesign --verify --deep --strict/);
assert.match(productionInstaller, /spctl --assess --type execute/);
assert.doesNotMatch(productionInstaller, /tatwo_configure_sparkle_info_plist/);

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-sparkle-contract-"));
const plist = path.join(tempRoot, "Info.plist");
const validPublicKey = Buffer.alloc(32, 7).toString("base64");
const basePlist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.tatwo.contract-test</string>
</dict></plist>
`;
fs.writeFileSync(plist, basePlist);

execFileSync("/bin/bash", [
  "-c",
  `source "$1"; tatwo_configure_sparkle_info_plist "$2"`,
  "tatwo-sparkle-contract",
  helper,
  plist,
], { stdio: "pipe" });
assert.equal(readPlistKey(plist, "SUFeedURL"), null);

const partial = spawnSync(
  "/bin/bash",
  [
    "-c",
    `source "$1"; tatwo_configure_sparkle_info_plist "$2"`,
    "tatwo-sparkle-contract",
    helper,
    plist,
  ],
  {
    env: {
      ...process.env,
      TATWO_UPDATE_FEED_URL: "https://updates.example.invalid/appcast.xml",
    },
    encoding: "utf8",
  },
);
assert.notEqual(partial.status, 0);
assert.match(partial.stderr, /requires feed URL, public EdDSA key, and channel together/);

fs.writeFileSync(plist, basePlist);
execFileSync(
  "/bin/bash",
  [
    "-c",
    `source "$1"; tatwo_configure_sparkle_info_plist "$2"`,
    "tatwo-sparkle-contract",
    helper,
    plist,
  ],
  {
    env: {
      ...process.env,
      TATWO_UPDATE_FEED_URL: "https://updates.example.invalid/appcast.xml",
      TATWO_UPDATE_PUBLIC_ED_KEY: validPublicKey,
      TATWO_UPDATE_CHANNEL: "internal-canary",
    },
    stdio: "pipe",
  },
);
assert.equal(
  readPlistKey(plist, "SUFeedURL"),
  "https://updates.example.invalid/appcast.xml",
);
assert.equal(readPlistKey(plist, "TatwoUpdateChannel"), "internal-canary");
assert.equal(readPlistKey(plist, "SUEnableAutomaticChecks"), "true");
assert.equal(Number(readPlistKey(plist, "SUScheduledCheckInterval")), 21600);
assert.equal(readPlistKey(plist, "SUAutomaticallyUpdate"), "false");
assert.equal(readPlistKey(plist, "SUAllowsAutomaticUpdates"), "false");

for (const [name, environment, pattern] of [
  [
    "invalid public key",
    {
      TATWO_UPDATE_FEED_URL: "https://updates.example.invalid/appcast.xml",
      TATWO_UPDATE_PUBLIC_ED_KEY: "k".repeat(44),
      TATWO_UPDATE_CHANNEL: "stable",
    },
    /canonical base64 for 32 bytes/,
  ],
  [
    "credentialed feed URL",
    {
      TATWO_UPDATE_FEED_URL:
        "https://user:password@updates.example.invalid/appcast.xml",
      TATWO_UPDATE_PUBLIC_ED_KEY: validPublicKey,
      TATWO_UPDATE_CHANNEL: "stable",
    },
    /credential-free HTTPS URL/,
  ],
]) {
  fs.writeFileSync(plist, basePlist);
  const invalid = spawnSync(
    "/bin/bash",
    [
      "-c",
      `source "$1"; tatwo_configure_sparkle_info_plist "$2"`,
      "tatwo-sparkle-contract",
      helper,
      plist,
    ],
    {
      env: { ...process.env, ...environment },
      encoding: "utf8",
    },
  );
  assert.notEqual(invalid.status, 0, `${name} must fail closed`);
  assert.match(invalid.stderr, pattern);
}

function readPlistKey(plistPath, key) {
  const result = spawnSync(
    "/usr/libexec/PlistBuddy",
    ["-c", `Print :${key}`, plistPath],
    { encoding: "utf8" },
  );
  return result.status === 0 ? result.stdout.trim() : null;
}
