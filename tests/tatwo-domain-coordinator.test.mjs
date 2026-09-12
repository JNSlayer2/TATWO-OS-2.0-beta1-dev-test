#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  TatwoDomainCoordinatorCore,
  authorizeCoordinatorRequest,
  canonicalPayloadDigest,
} from "../Services/TatwoDomainCoordinator/core.mjs";

const observedAt = "2026-07-19T12:00:00.000Z";
const secret = "s".repeat(48);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const wranglerExample = fs.readFileSync(
  path.join(root, "Services/TatwoDomainCoordinator/wrangler.toml.example"),
  "utf8",
);
assert.match(wranglerExample, /TATWO_DOMAIN_COORDINATOR_ENABLED = "false"/);
assert.doesNotMatch(wranglerExample, /TATWO_DOMAIN_GATEWAY_SECRET\s*=/);
assert.equal(
  fs.existsSync(path.join(root, "Services/TatwoDomainCoordinator/deploy.sh")),
  false,
);

assert.equal(
  authorizeCoordinatorRequest({
    enabled: false,
    configuredSecret: secret,
    presentedSecret: secret,
  }).code,
  "coordinator_disabled",
);
assert.equal(
  authorizeCoordinatorRequest({
    enabled: true,
    configuredSecret: undefined,
    presentedSecret: secret,
  }).code,
  "gateway_secret_missing",
);
assert.equal(
  authorizeCoordinatorRequest({
    enabled: true,
    configuredSecret: " ".repeat(48),
    presentedSecret: " ".repeat(48),
  }).code,
  "gateway_secret_missing",
);
assert.equal(
  authorizeCoordinatorRequest({
    enabled: true,
    configuredSecret: secret,
    presentedSecret: "wrong",
  }).code,
  "gateway_auth_failed",
);
assert.equal(
  authorizeCoordinatorRequest({
    enabled: true,
    configuredSecret: secret,
    presentedSecret: secret,
  }).ok,
  true,
);

const core = new TatwoDomainCoordinatorCore({ domainID: "domain-1" });
const unapprovedLease = leaseCommand({
  humanConfirmation: {
    approved: false,
    approvalID: "approval-1",
    approvedAt: observedAt,
  },
});
assertCoordinatorError(
  () => core.apply(unapprovedLease, { observedAt }),
  "human_confirmation_required",
);
assert.equal(core.publicSnapshot().activeLease, null);

const granted = core.apply(leaseCommand(), { observedAt });
assert.equal(granted.code, "authority_lease_granted");
assert.equal(granted.sequence, 1);
assert.equal(granted.lease.holderDeviceID, "mini");
assert.equal(core.publicSnapshot().nextSequence, 2);

const leaseReplay = core.apply(leaseCommand(), { observedAt });
assert.equal(leaseReplay.idempotentReplay, true);
assert.equal(core.publicSnapshot().nextSequence, 2);
assertCoordinatorError(
  () => core.apply(
    leaseCommand({ deviceID: "book" }),
    { observedAt },
  ),
  "idempotency_conflict",
);

const heartbeat = eventCommand();
const appended = core.apply(heartbeat, { observedAt });
assert.equal(appended.code, "domain_event_appended");
assert.equal(appended.sequence, 2);
assert.equal(appended.payloadDigest, heartbeat.payloadDigest);

const replay = core.apply(heartbeat, { observedAt });
assert.equal(replay.idempotentReplay, true);
assert.equal(core.publicSnapshot().nextSequence, 3);
const duplicateEvent = core.apply(
  eventCommand({
    idempotencyKey: "event-1-alternate-key",
    expectedSequence: 3,
  }),
  { observedAt },
);
assert.equal(duplicateEvent.code, "domain_event_duplicate");
assert.equal(duplicateEvent.sequence, 2);
assert.equal(core.publicSnapshot().nextSequence, 3);

assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-secondary",
      eventID: "event-secondary",
      deviceID: "book",
      expectedSequence: 3,
    }),
    { observedAt },
  ),
  "authority_holder_mismatch",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-wrong-fence",
      eventID: "event-wrong-fence",
      fencingToken: "wrong",
      expectedSequence: 3,
    }),
    { observedAt },
  ),
  "fencing_token_mismatch",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-out-of-order",
      eventID: "event-out-of-order",
      expectedSequence: 99,
    }),
    { observedAt },
  ),
  "sequence_mismatch",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-schema",
      eventID: "event-schema",
      expectedSequence: 3,
      schemaVersion: 2,
    }),
    { observedAt },
  ),
  "schema_mismatch",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-protected",
      eventID: "event-protected",
      expectedSequence: 3,
      payload: { deviceID: "mini", authToken: "must-not-sync" },
    }),
    { observedAt },
  ),
  "protected_data_rejected",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-api-key",
      eventID: "event-api-key",
      expectedSequence: 3,
      payload: { apiKey: "must-not-sync" },
    }),
    { observedAt },
  ),
  "protected_data_rejected",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-sk-value",
      eventID: "event-sk-value",
      expectedSequence: 3,
      payload: { note: "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789" },
    }),
    { observedAt },
  ),
  "protected_data_rejected",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-pem-value",
      eventID: "event-pem-value",
      expectedSequence: 3,
      payload: {
        note: "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----",
      },
    }),
    { observedAt },
  ),
  "protected_data_rejected",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-jwt-value",
      eventID: "event-jwt-value",
      expectedSequence: 3,
      payload: {
        note: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJtaW5pIn0.signature",
      },
    }),
    { observedAt },
  ),
  "protected_data_rejected",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-long-base64-value",
      eventID: "event-long-base64-value",
      expectedSequence: 3,
      payload: { note: "a".repeat(41) },
    }),
    { observedAt },
  ),
  "protected_data_rejected",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-class",
      eventID: "event-class",
      expectedSequence: 3,
      payloadClass: "rawDatabase",
    }),
    { observedAt },
  ),
  "payload_class_not_allowed",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-digest",
      eventID: "event-digest",
      expectedSequence: 3,
      payloadDigest: "0".repeat(64),
    }),
    { observedAt },
  ),
  "payload_digest_mismatch",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-float",
      eventID: "event-float",
      expectedSequence: 3,
      payload: { deviceID: "mini", load: 0.5 },
    }),
    { observedAt },
  ),
  "payload_type_invalid",
);
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "event-invalid-key",
      eventID: "event-invalid-key",
      expectedSequence: 3,
      payload: { 日本語: "must-use-typed-ascii-key" },
    }),
    { observedAt },
  ),
  "payload_key_invalid",
);
const authorityPayloadCore = new TatwoDomainCoordinatorCore({
  domainID: "domain-1",
});
authorityPayloadCore.apply(leaseCommand(), { observedAt });
assert.doesNotThrow(() => authorityPayloadCore.apply(
  eventCommand({
    idempotencyKey: "event-authority-payload",
    eventID: "event-authority-payload",
    payload: { authority: "primary" },
  }),
  { observedAt },
));
const reorderedPayload = { online: true, deviceID: "mini" };
assert.equal(
  canonicalPayloadDigest(reorderedPayload),
  canonicalPayloadDigest({ deviceID: "mini", online: true }),
);
assert.equal(
  canonicalPayloadDigest({
    status: "ok",
    nested: { enabled: true, count: 2 },
  }),
  "22140370b692dcc11d4dfb33c25bc2ab142ea4953aa4e96b32d4feccfa0b23b7",
);
assert.equal(
  canonicalPayloadDigest({
    message: "日本🙂\u2028line",
    key: "value",
  }),
  "2698c26cac4386e2147ff1ce139385b267f77b03c0c88fa9d5b78a5fd351fa2e",
);

const transferred = core.apply(
  leaseCommand({
    deviceID: "book",
    leaseEpoch: 2,
    fencingToken: "fence-2",
    idempotencyKey: "lease-2",
    expectedSequence: 3,
    eventID: "lease-2",
    humanConfirmation: {
      approved: true,
      approvalID: "approval-2",
      approvedAt: observedAt,
    },
  }),
  { observedAt },
);
assert.equal(transferred.sequence, 3);
assert.equal(transferred.lease.holderDeviceID, "book");
assertCoordinatorError(
  () => core.apply(
    eventCommand({
      idempotencyKey: "old-primary-after-transfer",
      eventID: "old-primary-after-transfer",
      expectedSequence: 4,
    }),
    { observedAt },
  ),
  "authority_holder_mismatch",
);
const bookEvent = core.apply(
  eventCommand({
    deviceID: "book",
    leaseEpoch: 2,
    fencingToken: "fence-2",
    idempotencyKey: "book-event",
    eventID: "book-event",
    expectedSequence: 4,
  }),
  { observedAt },
);
assert.equal(bookEvent.sequence, 4);

