#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { canonicalPayloadDigest } from "../Services/TatwoDomainCoordinator/core.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const hostPath = path.join(root, "Services/TatwoDomainCoordinator/local-host.mjs");
const secret = "s".repeat(48);
const approvedAt = new Date().toISOString();
const expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();

test("tatwo domain coordinator local host", async t => {
const loopbackCapability = await probeLoopbackRoundtrip();
if (!loopbackCapability.available) {
  t.skip(
    "sandbox 禁止 loopback network，非程式缺陷" +
      `（127.0.0.1 bind/connect probe ${loopbackCapability.error.code}）`,
  );
  return;
}

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-local-host-test-"));
const statePath = path.join(tempDir, "coordinator-state.json");
const children = new Set();

function makeEnv(overrides = {}) {
  const env = {
    ...process.env,
    TATWO_DOMAIN_COORDINATOR_ENABLED: "true",
    TATWO_DOMAIN_GATEWAY_SECRET: secret,
  };
  for (const [key, value] of Object.entries(overrides)) {
    if (value === null) delete env[key];
    else env[key] = value;
  }
  return env;
}

function startHost({ envOverrides = {}, args = ["--port", "0", "--state", statePath] } = {}) {
  const child = spawn(process.execPath, [hostPath, ...args], {
    env: makeEnv(envOverrides),
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.add(child);
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const exit = new Promise((resolve) => {
    child.on("exit", (code, signal) => {
      children.delete(child);
      resolve({ code, signal });
    });
  });
  const ready = new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`host did not become ready\n${stdout}${stderr}`)),
      10_000,
    );
    const probe = () => {
      for (const line of stdout.split("\n")) {
        if (!line.startsWith("{")) continue;
        const parsed = JSON.parse(line);
        if (parsed.code === "listening") {
          clearTimeout(timer);
          resolve(parsed);
          return;
        }
      }
    };
    child.stdout.on("data", probe);
    exit.then(() => {
      clearTimeout(timer);
      reject(new Error(`host exited before ready\n${stdout}${stderr}`));
    });
  });
  ready.catch(() => {});
  const waitExit = () => Promise.race([
    exit,
    new Promise((_, reject) => setTimeout(
      () => reject(new Error(`host did not exit\n${stdout}${stderr}`)),
      10_000,
    )),
  ]);
  return { child, ready, waitExit, stderrText: () => stderr };
}

async function call(port, requestPath, {
  method = "GET",
  body,
  token = secret,
  headers = {},
} = {}) {
  const response = await fetch(`http://127.0.0.1:${port}${requestPath}`, {
    method,
    headers: {
      ...(token === null ? {} : { authorization: `Bearer ${token}` }),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...headers,
    },
    body: body === undefined
      ? undefined
      : (typeof body === "string" ? body : JSON.stringify(body)),
  });
  return { status: response.status, body: await response.json() };
}

function leaseCommand(overrides = {}) {
  return {
    type: "grant_authority_lease",
    domainID: "domain-1",
    deviceID: "mini",
    leaseEpoch: 1,
    fencingToken: "fence-1",
    idempotencyKey: "lease-1",
    expectedSequence: 1,
    expiresAt,
    humanConfirmation: {
      approved: true,
      approvalID: "approval-1",
      approvedAt,
    },
    ...overrides,
  };
}

function eventCommand(overrides = {}) {
  const command = {
    type: "append_domain_event",
    domainID: "domain-1",
    deviceID: "mini",
    leaseEpoch: 1,
    fencingToken: "fence-1",
    idempotencyKey: "event-1",
    expectedSequence: 2,
    schemaVersion: 1,
    protocolVersion: 1,
    eventID: "event-1",
    eventKind: "device.heartbeat",
    payloadClass: "typedMetadata",
    payload: { deviceID: "mini", online: true },
    occurredAt: approvedAt,
    ...overrides,
  };
  if (!Object.hasOwn(overrides, "payloadDigest")) {
    command.payloadDigest = canonicalPayloadDigest(command.payload);
  }
  return command;
}

