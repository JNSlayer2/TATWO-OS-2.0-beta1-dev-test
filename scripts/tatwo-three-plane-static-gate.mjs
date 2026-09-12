#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const expectedDependencies = new Map([
  ["TatwoDomainContracts", ["TatwoWorkReceiptContracts"]],
  ["TatwoDeploymentPrimitives", ["TatwoModuleContracts"]],
  ["TatwoBootstrapCore", ["TatwoDeploymentPrimitives", "TatwoModuleContracts"]],
  ["TatwoUpdater", ["TatwoDeploymentPrimitives", "TatwoModuleContracts"]],
  ["TatwoDeviceSyncCore", ["TatwoDomainContracts", "TatwoWorkReceiptContracts"]],
  ["TatwoRunnerAdapter", ["TatwoWorkReceiptContracts"]],
  ["TatwoHostDaemon", ["TatwoRunnerAdapter", "TatwoWorkReceiptContracts"]],
]);

const planeRules = {
  data: {
    forbiddenImports: [
      "TatwoBootstrapCore",
      "TatwoUpdater",
      "TatwoDeploymentPrimitives",
    ],
    forbiddenSymbols: [
      "TatwoBootstrapCommandPort",
      "TatwoUpdateCommandPort",
      "TatwoBundleActivationPort",
      "TatwoBundleActivationService",
      "TatwoHostDaemon",
      "TatwoRunnerAdapter",
    ],
  },
  deployment: {
    forbiddenImports: [
      "TatwoDomainContracts",
      "TatwoDeviceSyncCore",
    ],
    forbiddenSymbols: [
      "TatwoDataCommandPort",
      "DomainDeviceSnapshotProvider",
      "TatwoAuthorityLeaseV1",
      "TatwoDomainEventV1",
    ],
  },
  host: {
    forbiddenImports: [
      "TatwoDomainContracts",
      "TatwoDeviceSyncCore",
      "TatwoUpdater",
      "TatwoBootstrapCore",
      "TatwoDeploymentPrimitives",
    ],
    forbiddenSymbols: [
      "TatwoAuthorityLeaseV1",
      "TatwoDomainEventV1",
      "TatwoDomainDeviceSnapshotV1",
      "DomainDeviceSnapshotProvider",
      "leaseEpoch",
      "fencingToken",
      "issueAuthorityLease",
      "renewAuthorityLease",
      "transferAuthority",
      "promoteDevice",
      "appendDomainEvent",
      "requestUpdateActivation",
      "rollbackBundle",
    ],
  },
};

const forbiddenConcreteTypes = {
  data: [
    "TatwoBootstrapCore",
    "TatwoUpdater",
    "TatwoBundleActivationService",
    "TatwoHostDaemon",
    "TatwoRunnerAdapter",
  ],
  deployment: [
    "TatwoDeviceSyncCore",
    "TatwoAuthorityLeaseV1",
    "TatwoDomainEventV1",
    "TatwoHostDaemon",
    "TatwoRunnerAdapter",
  ],
  host: [
    "TatwoDeviceSyncCore",
    "TatwoAuthorityLeaseV1",
    "TatwoDomainEventV1",
    "TatwoDomainDeviceSnapshotV1",
    "TatwoUpdater",
    "TatwoBootstrapCore",
    "TatwoDeploymentPrimitives",
  ],
};

function sortedUnique(values) {
  return [...new Set(values)].sort();
}

export function validateDependencies(targetName, actualDependencies) {
  const expected = expectedDependencies.get(targetName);
  if (!expected) return [];
  const actual = sortedUnique(actualDependencies);
  const wanted = sortedUnique(expected);
  return JSON.stringify(actual) === JSON.stringify(wanted)
    ? []
    : [{
      code: "TARGET_DEPENDENCY_DRIFT",
      target: targetName,
      expected: wanted,
      actual,
    }];
}

export function validateSourceText({ plane, file, text }) {
  const rules = planeRules[plane];
  if (!rules) {
    return [{ code: "UNKNOWN_PLANE", plane, file }];
  }
  const issues = [];
  for (const moduleName of rules.forbiddenImports) {
    const importPattern = new RegExp(`^\\s*import\\s+${moduleName}\\s*$`, "m");
    if (importPattern.test(text)) {
      issues.push({
        code: "FORBIDDEN_CROSS_PLANE_IMPORT",
        plane,
        file,
        value: moduleName,
      });
    }
  }
  for (const symbol of rules.forbiddenSymbols) {
    if (text.includes(symbol)) {
      issues.push({
        code: "FORBIDDEN_CROSS_PLANE_SYMBOL",
        plane,
        file,
        value: symbol,
      });
    }
  }
  return issues;
}

export function validateConcreteTypeDependencies({ plane, file, text }) {
  const types = forbiddenConcreteTypes[plane];
  if (!types) {
    return [{ code: "UNKNOWN_PLANE", plane, file }];
  }
  return types
    .filter((typeName) => {
      const pattern = new RegExp(
        `\\b${typeName.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\$&")}\\b`,
      );
      return pattern.test(text);
    })
    .map((value) => ({
      code: "FORBIDDEN_CONCRETE_TYPE_DEPENDENCY",
      plane,
      file,
      value,
    }));
}

