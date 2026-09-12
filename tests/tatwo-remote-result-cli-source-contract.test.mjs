import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const repo = path.resolve(import.meta.dirname, "..");
const cli = fs.readFileSync(
  path.join(repo, "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/RemoteRunnerCLI.swift"),
  "utf8",
);

test("remote-runner result exposes provider-observed exact-model evidence", () => {
  assert.match(cli, /requestedCanonicalModelID:/);
  assert.match(cli, /requestedVendorModelID:/);
  assert.match(cli, /observedAssistantModelIDs:/);
  assert.match(cli, /modelUsageKeys:/);
  assert.match(cli, /fallbackEventCount:/);
  assert.match(cli, /modelAttestationOutcome:/);
  assert.match(cli, /receipt\.modelExecutionAttestation\?\.requestedCanonicalModelID/);
  assert.match(cli, /receipt\.modelExecutionAttestation\?\.observedAssistantModelIDs/);
  assert.match(cli, /receipt\.modelExecutionAttestation\?\.modelUsageKeys/);
  assert.match(cli, /receipt\.modelExecutionAttestation\?\.fallbackEventCount/);
  assert.match(cli, /receipt\.modelExecutionAttestation\?\.outcome\.rawValue/);
});
