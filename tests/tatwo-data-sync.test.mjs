import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tool = path.join(repositoryRoot, "scripts/tatwo-data-sync.py");

function run(args, extra = {}) {
  return spawnSync("python3", [tool, ...args], {
    encoding: "utf8",
    ...extra,
  });
}

function writeJSON(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`);
}

test("data-sync selftest-merge unions concurrent host and secondary edits", () => {
  const result = run(["selftest-merge"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /selftest-merge=passed/);
});

test("apply overwrite is refused", () => {
  const result = run(["apply"]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /submit to host/);
});

test("unify merges inbox into host and never writes the secondary store", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-data-sync-"));
  const host = path.join(work, "host");
  const laptop = path.join(work, "laptop");
  const exportDir = path.join(work, "submit");
  const inbox = path.join(host, "data-sync", "inbox");

  const hostNative = {
    schemaVersion: 1,
    updatedAt: "2026-08-15T01:00:00Z",
    projects: [],
    threads: [
      {
        id: "shared",
        title: "host-work",
        updatedAt: "2026-08-15T01:00:00Z",
        adapterSessionHandles: [
          { adapterID: "host", providerSessionID: "h1" },
        ],
      },
    ],
  };
  const laptopNative = {
    schemaVersion: 1,
    updatedAt: "2026-08-15T04:00:00Z",
    projects: [],
    threads: [
      {
        id: "shared",
        title: "laptop-opt",
        updatedAt: "2026-08-15T04:00:00Z",
        adapterSessionHandles: [
          { adapterID: "laptop", providerSessionID: "l1" },
        ],
      },
      {
        id: "laptop-only",
        title: "only-here",
        updatedAt: "2026-08-15T04:10:00Z",
        adapterSessionHandles: [],
      },
    ],
  };
  const hostJournal = {
    schema: "ChatTranscriptJournalSnapshotV1",
    events: [
      {
        eventID: "keep-host",
        occurredAt: "2026-08-15T01:00:00Z",
        sequence: 1,
        summary: "host",
      },
    ],
    threads: [{ id: "thread:host", turns: [] }],
  };
  const laptopJournal = {
    schema: "ChatTranscriptJournalSnapshotV1",
    events: [
      {
        eventID: "keep-laptop",
        occurredAt: "2026-08-15T04:00:00Z",
        sequence: 2,
        summary: "laptop",
      },
    ],
    threads: [{ id: "thread:laptop", turns: [] }],
  };

  writeJSON(path.join(host, "native-chat-threads.json"), hostNative);
  writeJSON(path.join(host, "chat-transcript-journal-v1.json"), hostJournal);
  writeJSON(path.join(laptop, "native-chat-threads.json"), laptopNative);
  writeJSON(path.join(laptop, "chat-transcript-journal-v1.json"), laptopJournal);

  const packaged = run([
    "--support",
    laptop,
    "--export",
    exportDir,
    "--device",
    "MacBook",
    "package",
  ]);
  assert.equal(packaged.status, 0, packaged.stderr + packaged.stdout);
  assert.match(packaged.stdout, /packaged submitId=/);
  assert.deepEqual(
    JSON.parse(fs.readFileSync(path.join(laptop, "native-chat-threads.json"), "utf8")),
    laptopNative,
    "package must not mutate secondary live files",
  );

  const manifest = JSON.parse(fs.readFileSync(path.join(exportDir, "manifest.json"), "utf8"));
  assert.equal(manifest.schema, "TatwoDeviceDataSubmitV1");
  assert.equal(manifest.direction, "secondary-to-host");
  const staged = path.join(inbox, manifest.device, manifest.submitId);
  fs.mkdirSync(path.dirname(staged), { recursive: true });
  fs.cpSync(exportDir, staged, { recursive: true });

  const unified = run([
    "--support",
    host,
    "--inbox",
    inbox,
    "unify",
  ]);
  assert.equal(unified.status, 0, unified.stderr + unified.stdout);
  assert.match(unified.stdout, /unified submitCount=1/);

  assert.deepEqual(
    JSON.parse(fs.readFileSync(path.join(laptop, "native-chat-threads.json"), "utf8")),
    laptopNative,
    "unify must never write back to the secondary",
  );

  const mergedNative = JSON.parse(
    fs.readFileSync(path.join(host, "native-chat-threads.json"), "utf8"),
  );
  const ids = mergedNative.threads.map((thread) => thread.id).sort();
  assert.deepEqual(ids, ["laptop-only", "shared"]);
  const shared = mergedNative.threads.find((thread) => thread.id === "shared");
  assert.equal(shared.title, "laptop-opt");
  const adapters = shared.adapterSessionHandles.map((item) => item.adapterID).sort();
  assert.deepEqual(adapters, ["host", "laptop"]);

  const mergedJournal = JSON.parse(
    fs.readFileSync(path.join(host, "chat-transcript-journal-v1.json"), "utf8"),
  );
  const eventIDs = mergedJournal.events.map((item) => item.eventID).sort();
  assert.deepEqual(eventIDs, ["keep-host", "keep-laptop"]);
  const journalThreads = mergedJournal.threads.map((item) => item.id).sort();
  assert.deepEqual(journalThreads, ["thread:host", "thread:laptop"]);

  assert.ok(
    fs.existsSync(path.join(host, "data-sync-previous", "native-chat-threads.json")),
  );
  const leftover = fs.readdirSync(inbox).filter((name) => !name.startsWith("."));
  assert.deepEqual(leftover, [], `inbox should be drained, leftover=${leftover.join(",")}`);
});

test("consumer environment cannot unify into its own live files", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-data-sync-consumer-"));
  const laptop = path.join(work, "laptop");
  writeJSON(path.join(laptop, "native-chat-threads.json"), {
    schemaVersion: 1,
    threads: [{ id: "keep", title: "mine" }],
    projects: [],
  });
  writeJSON(path.join(laptop, "chat-transcript-journal-v1.json"), {
    schema: "ChatTranscriptJournalSnapshotV1",
    events: [],
    threads: [],
  });
  const before = fs.readFileSync(path.join(laptop, "native-chat-threads.json"), "utf8");
  const result = run(
    ["--support", laptop, "--inbox", path.join(laptop, "data-sync", "inbox"), "unify"],
    { env: { ...process.env, TATWO_OS_IMAGE_CONSUMER: "1" } },
  );
  assert.equal(result.status, 2);
  assert.match(result.stderr, /refuse local unify on a consumer/);
  assert.equal(fs.readFileSync(path.join(laptop, "native-chat-threads.json"), "utf8"), before);
});

test("empty inbox leaves host files untouched", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-data-sync-empty-"));
  const host = path.join(work, "host");
  writeJSON(path.join(host, "native-chat-threads.json"), {
    schemaVersion: 1,
    threads: [{ id: "keep", title: "same" }],
    projects: [],
  });
  writeJSON(path.join(host, "chat-transcript-journal-v1.json"), {
    schema: "ChatTranscriptJournalSnapshotV1",
    events: [],
    threads: [],
  });
  const before = fs.readFileSync(path.join(host, "native-chat-threads.json"), "utf8");
  const result = run([
    "--support",
    host,
    "--inbox",
    path.join(host, "data-sync", "inbox"),
    "unify",
  ]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /submitCount=0/);
  assert.equal(fs.readFileSync(path.join(host, "native-chat-threads.json"), "utf8"), before);
});
