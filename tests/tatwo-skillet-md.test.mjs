import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tool = path.join(repositoryRoot, "scripts/tatwo-skillet-md.py");
const osImage = path.join(repositoryRoot, "scripts/tatwo-os-image.py");

function run(args, extra = {}) {
  return spawnSync("python3", [tool, ...args], {
    encoding: "utf8",
    ...extra,
  });
}

test("skillet-md selftest keeps vendor SKILL.md and refuses unsafe paths", () => {
  const result = run(["selftest"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /selftest=passed/);
});

test("consumer cannot local-unify skillet.md", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-md-consumer-"));
  const result = run(["--support", work, "unify"], {
    env: { ...process.env, TATWO_OS_IMAGE_CONSUMER: "1" },
  });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /consumer cannot local-unify/);
});

test("unify archives a proposal without rewriting curated skillet.md or vendor skills", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-skillet-md-unify-"));
  const osRoot = path.join(work, "os");
  const runtime = path.join(work, "runtime");
  const vendor = path.join(runtime, "tatwo-ultrawork", "SKILL.md");
  fs.mkdirSync(osRoot, { recursive: true });
  fs.writeFileSync(path.join(osRoot, "os.md"), "# os\n");
  fs.mkdirSync(path.dirname(vendor), { recursive: true });
  fs.writeFileSync(vendor, "KEEP_TATWO\n");
  const installed = run([
    "--support", work,
    "--os-root", osRoot,
    "--canonical", path.join(osRoot, "skillet.md"),
    "--wrappers", path.join(runtime, "skillet", "SKILL.md"),
    "install",
  ], {
    env: {
      ...process.env,
      TATWO_SKILLS_RUNTIME_ROOT: runtime,
      TATWO_SKILLET_SOURCE_ROOT: "",
    },
  });
  assert.equal(installed.status, 0, installed.stderr + installed.stdout);
  const before = fs.readFileSync(path.join(osRoot, "skillet.md"), "utf8");
  const packaged = run([
    "--support", work,
    "--os-root", osRoot,
    "--canonical", path.join(osRoot, "skillet.md"),
    "--export", path.join(work, "outgoing"),
    "--device", "laptop",
    "package",
  ]);
  assert.equal(packaged.status, 0, packaged.stderr);
  const inbox = path.join(work, "skillet-md", "inbox", "laptop", "one");
  fs.cpSync(path.join(work, "outgoing"), inbox, { recursive: true });
  fs.writeFileSync(path.join(inbox, "skillet.md"), `${before}\n# laptop note\n`);
  const unified = run([
    "--support", work,
    "--os-root", osRoot,
    "--canonical", path.join(osRoot, "skillet.md"),
    "--wrappers", path.join(runtime, "skillet", "SKILL.md"),
    "--inbox", path.join(work, "skillet-md", "inbox"),
    "unify",
  ], {
    env: {
      ...process.env,
      TATWO_DATA_SYNC_ROLE: "host",
      TATWO_SKILLS_RUNTIME_ROOT: runtime,
    },
  });
  assert.equal(unified.status, 0, unified.stderr + unified.stdout);
  assert.equal(fs.readFileSync(path.join(osRoot, "skillet.md"), "utf8"), before);
  assert.equal(fs.readFileSync(vendor, "utf8"), "KEEP_TATWO\n");
  assert.match(fs.readFileSync(path.join(work, "skillet-md", "INDEX.md"), "utf8"), /laptop/);
  assert.equal(
    fs.readFileSync(path.join(runtime, "skillet", "SKILL.md"), "utf8"),
    before,
  );
});

test("os-image default OS skill slot is skillet not tatwo-ultrawork", () => {
  const source = fs.readFileSync(osImage, "utf8");
  assert.match(source, /skills-runtime\/skillet/);
  assert.match(source, /CodexData\/skills\/skillet/);
  assert.doesNotMatch(source, /skills-runtime\/tatwo-ultrawork/);
  assert.doesNotMatch(source, /CodexData\/skills\/tatwo-ultrawork/);
});