const fencingHistoryCore = new TatwoDomainCoordinatorCore({
  domainID: "fencing-history",
});
fencingHistoryCore.apply(
  leaseCommand({
    domainID: "fencing-history",
    idempotencyKey: "fencing-history-lease-1",
    eventID: "fencing-history-lease-1",
    fencingToken: "history-fence-1",
  }),
  { observedAt },
);
fencingHistoryCore.apply(
  leaseCommand({
    domainID: "fencing-history",
    deviceID: "book",
    leaseEpoch: 2,
    fencingToken: "history-fence-2",
    idempotencyKey: "fencing-history-lease-2",
    eventID: "fencing-history-lease-2",
    expectedSequence: 2,
    humanConfirmation: {
      approved: true,
      approvalID: "fencing-history-approval-2",
      approvedAt: observedAt,
    },
  }),
  { observedAt },
);
assertCoordinatorError(
  () => fencingHistoryCore.apply(
    leaseCommand({
      domainID: "fencing-history",
      leaseEpoch: 3,
      fencingToken: "history-fence-1",
      idempotencyKey: "fencing-history-lease-3-reused",
      eventID: "fencing-history-lease-3-reused",
      expectedSequence: 3,
      humanConfirmation: {
        approved: true,
        approvalID: "fencing-history-approval-3",
        approvedAt: observedAt,
      },
    }),
    { observedAt },
  ),
  "fencing_token_reuse",
);
const restoredFencingHistoryCore = new TatwoDomainCoordinatorCore({
  domainID: "fencing-history",
  snapshot: fencingHistoryCore.storageSnapshot(),
});
assertCoordinatorError(
  () => restoredFencingHistoryCore.apply(
    leaseCommand({
      domainID: "fencing-history",
      leaseEpoch: 3,
      fencingToken: "history-fence-1",
      idempotencyKey: "fencing-history-lease-3-reused-after-restart",
      eventID: "fencing-history-lease-3-reused-after-restart",
      expectedSequence: 3,
      humanConfirmation: {
        approved: true,
        approvalID: "fencing-history-approval-3-restart",
        approvedAt: observedAt,
      },
    }),
    { observedAt },
  ),
  "fencing_token_reuse",
);

const exhausted = new TatwoDomainCoordinatorCore({ domainID: "exhausted" });
exhausted.state.activeLease = {
  schema: "TatwoAuthorityLeaseV1",
  domainID: "exhausted",
  holderDeviceID: "mini",
  leaseEpoch: 1,
  fencingToken: "fence-exhausted",
  observedAt: "2026-07-19T00:00:00.000Z",
  expiresAt: "2026-07-20T00:00:00.000Z",
  source: "human_confirmed",
  humanApprovalID: "human-exhausted",
};
exhausted.state.nextSequence = Number.MAX_SAFE_INTEGER;
assertCoordinatorError(
  () => exhausted.apply(
    {
      ...eventCommand({
        domainID: "exhausted",
        fencingToken: "fence-exhausted",
        idempotencyKey: "event-exhausted",
        eventID: "event-exhausted",
        eventKind: "receipt.metadata",
        payload: { receiptID: "receipt-exhausted" },
        expectedSequence: Number.MAX_SAFE_INTEGER,
      }),
    },
    { observedAt: "2026-07-19T00:00:01.000Z" },
  ),
  "sequence_exhausted",
);

const restored = new TatwoDomainCoordinatorCore({
  domainID: "domain-1",
  snapshot: core.storageSnapshot(),
});
assert.equal(restored.publicSnapshot().nextSequence, 5);
assert.equal(restored.publicSnapshot().activeLease.holderDeviceID, "book");
const restoredDuplicateReplay = restored.apply(
  eventCommand({
    idempotencyKey: "event-1-alternate-key",
    expectedSequence: 3,
  }),
  { observedAt },
);
assert.equal(restoredDuplicateReplay.code, "domain_event_duplicate");
assert.equal(restoredDuplicateReplay.sequence, 2);
assert.equal(restoredDuplicateReplay.idempotentReplay, true);
assert.equal(restoredDuplicateReplay.mutated, false);
assert.equal(restored.publicSnapshot().nextSequence, 5);

