import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tool = path.join(repositoryRoot, "scripts/tatwo-os-image.py");

function run(args, extra = {}) {
  const result = spawnSync("python3", [tool, ...args], {
    encoding: "utf8",
    ...extra,
  });
  return result;
}

function writeTree(root, files) {
  for (const [rel, body] of Object.entries(files)) {
    const dest = path.join(root, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, body);
  }
}

// SKIP_HEALTHZ prevents restart/verification, but the production busy gate still
// invokes curl first. Keep that external process boundary entirely synthetic.
function imageEnvironment(work, inFlight = 0) {
  const bin = path.join(work, "bin");
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, "curl"), `#!/bin/sh
printf '%s\\n' "$*" >> "$TATWO_TEST_IMAGE_CALLS"
printf '{"routes":{"fixture":{"in_flight":%s}}}\\n' "$TATWO_TEST_IMAGE_BUSY"
`, { mode: 0o700 });
  fs.writeFileSync(path.join(bin, "launchctl"), "#!/bin/sh\nexit 99\n", { mode: 0o700 });
  return { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`,
    TATWO_OS_IMAGE_SKIP_HEALTHZ: "1", TATWO_TEST_IMAGE_BUSY: String(inFlight),
    TATWO_TEST_IMAGE_CALLS: path.join(work, "curl.calls") };
}

test("os-image compare treats same hashes as aligned and app drift as diverged", () => {
  const result = run(["selftest-compare"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /selftest-compare=passed/);
});

test("os-image publish is content-addressed and apply restores runtime files", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-os-image-"));
  const room = path.join(work, "room");
  const laptop = path.join(work, "laptop");
  const exportDir = path.join(work, "export");
  const state = path.join(work, "state");
  const env = imageEnvironment(work);

  writeTree(room, {
    "Tatwo Ultrawork.app/Contents/MacOS/TatwoUltraworkMac": "ROOM_APP",
    "Tatwo Ultrawork.app/Contents/Resources/TatwoUltrawork_TatwoUltraworkMac.bundle/Contents/Resources/tatwo-direct-gateway-chat.mjs": "ROOM_ADAPTER",
    "gateway/runtime/server.js": "ROOM_SERVER",
    "gateway/runtime/tatwo-continuation.js": "ROOM_CONTINUATION",
    "os-skill/SKILL.md": "ROOM_SKILL",
  });
  writeTree(laptop, {
    "Tatwo Ultrawork.app/Contents/MacOS/TatwoUltraworkMac": "OLD_APP",
    "Tatwo Ultrawork.app/Contents/Resources/TatwoUltrawork_TatwoUltraworkMac.bundle/Contents/Resources/tatwo-direct-gateway-chat.mjs": "OLD_ADAPTER",
    "gateway/runtime/server.js": "OLD_SERVER",
    "gateway/runtime/tatwo-continuation.js": "OLD_CONTINUATION",
    "os-skill/SKILL.md": "OLD_SKILL",
    "native-chat-threads.json": "USER_CHAT_MUST_STAY",
  });

  const published = run([
    "--app", path.join(room, "Tatwo Ultrawork.app"),
    "--gateway", path.join(room, "gateway"),
    "--os-skill", path.join(room, "os-skill"),
    "--export", exportDir,
    "publish",
  ], { env });
  assert.equal(published.status, 0, published.stderr + published.stdout);
  assert.match(published.stdout, /published imageId=/);
  assert.ok(fs.existsSync(path.join(exportDir, "manifest.json")));

  const applied = run([
    "--app", path.join(laptop, "Tatwo Ultrawork.app"),
    "--gateway", path.join(laptop, "gateway"),
    "--os-skill", path.join(laptop, "os-skill"),
    "--state", state,
    "--export", exportDir,
    "apply",
  ], { env });
  assert.equal(applied.status, 0, applied.stderr + applied.stdout);
  assert.equal(
    fs.readFileSync(path.join(laptop, "gateway/runtime/server.js"), "utf8"),
    "ROOM_SERVER",
  );
  assert.equal(
    fs.readFileSync(path.join(laptop, "gateway/runtime/tatwo-continuation.js"), "utf8"),
    "ROOM_CONTINUATION",
  );
  assert.equal(
    fs.readFileSync(path.join(laptop, "os-skill/SKILL.md"), "utf8"),
    "ROOM_SKILL",
  );
  assert.equal(
    fs.readFileSync(path.join(laptop, "Tatwo Ultrawork.app/Contents/MacOS/TatwoUltraworkMac"), "utf8"),
    "OLD_APP",
    "scheduled apply must not silently replace a running-class App binary",
  );
  assert.equal(
    fs.readFileSync(path.join(laptop, "native-chat-threads.json"), "utf8"),
    "USER_CHAT_MUST_STAY",
  );
  const staged = JSON.parse(fs.readFileSync(path.join(state, "staged.json"), "utf8"));
  assert.equal(staged.schema, "TatwoOsImageManifestV1");
});

test("os-image fixture isolates the busy gate and still defers before an idle apply", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-os-image-busy-"));
  const room = path.join(work, "room"), laptop = path.join(work, "laptop");
  for (const [root, body] of [[room, "NEW"], [laptop, "OLD"]]) {
    writeTree(root, {
      "app/Contents/MacOS/TatwoUltraworkMac": body,
      "app/Contents/Resources/TatwoUltrawork_TatwoUltraworkMac.bundle/Contents/Resources/tatwo-direct-gateway-chat.mjs": body,
      "gateway/runtime/server.js": body,
      "gateway/runtime/tatwo-continuation.js": body,
      "os-skill/SKILL.md": body,
    });
  }
  const args = root => ["--app", path.join(root, "app"),
    "--gateway", path.join(root, "gateway"), "--os-skill", path.join(root, "os-skill"),
    "--export", path.join(work, "export"), "--state", path.join(work, "state")];
  const env = imageEnvironment(work, 1);
  const published = run([...args(room), "publish"], { env });
  assert.equal(published.status, 0, published.stdout + published.stderr);
  const busy = run([...args(laptop), "apply"], { env });
  assert.equal(busy.status, 0, busy.stdout + busy.stderr);
  assert.match(busy.stdout, /deferred=runtime reason=gateway_busy/);
  assert.equal(fs.readFileSync(path.join(laptop, "gateway/runtime/server.js"), "utf8"), "OLD");
  const idle = run([...args(laptop), "apply"], {
    env: { ...env, TATWO_TEST_IMAGE_BUSY: "0" },
  });
  assert.equal(idle.status, 0, idle.stdout + idle.stderr);
  assert.match(idle.stdout, /applied=runtime/);
  assert.equal(fs.readFileSync(path.join(laptop, "gateway/runtime/server.js"), "utf8"), "NEW");
  const calls = fs.readFileSync(env.TATWO_TEST_IMAGE_CALLS, "utf8").trim().split("\n");
  assert.equal(calls.length, 2);
  assert.ok(calls.every(call => call.endsWith("http://127.0.0.1:4177/healthz")));
});
test("os-image refuses to publish a torn live tree", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-os-image-torn-"));
  writeTree(work, {
    "Tatwo Ultrawork.app/Contents/MacOS/TatwoUltraworkMac": "APP",
    "gateway/runtime/server.js": "SERVER",
  });
  const published = run([
    "--app", path.join(work, "Tatwo Ultrawork.app"),
    "--gateway", path.join(work, "gateway"),
    "--os-skill", path.join(work, "os-skill"),
    "--export", path.join(work, "export"),
    "publish",
  ]);
  assert.equal(published.status, 2);
  assert.match(published.stderr, /live image incomplete/);
});
