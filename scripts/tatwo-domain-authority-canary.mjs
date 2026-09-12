#!/usr/bin/env node
import assert from "node:assert/strict";
import {
  TatwoDomainCoordinatorCore,
  TatwoDomainCoordinatorError,
  canonicalPayloadDigest,
} from "../Services/TatwoDomainCoordinator/core.mjs";

const observedAt = "2026-07-19T12:00:00.000Z";
const core = new TatwoDomainCoordinatorCore({ domainID: "personal-domain-canary" });

const leaseMini = core.apply(
  {
    type: "grant_authority_lease",
    domainID: "personal-domain-canary",
    deviceID: "mac-mini",
    leaseEpoch: 1,
    fencingToken: "mini-fencing-token-epoch-1",
    idempotencyKey: "lease-mini-epoch-1",
    expectedSequence: 1,
    expiresAt: "2026-07-19T20:00:00.000Z",
    humanConfirmation: {
      approved: true,
      approvalID: "human-canary-mini",
      approvedAt: observedAt,
    },
  },
  { observedAt },
);
assert.equal(leaseMini.code, "authority_lease_granted");
assert.equal(leaseMini.sequence, 1);

const miniPayload = {
  deviceID: "mac-mini",
  state: "online",
  observedAt,
};
const miniEvent = {
  type: "append_domain_event",
  domainID: "personal-domain-canary",
  deviceID: "mac-mini",
  leaseEpoch: 1,
  fencingToken: "mini-fencing-token-epoch-1",
  idempotencyKey: "heartbeat-mini-1",
  expectedSequence: 2,
  schemaVersion: 1,
  protocolVersion: 1,
  eventID: "event-heartbeat-mini-1",
  eventKind: "device.heartbeat",
  payloadClass: "typedMetadata",
  payload: miniPayload,
  payloadDigest: canonicalPayloadDigest(miniPayload),
  occurredAt: observedAt,
};
const miniAppend = core.apply(miniEvent, { observedAt });
assert.equal(miniAppend.code, "domain_event_appended");
assert.equal(miniAppend.sequence, 2);
assert.equal(core.apply(miniEvent, { observedAt }).idempotentReplay, true);

assertCoordinatorError(
  () =>
    core.apply(
      {
        ...miniEvent,
        deviceID: "macbook",
        eventID: "event-heartbeat-book-before-transfer",
        idempotencyKey: "heartbeat-book-before-transfer",
        expectedSequence: 3,
      },
      { observedAt },
    ),
  "authority_holder_mismatch",
);

const transferObservedAt = "2026-07-19T12:10:00.000Z";
const leaseBook = core.apply(
  {
    type: "grant_authority_lease",
    domainID: "personal-domain-canary",
    deviceID: "macbook",
    leaseEpoch: 2,
    fencingToken: "book-fencing-token-epoch-2",
    idempotencyKey: "lease-book-epoch-2",
    expectedSequence: 3,
    expiresAt: "2026-07-19T20:10:00.000Z",
    humanConfirmation: {
      approved: true,
      approvalID: "human-canary-book",
      approvedAt: transferObservedAt,
    },
  },
  { observedAt: transferObservedAt },
);
assert.equal(leaseBook.code, "authority_lease_granted");
assert.equal(leaseBook.sequence, 3);

const bookPayload = {
  deviceID: "macbook",
  state: "online",
  observedAt: transferObservedAt,
};
const bookAppend = core.apply(
  {
    type: "append_domain_event",
    domainID: "personal-domain-canary",
    deviceID: "macbook",
    leaseEpoch: 2,
    fencingToken: "book-fencing-token-epoch-2",
    idempotencyKey: "heartbeat-book-1",
    expectedSequence: 4,
    schemaVersion: 1,
    protocolVersion: 1,
    eventID: "event-heartbeat-book-1",
    eventKind: "device.heartbeat",
    payloadClass: "typedMetadata",
    payload: bookPayload,
    payloadDigest: canonicalPayloadDigest(bookPayload),
    occurredAt: transferObservedAt,
  },
  { observedAt: transferObservedAt },
);
assert.equal(bookAppend.code, "domain_event_appended");
assert.equal(bookAppend.sequence, 4);

assertCoordinatorError(
  () =>
    core.apply(
      {
        ...miniEvent,
        idempotencyKey: "heartbeat-mini-stale-epoch",
        eventID: "event-heartbeat-mini-stale-epoch",
        expectedSequence: 5,
      },
      { observedAt: transferObservedAt },
    ),
  "authority_holder_mismatch",
);

const snapshot = core.publicSnapshot();
assert.equal(snapshot.nextSequence, 5);
assert.equal(snapshot.activeLease.holderDeviceID, "macbook");
assert.equal(snapshot.activeLease.leaseEpoch, 2);
assert.equal(snapshot.events.length, 4);

process.stdout.write(
  `${JSON.stringify(
    {
      schema: "TatwoDomainAuthorityCanaryReceiptV1",
      status: "passed",
      domainID: snapshot.domainID,
      initialPrimary: "mac-mini",
      finalPrimary: "macbook",
      explicitHumanConfirmationCount: 2,
      automaticElectionCount: 0,
      acceptedEventCount: snapshot.events.length,
      staleAuthorityWriteRejected: true,
      protectedDataWriteCount: 0,
      updatePlaneCallCount: 0,
      bootstrapPlaneCallCount: 0,
    },
    null,
    2,
  )}\n`,
);

function assertCoordinatorError(operation, code) {
  assert.throws(operation, (error) => {
    assert.ok(error instanceof TatwoDomainCoordinatorError);
    assert.equal(error.code, code);
    return true;
  });
}