function extractBalanced(text, startIndex, openCharacter, closeCharacter) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = startIndex; index < text.length; index += 1) {
    const character = text[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === "\"") {
        inString = false;
      }
      continue;
    }
    if (character === "\"") {
      inString = true;
      continue;
    }
    if (character === openCharacter) depth += 1;
    if (character === closeCharacter) {
      depth -= 1;
      if (depth === 0) return text.slice(startIndex, index + 1);
    }
  }
  return null;
}

function targetBlock(packageText, targetName) {
  const targetPattern = new RegExp(
    `\\.target\\(\\s*name:\\s*"${targetName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`,
    "m",
  );
  const match = targetPattern.exec(packageText);
  if (!match) return null;
  const targetIndex = match.index;
  const openIndex = packageText.indexOf("(", targetIndex);
  return extractBalanced(packageText, openIndex, "(", ")");
}

function targetDependencies(packageText, targetName) {
  const block = targetBlock(packageText, targetName);
  if (!block) return null;
  const dependencyLabel = block.indexOf("dependencies:");
  if (dependencyLabel < 0) return [];
  const bracket = block.indexOf("[", dependencyLabel);
  const list = bracket < 0 ? null : extractBalanced(block, bracket, "[", "]");
  if (!list) return null;
  return [...list.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

function sourceFilesUnder(root, relativeDirectory, extensions) {
  const directory = path.join(root, relativeDirectory);
  if (!fs.existsSync(directory)) return [];
  const files = [];
  const stack = [directory];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const candidate = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(candidate);
      } else if (
        entry.isFile()
        && extensions.some((extension) => candidate.endsWith(extension))
      ) {
        files.push(candidate);
      }
    }
  }
  return files.sort();
}

export function evaluateThreePlaneGate(root) {
  const issues = [];
  const packagePath = path.join(root, "Package.swift");
  const packageText = fs.readFileSync(packagePath, "utf8");
  for (const targetName of expectedDependencies.keys()) {
    const dependencies = targetDependencies(packageText, targetName);
    if (dependencies === null) {
      issues.push({ code: "TARGET_NOT_PARSEABLE", target: targetName });
      continue;
    }
    issues.push(...validateDependencies(targetName, dependencies));
  }

  const sourceGroups = [
    {
      plane: "data",
      directories: [
        "Packages/TatwoDomainContracts/Sources",
        "Packages/TatwoDeviceSyncCore/Sources",
      ],
      nodeDirectories: [
        "Services/TatwoDomainCoordinator",
      ],
    },
    {
      plane: "deployment",
      directories: [
        "Packages/TatwoDeploymentPrimitives/Sources",
        "Packages/TatwoBootstrapCore/Sources",
        "Packages/TatwoUpdater/Sources",
      ],
    },
    {
      plane: "host",
      directories: [
        "Packages/TatwoRunnerAdapter/Sources",
        "Packages/TatwoHostDaemon/Sources",
      ],
      files: [
        "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/ComputerHost.swift",
        "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/HostExecutor.swift",
        "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/HostPreparation.swift",
      ],
    },
  ];

  for (const group of sourceGroups) {
    const files = [
      ...(group.directories ?? []).flatMap(
        (directory) => sourceFilesUnder(root, directory, [".swift"]),
      ),
      ...(group.nodeDirectories ?? []).flatMap(
        (directory) => sourceFilesUnder(root, directory, [".mjs"]),
      ),
      ...(group.files ?? []).map((file) => path.join(root, file)),
    ];
    for (const file of files) {
      if (!fs.existsSync(file)) {
        issues.push({
          code: "EXPECTED_SOURCE_MISSING",
          plane: group.plane,
          file: path.relative(root, file),
        });
        continue;
      }
      issues.push(...validateSourceText({
        plane: group.plane,
        file: path.relative(root, file),
        text: fs.readFileSync(file, "utf8"),
      }));
      issues.push(...validateConcreteTypeDependencies({
        plane: group.plane,
        file: path.relative(root, file),
        text: fs.readFileSync(file, "utf8"),
      }));
    }
  }

  return {
    schema: "TatwoThreePlaneStaticGateReceiptV1",
    ok: issues.length === 0,
    root,
    checkedTargets: [...expectedDependencies.keys()],
    checkedPlanes: ["data", "deployment", "host"],
    bootstrapUpdateDataCrossCallCount: issues.filter(
      (issue) => issue.code === "FORBIDDEN_CROSS_PLANE_SYMBOL",
    ).length,
    forbiddenImportCount: issues.filter(
      (issue) => issue.code === "FORBIDDEN_CROSS_PLANE_IMPORT",
    ).length,
    concreteTypeDependencyCount: issues.filter(
      (issue) => issue.code === "FORBIDDEN_CONCRETE_TYPE_DEPENDENCY",
    ).length,
    hostAuthorityProducerCount: issues.filter(
      (issue) => issue.plane === "host",
    ).length,
    issues,
  };
}

const isMain = process.argv[1]
  && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const rootIndex = process.argv.indexOf("--root");
  const root = path.resolve(
    rootIndex >= 0 && process.argv[rootIndex + 1]
      ? process.argv[rootIndex + 1]
      : path.join(path.dirname(fileURLToPath(import.meta.url)), ".."),
  );
  const receipt = evaluateThreePlaneGate(root);
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  if (!receipt.ok) process.exitCode = 2;
}