try {
  // Fail-closed startup: missing secret, disabled flag, short secret, missing state path.
  const startupFailureCases = [
    [{ TATWO_DOMAIN_GATEWAY_SECRET: null }, /gateway_secret_missing/],
    [{ TATWO_DOMAIN_GATEWAY_SECRET: "x".repeat(8) }, /gateway_secret_missing/],
    [{ TATWO_DOMAIN_COORDINATOR_ENABLED: null }, /coordinator_disabled/],
    [{ TATWO_DOMAIN_COORDINATOR_ENABLED: "false" }, /coordinator_disabled/],
  ];
  for (const [envOverrides, pattern] of startupFailureCases) {
    const failing = startHost({ envOverrides });
    const { code } = await failing.waitExit();
    assert.notEqual(code, 0, `expected startup failure for ${JSON.stringify(envOverrides)}`);
    assert.match(failing.stderrText(), pattern);
  }
  const noStatePath = startHost({ args: ["--port", "0"] });
  assert.notEqual((await noStatePath.waitExit()).code, 0);
  assert.match(noStatePath.stderrText(), /state_path_required/);
  const badHost = startHost({
    args: ["--port", "0", "--state", statePath, "--host", "0.0.0.0"],
  });
  assert.notEqual((await badHost.waitExit()).code, 0);
  assert.match(badHost.stderrText(), /host_not_loopback/);

  // Healthy host on an OS-assigned high port with a temp state file.
  const first = startHost();
  const { port, host } = await first.ready;
  assert.equal(host, "127.0.0.1");

  // Authorization: wrong bearer and missing bearer are rejected without internals.
  const wrongBearer = await call(port, "/v1/domains/domain-1/snapshot", { token: "wrong" });
  assert.equal(wrongBearer.status, 401);
  assert.equal(wrongBearer.body.code, "gateway_auth_failed");
  const noBearer = await call(port, "/v1/domains/domain-1/snapshot", { token: null });
  assert.equal(noBearer.status, 401);
  assert.equal(noBearer.body.code, "gateway_auth_failed");
  const wrongBearerCommand = await call(port, "/v1/domains/domain-1/command", {
    method: "POST",
    token: "wrong",
    body: leaseCommand(),
  });
  assert.equal(wrongBearerCommand.status, 401);

  // Route hygiene.
  const unknownRoute = await call(port, "/v1/unknown");
  assert.equal(unknownRoute.status, 404);
  assert.equal(unknownRoute.body.code, "route_not_found");
  const headerlessSnapshot = await call(port, "/v1/snapshot");
  assert.equal(headerlessSnapshot.status, 503);
  assert.equal(headerlessSnapshot.body.code, "domain_id_missing");
  const invalidJSON = await call(port, "/v1/domains/domain-1/command", {
    method: "POST",
    body: "{not-json",
  });
  assert.equal(invalidJSON.status, 400);
  assert.equal(invalidJSON.body.code, "invalid_json");

  // Closed loop: grant lease (epoch 1, human-confirmed), register device,
  // append heartbeat, read snapshot.
  const granted = await call(port, "/v1/domains/domain-1/command", {
    method: "POST",
    body: leaseCommand(),
  });
  assert.equal(granted.status, 200);
  assert.equal(granted.body.code, "authority_lease_granted");
  assert.equal(granted.body.sequence, 1);
  assert.equal(granted.body.lease.leaseEpoch, 1);
  assert.equal(granted.body.lease.humanApprovalID, "approval-1");

  const registered = await call(port, "/v1/domains/domain-1/command", {
    method: "POST",
    body: eventCommand({
      idempotencyKey: "register-mini",
      eventID: "register-mini",
      eventKind: "device.registered",
      payload: { deviceID: "mini", platform: "macOS" },
      expectedSequence: 2,
    }),
  });
  assert.equal(registered.status, 200);
  assert.equal(registered.body.code, "domain_event_appended");
  assert.equal(registered.body.sequence, 2);

  const heartbeat = await call(port, "/v1/domains/domain-1/command", {
    method: "POST",
    body: eventCommand({
      idempotencyKey: "heartbeat-1",
      eventID: "heartbeat-1",
      expectedSequence: 3,
    }),
  });
  assert.equal(heartbeat.status, 200);
  assert.equal(heartbeat.body.sequence, 3);

  const snapshot = await call(port, "/v1/domains/domain-1/snapshot");
  assert.equal(snapshot.status, 200);
  assert.equal(snapshot.body.snapshot.nextSequence, 4);
  assert.equal(snapshot.body.snapshot.activeLease.holderDeviceID, "mini");
  assert.equal(snapshot.body.snapshot.events.length, 3);

  // Worker-parity headerful route reads the same domain.
  const headerSnapshot = await call(port, "/v1/snapshot", {
    headers: { "x-tatwo-domain-id": "domain-1" },
  });
  assert.equal(headerSnapshot.status, 200);
  assert.deepEqual(headerSnapshot.body.snapshot, snapshot.body.snapshot);

  // State file persisted atomically with the storage snapshot.
  const persisted = JSON.parse(fs.readFileSync(statePath, "utf8"));
  assert.equal(persisted.schema, "TatwoDomainCoordinatorLocalHostStateV1");
  assert.equal(persisted.domains["domain-1"].nextSequence, 4);

  // Restart replay: graceful SIGTERM, same state file, identical snapshot.
  first.child.kill("SIGTERM");
  const firstExit = await first.waitExit();
  assert.equal(firstExit.code, 0);

  const second = startHost();
  const { port: port2 } = await second.ready;
  const replayed = await call(port2, "/v1/domains/domain-1/snapshot");
  assert.equal(replayed.status, 200);
  assert.deepEqual(replayed.body.snapshot, snapshot.body.snapshot);

  // Idempotent replay across restart.
  const leaseReplay = await call(port2, "/v1/domains/domain-1/command", {
    method: "POST",
    body: leaseCommand(),
  });
  assert.equal(leaseReplay.status, 200);
  assert.equal(leaseReplay.body.idempotentReplay, true);
  assert.equal(leaseReplay.body.mutated, false);

  // Two devices: transfer lease to "book" at epoch 2, register it,
  // then reject fencing token reuse and epoch skipping.
  const transferred = await call(port2, "/v1/domains/domain-1/command", {
    method: "POST",
    body: leaseCommand({
      deviceID: "book",
      leaseEpoch: 2,
      fencingToken: "fence-2",
      idempotencyKey: "lease-2",
      expectedSequence: 4,
      eventID: "lease-2",
      humanConfirmation: {
        approved: true,
        approvalID: "approval-2",
        approvedAt,
      },
    }),
  });
  assert.equal(transferred.status, 200);
  assert.equal(transferred.body.lease.leaseEpoch, 2);
  assert.equal(transferred.body.lease.holderDeviceID, "book");

  const registeredBook = await call(port2, "/v1/domains/domain-1/command", {
    method: "POST",
    body: eventCommand({
      deviceID: "book",
      leaseEpoch: 2,
      fencingToken: "fence-2",
      idempotencyKey: "register-book",
      eventID: "register-book",
      eventKind: "device.registered",
      payload: { deviceID: "book", platform: "macOS" },
      expectedSequence: 5,
    }),
  });
  assert.equal(registeredBook.status, 200);
  assert.equal(registeredBook.body.sequence, 5);

  const staleWriter = await call(port2, "/v1/domains/domain-1/command", {
    method: "POST",
    body: eventCommand({
      idempotencyKey: "stale-mini",
      eventID: "stale-mini",
      expectedSequence: 6,
    }),
  });
  assert.equal(staleWriter.status, 409);
  assert.equal(staleWriter.body.code, "authority_holder_mismatch");

  const fenceReuse = await call(port2, "/v1/domains/domain-1/command", {
    method: "POST",
    body: leaseCommand({
      deviceID: "mini",
      leaseEpoch: 3,
      fencingToken: "fence-2",
      idempotencyKey: "lease-3-reuse",
      expectedSequence: 6,
    }),
  });
  assert.equal(fenceReuse.status, 409);
  assert.equal(fenceReuse.body.code, "fencing_token_reuse");

  const epochSkip = await call(port2, "/v1/domains/domain-1/command", {
    method: "POST",
    body: leaseCommand({
      deviceID: "mini",
      leaseEpoch: 4,
      fencingToken: "fence-4",
      idempotencyKey: "lease-4-skip",
      expectedSequence: 6,
    }),
  });
  assert.equal(epochSkip.status, 409);
  assert.equal(epochSkip.body.code, "lease_epoch_mismatch");

  const finalSnapshot = await call(port2, "/v1/domains/domain-1/snapshot");
  assert.equal(finalSnapshot.body.snapshot.nextSequence, 6);
  assert.equal(finalSnapshot.body.snapshot.activeLease.leaseEpoch, 2);

  // Graceful SIGINT shutdown.
  second.child.kill("SIGINT");
  const secondExit = await second.waitExit();
  assert.equal(secondExit.code, 0);

  // Tampered state file must fail closed at startup, never silently reset.
  const tampered = JSON.parse(fs.readFileSync(statePath, "utf8"));
  tampered.domains["domain-1"].activeLease.holderDeviceID = "mini";
  fs.writeFileSync(statePath, JSON.stringify(tampered));
  const rejecting = startHost();
  const rejectingExit = await rejecting.waitExit();
  assert.notEqual(rejectingExit.code, 0);
  assert.match(rejecting.stderrText(), /stored_snapshot_invalid/);

  console.log("tatwo-domain-coordinator-local-host tests passed");
} finally {
  for (const child of children) child.kill("SIGKILL");
  fs.rmSync(tempDir, { recursive: true, force: true });
}
});

async function probeLoopbackRoundtrip() {
  const server = http.createServer((_request, response) => {
    response.writeHead(204);
    response.end();
  });
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    await new Promise((resolve, reject) => {
      const request = http.get({
        host: "127.0.0.1",
        port: address.port,
        path: "/",
      }, response => {
        response.resume();
        response.on("end", () => {
          if (response.statusCode !== 204) {
            reject(new Error(`loopback probe returned HTTP ${response.statusCode}`));
            return;
          }
          resolve();
        });
      });
      request.setTimeout(2_000, () => {
        const error = new Error("loopback probe request timed out");
        error.code = "ETIMEDOUT";
        request.destroy(error);
      });
      request.on("error", reject);
    });
    return { available: true };
  } catch (error) {
    if (["EACCES", "EPERM", "EADDRNOTAVAIL", "ETIMEDOUT"].includes(error?.code)) {
      return { available: false, error };
    }
    throw error;
  } finally {
    if (server.listening) {
      await new Promise((resolve, reject) => {
        server.close(error => error ? reject(error) : resolve());
      });
    }
  }
}