const validStoredSnapshot = core.storageSnapshot();
const storedSnapshotTamperCases = [
  ["active lease", (snapshot) => {
    snapshot.activeLease.holderDeviceID = "mini";
  }],
  ["event payload", (snapshot) => {
    snapshot.events[1].payload.online = false;
  }],
  ["event digest", (snapshot) => {
    snapshot.events[1].payloadDigest = "0".repeat(64);
  }],
  ["missing idempotency entry", (snapshot) => {
    delete snapshot.idempotency["event-1"];
  }],
  ["wrong idempotency result", (snapshot) => {
    snapshot.idempotency["event-1"].result.sequence = 4;
  }],
  ["missing event index", (snapshot) => {
    delete snapshot.eventIndex["event-1"];
  }],
  ["wrong event index", (snapshot) => {
    snapshot.eventIndex["event-1"].sequence = 4;
  }],
  ["malformed command fingerprint", (snapshot) => {
    snapshot.idempotency["event-1"].commandFingerprint = "{";
  }],
];
for (const [label, tamper] of storedSnapshotTamperCases) {
  const snapshot = structuredClone(validStoredSnapshot);
  tamper(snapshot);
  assertCoordinatorError(
    () => new TatwoDomainCoordinatorCore({
      domainID: "domain-1",
      snapshot,
    }),
    "stored_snapshot_invalid",
    label,
  );
}

const roundTripCore = new TatwoDomainCoordinatorCore({
  domainID: "round-trip-domain",
});
roundTripCore.apply(
  leaseCommand({
    domainID: "round-trip-domain",
    idempotencyKey: "99",
    eventID: "lease-round-trip",
    fencingToken: "round-trip-fence",
  }),
  { observedAt },
);
for (let index = 1; index <= 12; index += 1) {
  roundTripCore.apply(
    eventCommand({
      domainID: "round-trip-domain",
      idempotencyKey: String(99 - index),
      eventID: `event-round-trip-${index}`,
      fencingToken: "round-trip-fence",
      expectedSequence: index + 1,
      payload: { deviceID: "mini", index },
    }),
    { observedAt },
  );
}
const persistedRoundTripSnapshot = JSON.parse(
  JSON.stringify(roundTripCore.storageSnapshot()),
);
assert.equal(
  Object.keys(persistedRoundTripSnapshot.idempotency)[0],
  "87",
  "array-index idempotency keys must demonstrate storage enumeration reordering",
);
const restoredRoundTrip = new TatwoDomainCoordinatorCore({
  domainID: "round-trip-domain",
  snapshot: persistedRoundTripSnapshot,
});
assert.equal(restoredRoundTrip.publicSnapshot().nextSequence, 14);
assert.equal(restoredRoundTrip.publicSnapshot().events.length, 13);

assertCoordinatorError(
  () => restored.apply(
    eventCommand({
      idempotencyKey: "event-expired",
      eventID: "event-expired",
      deviceID: "book",
      leaseEpoch: 2,
      fencingToken: "fence-2",
      expectedSequence: 5,
    }),
    { observedAt: "2026-07-20T13:00:00.000Z" },
  ),
  "authority_lease_expired",
);

function leaseCommand(overrides = {}) {
  return {
    type: "grant_authority_lease",
    domainID: "domain-1",
    deviceID: "mini",
    leaseEpoch: 1,
    fencingToken: "fence-1",
    idempotencyKey: "lease-1",
    expectedSequence: 1,
    expiresAt: "2026-07-19T18:00:00.000Z",
    humanConfirmation: {
      approved: true,
      approvalID: "approval-1",
      approvedAt: observedAt,
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
    occurredAt: observedAt,
    ...overrides,
  };
  if (!Object.hasOwn(overrides, "payloadDigest")) {
    command.payloadDigest = canonicalPayloadDigest(command.payload);
  }
  return command;
}

function assertCoordinatorError(action, code, label = code) {
  assert.throws(action, (error) => {
    assert.equal(error?.code, code, label);
    return true;
  });
}
