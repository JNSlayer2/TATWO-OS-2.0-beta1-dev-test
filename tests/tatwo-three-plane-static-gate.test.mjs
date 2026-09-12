#!/usr/bin/env node
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  evaluateThreePlaneGate,
  validateConcreteTypeDependencies,
  validateDependencies,
  validateSourceText,
} from "../scripts/tatwo-three-plane-static-gate.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const receipt = evaluateThreePlaneGate(root);
assert.equal(receipt.ok, true, JSON.stringify(receipt.issues, null, 2));
assert.equal(receipt.bootstrapUpdateDataCrossCallCount, 0);
assert.equal(receipt.forbiddenImportCount, 0);
assert.equal(receipt.concreteTypeDependencyCount, 0);
assert.equal(receipt.hostAuthorityProducerCount, 0);
assert.ok(receipt.checkedTargets.includes("TatwoRunnerAdapter"));
assert.ok(receipt.checkedTargets.includes("TatwoHostDaemon"));

assert.deepEqual(
  validateDependencies("TatwoDeviceSyncCore", [
    "TatwoWorkReceiptContracts",
    "TatwoDomainContracts",
  ]),
  [],
);
assert.equal(
  validateDependencies("TatwoDeviceSyncCore", [
    "TatwoDomainContracts",
    "TatwoUpdater",
  ])[0].code,
  "TARGET_DEPENDENCY_DRIFT",
);

assert.equal(
  validateSourceText({
    plane: "data",
    file: "Injected.swift",
    text: "import TatwoUpdater\n",
  })[0].code,
  "FORBIDDEN_CROSS_PLANE_IMPORT",
);
assert.equal(
  validateSourceText({
    plane: "host",
    file: "InjectedHost.swift",
    text: "let lease: TatwoAuthorityLeaseV1\n",
  })[0].code,
  "FORBIDDEN_CROSS_PLANE_SYMBOL",
);
assert.deepEqual(
  validateDependencies("TatwoRunnerAdapter", [
    "TatwoWorkReceiptContracts",
  ]),
  [],
);
assert.deepEqual(
  validateDependencies("TatwoHostDaemon", [
    "TatwoWorkReceiptContracts",
    "TatwoRunnerAdapter",
  ]),
  [],
);
assert.equal(
  validateConcreteTypeDependencies({
    plane: "host",
    file: "InjectedRunner.swift",
    text: "let updater: TatwoUpdater\n",
  })[0].code,
  "FORBIDDEN_CONCRETE_TYPE_DEPENDENCY",
);
