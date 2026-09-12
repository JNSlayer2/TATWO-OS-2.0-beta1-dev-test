import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = relative =>
  fs.readFileSync(path.join(repoRoot, relative), "utf8");
const workOS = read(
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/WorkOS.swift");
const authority = read(
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift");
const session = read(
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift");
const sessionTests = read(
  "Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/SessionPointerTests.swift");
const recovery = read(
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalRunStore.swift");
const mcp = read(
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/MCPFramework.swift");
const cli = read(
  "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift");
const nodeMCP = read("scripts/tatwo-ultrawork-mcp.mjs");
const packageManifest = read("Package.swift");
const testSupport = read(
  "Packages/TatwoUltraworkTestSupport/Sources/TatwoUltraworkTestSupport/TatwoUltraworkFixtureSupport.swift");
const coreTestBridge = read(
  "Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/TatwoUltraworkTestSupportBridge.swift");
const macTestBridge = read(
  "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/TatwoUltraworkTestSupportBridge.swift");

const productionSourceRoots = [
  ...["Packages", "Apps", "Tools"].flatMap(top =>
    fs.existsSync(path.join(repoRoot, top))
      ? fs
          .readdirSync(path.join(repoRoot, top), { withFileTypes: true })
          .filter(entry => entry.isDirectory())
          .filter(entry => entry.name !== "TatwoUltraworkTestSupport")
          .map(entry => path.join(repoRoot, top, entry.name, "Sources"))
          .filter(sourceRoot => fs.existsSync(sourceRoot))
      : []),
  path.join(repoRoot, "scripts"),
];
const productionExtensions = new Set([".swift", ".mjs", ".js", ".ts", ".sh"]);
const excludedDirectoryNames = new Set([
  ".build",
  "Tests",
  "Fixtures",
  "fixtures",
  "archive",
  "archives",
  "scratch",
]);

function productionFiles() {
  const files = [];
  const visit = current => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) {
        if (!excludedDirectoryNames.has(entry.name)) visit(absolute);
      } else if (
        entry.isFile()
        && productionExtensions.has(path.extname(entry.name))
      ) {
        files.push([
          path.relative(repoRoot, absolute).split(path.sep).join("/"),
          fs.readFileSync(absolute, "utf8"),
        ]);
      }
    }
  };
  for (const root of productionSourceRoots) visit(root);
  return files.sort(([left], [right]) => left.localeCompare(right));
}

function sourceLine(source, index) {
  const start = source.lastIndexOf("\n", index - 1) + 1;
  const end = source.indexOf("\n", index);
  return source.slice(start, end === -1 ? source.length : end);
}

function enclosingFunction(source, index) {
  const prefix = source.slice(0, index);
  const stack = [];
  let depth = 0;
  let pendingFunction = null;
  for (const line of prefix.split("\n")) {
    const functionMatch = line.match(
      /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
    if (functionMatch) pendingFunction = functionMatch[1];
    for (const character of line) {
      if (character === "{") {
        depth += 1;
        if (pendingFunction) {
          stack.push({ name: pendingFunction, depth });
          pendingFunction = null;
        }
      } else if (character === "}") {
        while (stack.at(-1)?.depth === depth) stack.pop();
        depth -= 1;
      }
    }
  }
  return stack.at(-1)?.name ?? "<type-scope>";
}

function between(source, start, end) {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing source marker: ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing source marker: ${end}`);
  return source.slice(from, to);
}

function balancedBraceSlice(source, openingBraceIndex) {
  let depth = 0;
  for (let index = openingBraceIndex; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(openingBraceIndex, index + 1);
    }
  }
  assert.fail(`unbalanced declaration at byte ${openingBraceIndex}`);
}

function declarationValueSlice(source, matchIndex) {
  let parentheses = 0;
  let brackets = 0;
  let braces = 0;
  let sawAssignment = false;
  let newlineCount = 0;
  for (let index = matchIndex; index < source.length; index += 1) {
    const character = source[index];
    if (character === "=") sawAssignment = true;
    if (character === "(") parentheses += 1;
    if (character === ")") parentheses -= 1;
    if (character === "[") brackets += 1;
    if (character === "]") brackets -= 1;
    if (character === "{") braces += 1;
    if (character === "}") braces -= 1;
    if (
      character === "\n"
      && sawAssignment
      && parentheses === 0
      && brackets === 0
      && braces === 0
    ) {
      const nextLine = source
        .slice(index + 1, source.indexOf("\n", index + 1))
        .trimStart();
      if (nextLine.startsWith(".") || nextLine.startsWith("?.")) continue;
      return source.slice(matchIndex, index);
    }
    if (character === "\n") {
      newlineCount += 1;
      if (newlineCount >= 20) return source.slice(matchIndex, index);
    }
  }
  return source.slice(matchIndex);
}

function discoverCurrentSessionPathAliases(files) {
  const aliasesByFile = new Map(files.map(([file]) => [file, new Set()]));
  for (const [file, source] of files) {
    const aliases = aliasesByFile.get(file);
    for (const match of source.matchAll(
      /\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)[^=\n{]*(=|\{)/g))
    {
      if (!/(?:url|path|file)/i.test(match[1])) continue;
      const openBrace = match[2] === "{"
        ? source.indexOf("{", match.index)
        : -1;
      const declaration = openBrace !== -1
        ? source.slice(match.index, openBrace)
          + balancedBraceSlice(source, openBrace)
        : declarationValueSlice(source, match.index);
      if (declaration.includes("current-session.json")) {
        aliases.add(match[1]);
      }
    }
  }

  let changed = true;
  while (changed) {
    changed = false;
    for (const [file, source] of files) {
      const aliases = aliasesByFile.get(file);
      for (const match of source.matchAll(
        /\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)[^=\n{]*(=|\{)/g))
      {
        const name = match[1];
        if (aliases.has(name) || !/(?:url|path|file)/i.test(name)) continue;
        const openBrace = match[2] === "{"
          ? source.indexOf("{", match.index)
          : -1;
        const declaration = openBrace !== -1
          ? source.slice(match.index, openBrace)
            + balancedBraceSlice(source, openBrace)
          : declarationValueSlice(source, match.index);
        if ([...aliases].some(alias =>
          new RegExp(`\\b${alias}\\b`).test(declaration)))
        {
          aliases.add(name);
          changed = true;
        }
      }
    }
  }
  return aliasesByFile;
}

function classifyCurrentSessionReference(lines, index, symbols) {
  const line = lines[index];
  const trimmed = line.trim();
  const continuation = /^(?:at:|to:|\)|\.)/.test(trimmed);
  const statement = continuation
    ? lines.slice(Math.max(0, index - 3), index + 1).join("\n")
    : line;
  if (/^\/\//.test(trimmed)) return "documentation";
  if (line.includes("current-session.json")) return "path_seed";
  if (/\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*/.test(line)
    && symbols.some(symbol =>
      new RegExp(`\\b(?:let|var)\\s+${symbol}\\b`).test(line)))
  {
    return "alias_definition";
  }
  if (/\bfunc\s+(?:authorityPointerData|publishAuthorityPointer|replaceAuthorityPointerForHandoff)\b/.test(line)) {
    return "authority_api_definition";
  }
  if (/removeItem|unlink|rename|replaceItem|moveItem/.test(statement)) {
    return "mutation_remove_or_replace";
  }
  if (/\.write\s*\(|createOnly\s*\(|createFile|forWritingTo/.test(statement)) {
    return "mutation_write";
  }
  if (/withExclusiveLock/.test(statement)) return "lock";
  if (/Data\s*\(\s*contentsOf:|fileExists|currentDataUnlocked/.test(statement)) {
    return "read_or_preflight";
  }
  if (/\b(?:authorityPointerData|publishAuthorityPointer|replaceAuthorityPointerForHandoff)\s*\(/.test(line)) {
    return "authority_api_call";
  }
  if (/\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*/.test(line)) {
    return "local_alias_or_value";
  }
  return "reference";
}

function currentSessionReferenceInventory() {
  const files = productionFiles();
  const aliasesByFile = discoverCurrentSessionPathAliases(files);
  const authorityAPIs = [
    "authorityPointerData",
    "publishAuthorityPointer",
    "replaceAuthorityPointerForHandoff",
  ];
  const entries = [];
  for (const [file, source] of files) {
    const aliases = [...aliasesByFile.get(file)].sort();
    const symbols = [...aliases, ...authorityAPIs];
    const lines = source.split("\n");
    lines.forEach((line, index) => {
      const referenced = symbols.filter(symbol =>
        new RegExp(`\\b${symbol}\\b`).test(line));
      if (!line.includes("current-session.json") && referenced.length === 0) {
        return;
      }
      const byteOffset = lines
        .slice(0, index)
        .reduce((count, item) => count + item.length + 1, 0);
      entries.push([
        file,
        enclosingFunction(source, byteOffset),
        classifyCurrentSessionReference(lines, index, referenced),
        referenced.join("+") || "current-session.json",
        line.trim().replace(/\s+/g, " "),
      ].join("|"));
    });
  }
  return entries.sort();
}

test("projection and canonical mutation are different typed APIs", () => {
  const projection = between(
    workOS,
    "public static func projectContract(",
    "/// Begin one new formal Work OS authority transaction.");
  assert.match(
    projection,
    /\)\s+throws\s+->\s+TatwoWorkOSContractV1\s*\{/);
  assert.doesNotMatch(
    projection,
    /recordBegin|recordManifest|publishAuthorityPointer|beginCanonical/);

  const canonical = between(
    workOS,
    "public static func beginCanonical(",
    "/// Create a fresh, store-only Goal candidate");
  assert.match(canonical, /store: TatwoGoalRunStore,/);
  assert.match(canonical, /registry: TatwoDispatchRegistry,/);
  assert.match(canonical, /sessionStore: TatwoSessionStore,/);
  assert.match(canonical, /owner: TatwoCanonicalSessionOwnerV1/);
  assert.match(
    canonical,
    /\)\s+throws\s+->\s+TatwoSessionAttachmentV1\s*\{/);
  assert.doesNotMatch(
    canonical,
    /store:\s+TatwoGoalRunStore\?|registry:\s+TatwoDispatchRegistry\?|sessionStore:\s+TatwoSessionStore\?|owner:\s+.*\?/);
  assert.match(canonical, /TatwoGoalAuthorityTransaction\(/);
  assert.match(canonical, /owner:\s+owner,/);
  assert.doesNotMatch(canonical, /owner\.expectation/);
  assert.doesNotMatch(canonical, /recordBegin|recordManifest/);
  assert.doesNotMatch(
    workOS,
    /public static func begin\(/,
    "the ambiguous optional-nil begin API must not exist");
});

test("formal authority begin and durable evidence preserve the typed owner kind", () => {
  const begin = between(
    authority,
    "public func begin(",
    "private func beginLocked(");
  assert.match(begin, /owner:\s+TatwoCanonicalSessionOwnerV1/);
  assert.doesNotMatch(begin, /owner:\s+TatwoSessionOwnerExpectationV1/);
  assert.match(authority, /let owner:\s+TatwoCanonicalSessionOwnerV1/g);
  assert.match(authority, /ownerBinding:\s+owner\.binding/);
  assert.match(
    authority,
    /ownerBinding\?\.ownerKind[\s\S]*?== intent\.owner\.ownerKind/);
  assert.match(session, /public let ownerKind: TatwoSessionOwnerKindV1\?/);
  assert.match(
    session,
    /Absent only on legacy V1\/V2 pointer bytes[\s\S]*?may not infer a legacy ID to be a thread/);
  assert.match(session, /ownerKind:\s+\$0\.ownerKind/);
});

test("next and loopStatus stateless fallbacks are pure projectContract projections", () => {
  const nextBody = between(
    workOS,
    "public static func next(",
    "public static func loopStatus(");
  const loopStatusBody = between(
    workOS,
    "public static func loopStatus(",
    "public static func submitReceipt(");
  const exactFallback =
    /\} else \{\s*contract = try projectContract\(\s*mode: effectiveMode,\s*scenarioProfileID: effectiveScenario,\s*objective: effectiveObjective,\s*scenarioBook: scenarioBook\)\s*\}/;

  for (const [name, body] of [
    ["next", nextBody],
    ["loopStatus", loopStatusBody],
  ]) {
    assert.match(body, exactFallback, `${name} must use the exact pure fallback`);
    assert.equal(
      [...body.matchAll(/contract = try projectContract\s*\(/g)].length,
      1,
      `${name} must contain exactly one stateless projectContract fallback`,
    );
    assert.doesNotMatch(
      body,
      /contract = try begin\s*\(/,
      `${name} must not call the removed ambiguous begin API`,
    );
  }
  assert.doesNotMatch(
    workOS,
    /contract = try begin\s*\(/,
    "WorkOS must contain no executable contract assignment to removed begin",
  );
});

test("schema-aware owner verification is closed-world and raw clear is absent", () => {
  assert.match(
    session,
    /public enum TatwoSessionOwnerVerificationV1[\s\S]*?case legacyV2\(TatwoSessionOwnerExpectationV1\)[\s\S]*?case canonicalV3\(TatwoCanonicalSessionOwnerV1\)/);
  const verifier = between(
    session,
    "private func verifyOwner(",
    "private func verifyOwnerIdentity(");
  assert.match(
    verifier,
    /case "TatwoSessionPointerV1":[\s\S]*?guard ownerVerification == nil/);
  assert.match(
    verifier,
    /case "TatwoSessionPointerV2":[\s\S]*?case \.legacyV2\(let expectation\)/);
  assert.match(
    verifier,
    /case "TatwoSessionAuthorityPointerV3":[\s\S]*?case \.canonicalV3\(let canonicalOwner\)/);
  assert.match(verifier, /ownerKind: canonicalOwner\.ownerKind/);
  assert.doesNotMatch(
    session,
    /public func clear\s*\(/,
    "production Core must not expose a raw current-session delete capability");
  assert.doesNotMatch(
    sessionTests,
    /\.clear\s*\(/,
    "isolated tests must clean their temporary roots instead of requesting a raw Core clear");
});

test("authority readback uses the sole canonical V3 resolver call", () => {
  const resolver = between(
    session,
    "func resolveAuthorityCurrent(",
    "private func verifyOwner(");
  assert.match(
    resolver,
    /ownerVerification: TatwoSessionOwnerVerificationV1/);
  assert.match(resolver, /requireOwnedOwnerVerification: true/);
  assert.equal(
    [...authority.matchAll(/resolveAuthorityCurrent\s*\(/g)].length,
    1);
  assert.match(
    authority,
    /resolveAuthorityCurrent\([\s\S]*?ownerVerification: \.canonicalV3\(intent\.owner\)/);
  for (const [file, source] of productionFiles()) {
    if (
      file.endsWith("GoalAuthorityTransaction.swift")
      || file.endsWith("SessionPointer.swift")
    ) continue;
    assert.doesNotMatch(
      source,
      /resolveAuthorityCurrent\s*\(/,
      `${file} must not add another authority resolver caller`);
  }
});

test("transaction pins and rechecks the exact state-root preflight before mutation", () => {
  const begin = between(
    authority,
    "public func begin(",
    "private func beginLocked(");
  assert.match(begin, /let pinnedRootPreflight[\s\S]*?preflightSnapshot/);
  assert.match(
    begin,
    /TatwoGoalStoreLifecycleLock\.withExclusiveLock[\s\S]*?TatwoGoalStoreGlobalLock\.withExclusiveLock/);
  assert.match(begin, /let lockedRootPreflight[\s\S]*?preflightSnapshot/);
  assert.match(
    begin,
    /guard lockedRootPreflight == pinnedRootPreflight[\s\S]*?stateRootIdentityChanged/);
  assert.ok(
    begin.indexOf("lockedRootPreflight") < begin.indexOf("beginLocked("),
    "root identity must be rechecked before the first transaction mutation");
  assert.equal(
    [...begin.matchAll(/^\s*return try beginLocked\s*\(/gm)].length,
    1,
    "the multi-statement record-scope closure must return beginLocked",
  );
  assert.doesNotMatch(
    begin,
    /^\s*try beginLocked\s*\(/m,
    "the record-scope closure must not discard the transaction result",
  );
});

test("official CLI and MCP begin routes are typed, same-root, and bootstrap-free", () => {
  const cliFormal = between(
    cli,
    "static func beginFormalWorkOSSession(",
    "static func bootstrapFormalWorkOSAuthorityLocksOnly(");
  assert.match(cliFormal, /requiredCanonicalSessionOwner/);
  assert.match(cliFormal, /WorkOSFactory\.beginCanonical/);
  assert.match(cliFormal, /store: goalStore/);
  assert.match(cliFormal, /registry: dispatchRegistry/);
  assert.match(cliFormal, /sessionStore: sessionStore/);
  assert.doesNotMatch(cliFormal, /bootstrapExplicitly|initializeSessionAuthorityLocksCreateOnly/);
  const cliOwnerParser = between(
    cli,
    "static func requiredCanonicalSessionOwner(",
    "/// Explicit operator-only bootstrap");
  assert.match(cliOwnerParser, /requiredOption\("--provider"/);
  assert.match(cliOwnerParser, /requiredExactlyOneOption/);
  assert.match(cliOwnerParser, /requiredOption\("--workspace"/);
  assert.match(cliOwnerParser, /isAbsolutePath/);
  assert.match(cliOwnerParser, /TatwoCanonicalSessionOwnerV1/);

  for (const marker of ['case "begin":', 'case "start":']) {
    const offset = cli.indexOf(marker);
    assert.notEqual(offset, -1);
    const surface = cli.slice(offset, offset + 1_800);
    assert.match(surface, /if args\.contains\("--initialize-authority-locks"\)/);
    assert.match(surface, /bootstrapFormalWorkOSAuthorityLocksOnly/);
    assert.match(surface, /\} else \{[\s\S]*?beginFormalWorkOSSession/);
  }
  const bootstrap = between(
    cli,
    "static func bootstrapFormalWorkOSAuthorityLocksOnly(",
    "static func scenarioConfigModels(");
  assert.doesNotMatch(bootstrap, /beginCanonical|beginCurrent/);

  const mcpDefinition = between(
    mcp,
    'name: "tatwo.os.begin"',
    'name: "tatwo.os.goal.candidate.create"');
  for (const field of ["provider", "workspace", "stateRoot"]) {
    assert.match(mcpDefinition, new RegExp(`"${field}"`));
  }
  assert.match(mcpDefinition, /"ownerSession", "ownerThread"/);
  const mcpCall = between(
    mcp,
    'case "tatwo.os.begin":',
    'case "tatwo.os.goal.candidate.create":');
  assert.match(mcpCall, /rawStateRoot\.hasPrefix\("\/"\)/);
  assert.match(mcpCall, /\(ownerSession == nil\) != \(ownerThread == nil\)/);
  assert.doesNotMatch(mcpCall, /ownerSession\s*\?\?\s*""/);
  assert.doesNotMatch(mcpCall, /ownerThread\.map/);
  assert.match(mcpCall, /TatwoCanonicalSessionOwnerV1/);
  assert.match(mcpCall, /WorkOSFactory\.beginCanonical/);
  assert.doesNotMatch(mcpCall, /TatwoGoalRunStore\.default|bootstrapExplicitly/);

  assert.match(nodeMCP, /const formalWorkOSBeginInput = \{/);
  assert.match(
    nodeMCP,
    /required: \["objective", "provider", "workspace", "stateRoot"\]/);
  assert.match(nodeMCP, /oneOf:[\s\S]*?ownerSession[\s\S]*?ownerThread/);
  assert.match(nodeMCP, /appendOption\(out, "--state-root", args\.stateRoot\)/);
  assert.match(
    nodeMCP,
    /compatibility adapter has no owner\/session\/registry authority chain[\s\S]*?return false/);
});

test("recovery is projection-only and fixture writers are isolated from production", () => {
  const recoveryBegin = between(
    recovery,
    "public func createRecovery(",
    "/// Fan-out Work OS goals require visible goal tracker evidence at activation.");
  assert.match(recoveryBegin, /WorkOSFactory\.projectContract/);
  assert.doesNotMatch(recoveryBegin, /WorkOSFactory\.beginCanonical/);

  assert.doesNotMatch(
    session,
    /public func save\(_ pointer: TatwoSessionPointer/);
  for (const production of [session, workOS]) {
    assert.doesNotMatch(production, /writeRawPointerFixtureForTesting/);
    assert.doesNotMatch(production, /issueDetachedFixtureForTesting/);
  }
  assert.match(packageManifest, /\.target\(\s*name: "TatwoUltraworkTestSupport"/);
  assert.doesNotMatch(
    packageManifest,
    /\.library\(name: "TatwoUltraworkTestSupport"/);
  for (const target of ["TatwoUltraworkCoreTests", "TatwoUltraworkMacTests"]) {
    const surface = between(
      packageManifest,
      `name: "${target}"`,
      "path:");
    assert.match(surface, /"TatwoUltraworkTestSupport"/);
  }
  assert.equal(
    [...packageManifest.matchAll(/"TatwoUltraworkTestSupport"/g)].length,
    3,
    "only the target declaration and two test dependencies may name TestSupport");
  assert.match(testSupport, /public enum TatwoUltraworkFixtureSupport/);
  assert.match(testSupport, /persistRegistryFixture/);
  assert.match(testSupport, /"dispatches"/);
  for (const bridge of [coreTestBridge, macTestBridge]) {
    assert.match(bridge, /import TatwoUltraworkTestSupport/);
    assert.match(bridge, /func writeRawPointerFixtureForTesting/);
    assert.match(bridge, /static func issueDetachedFixtureForTesting/);
  }
});

test("direct production writer calls remain in the canonical transaction only", () => {
  const files = productionFiles();
  assert.ok(files.length > 100, "production writer inventory unexpectedly narrow");
  const directWriters = [];
  for (const [file, source] of files) {
    for (const writer of [
      "recordBegin",
      "recordManifest",
      "publishAuthorityPointer",
      "replaceAuthorityPointerForHandoff",
    ]) {
      const pattern = new RegExp(`\\b${writer}\\s*\\(`, "g");
      for (const match of source.matchAll(pattern)) {
        const line = sourceLine(source, match.index);
        const kind = new RegExp(`\\bfunc\\s+${writer}\\s*\\(`).test(line)
          ? "definition"
          : "call";
        const enclosing = kind === "definition"
          ? writer
          : enclosingFunction(source, match.index);
        directWriters.push(
          `${file}:${kind}:${writer}:${enclosing}`);
      }
    }
  }
  assert.deepEqual(directWriters.sort(), [
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/DispatchRegistry.swift:definition:recordManifest:recordManifest",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift:call:publishAuthorityPointer:beginLocked",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift:call:recordManifest:beginLocked",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift:call:replaceAuthorityPointerForHandoff:beginLocked",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalRunStore.swift:definition:recordBegin:recordBegin",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift:definition:publishAuthorityPointer:publishAuthorityPointer",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift:definition:replaceAuthorityPointerForHandoff:replaceAuthorityPointerForHandoff",
  ]);

  for (const entry of directWriters.filter(value => value.includes(":call:"))) {
    assert.doesNotMatch(
      entry.split(":").at(-1),
      /init|initializ|hydrat|rehydrat|restore|ensure|repair|lazy/i,
      `${entry} hides a writer behind lifecycle naming`);
  }
});

test("recursive current-session path aliases and mutation sinks are closed-world inventoried", () => {
  const inventory = currentSessionReferenceInventory();
  assert.deepEqual(inventory, [
    'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+WorkOSBindingRecovery.swift|inspectCurrentSessionBundleFromDisk|alias_definition|pointerFile|let pointerFile = goalRunStore.directoryURL',
    'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+WorkOSBindingRecovery.swift|inspectCurrentSessionBundleFromDisk|path_seed|current-session.json|.appendingPathComponent("current-session.json", isDirectory: false)',
    "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+WorkOSBindingRecovery.swift|inspectCurrentSessionBundleFromDisk|reference|pointerFile|atPath: pointerFile.path)",
    'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+WorkOSBindingRecovery.swift|loadInitialStorePayload|path_seed|current-session.json|"current-session.json",',
    "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+WorkOSBindingRecovery.swift|refreshVerifiedCurrentSessionBundleFromDisk|alias_definition|pointerFile|let pointerFile = goalRunStore.directoryURL",
    'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+WorkOSBindingRecovery.swift|refreshVerifiedCurrentSessionBundleFromDisk|path_seed|current-session.json|.appendingPathComponent("current-session.json", isDirectory: false)',
    "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel+WorkOSBindingRecovery.swift|refreshVerifiedCurrentSessionBundleFromDisk|reference|pointerFile|atPath: pointerFile.path)",
    "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel.swift|rawFallback|documentation|current-session.json|/// Verified once from current-session.json + canonical GoalRun storage.",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift|beginLocked|authority_api_call|authorityPointerData|let pointerData = try sessionStore.authorityPointerData()",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift|beginLocked|authority_api_call|publishAuthorityPointer|pointerReadback = try sessionStore.publishAuthorityPointer(",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift|beginLocked|authority_api_call|replaceAuthorityPointerForHandoff|.replaceAuthorityPointerForHandoff(",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift|begin|documentation|authorityPointerData|// pointer. `authorityPointerData()` itself uses a pointer-side file lock,",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift|exactReadback|authority_api_call|authorityPointerData|guard let pointerData = try sessionStore.authorityPointerData(),",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift|requirePristinePreflight|authority_api_call|authorityPointerData|if let pointerData = try sessionStore.authorityPointerData() {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|<type-scope>|alias_definition|authorityPointerFileURL+fileURL|var authorityPointerFileURL: URL { fileURL }",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|<type-scope>|alias_definition|fileURL|private var fileURL: URL {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|<type-scope>|authority_api_definition|authorityPointerData|func authorityPointerData() throws -> Data? {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|<type-scope>|authority_api_definition|publishAuthorityPointer|func publishAuthorityPointer(",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|<type-scope>|authority_api_definition|replaceAuthorityPointerForHandoff|func replaceAuthorityPointerForHandoff(",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|<type-scope>|documentation|current-session.json|/// `current-session.json` is atomically replaced, so mtime or decoded-field",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|<type-scope>|documentation|current-session.json|/// `current-session.json` used to identify only the GoalRun. That was not",
    'Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|<type-scope>|path_seed|current-session.json|directoryURL.appendingPathComponent("current-session.json", isDirectory: false)',
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|attachCurrent|lock|fileURL|try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|authorityPointerData|lock|fileURL|try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|closeAndClearCurrent|lock|fileURL|return try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|closeAndClearCurrent|mutation_remove_or_replace|fileURL|try FileManager.default.removeItem(at: fileURL)",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|compareAndClearCurrent|lock|fileURL|try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|compareAndClearCurrent|mutation_remove_or_replace|fileURL|try FileManager.default.removeItem(at: fileURL)",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|currentDataUnlocked|read_or_preflight|fileURL|guard FileManager.default.fileExists(atPath: fileURL.path) else {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|currentDataUnlocked|read_or_preflight|fileURL|return try Data(contentsOf: fileURL)",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|inspectCurrent|lock|fileURL|try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|migrateCurrentV1Owner|lock|fileURL|return try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|migrateCurrentV1Owner|mutation_write|fileURL|try encoded(migrated).write(to: fileURL, options: [.atomic])",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|migrateCurrentV1Owner|read_or_preflight|fileURL|guard FileManager.default.fileExists(atPath: fileURL.path) else {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|migrateCurrentV1Owner|read_or_preflight|fileURL|let currentData = try Data(contentsOf: fileURL)",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|publishAuthorityPointer|lock|fileURL|return try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|publishAuthorityPointer|mutation_write|fileURL|at: fileURL)",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|reconcileRevisionPromotionLocked|mutation_write|fileURL|).write(to: fileURL, options: [.atomic])",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|reconcileRevisionPromotion|lock|fileURL|try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|reconcileSupersededTerminalCurrent|lock|fileURL|return try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|reconcileSupersededTerminalCurrent|reference|fileURL|try removeSupersededPointer(fileURL)",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|replaceAuthorityPointerForHandoff|lock|fileURL|return try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|replaceAuthorityPointerForHandoff|mutation_remove_or_replace|fileURL|guard rename(temporaryURL.path, fileURL.path) == 0 else {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|snapshotCurrent|lock|fileURL|try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|stopCurrent|lock|fileURL|return try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|stopCurrent|mutation_remove_or_replace|fileURL|try FileManager.default.removeItem(at: fileURL)",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|supersedePristinePlannedCurrent|lock|fileURL|return try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|supersedePristinePlannedCurrent|reference|fileURL|try removeSupersededPointer(fileURL)",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|transitionCurrentToPlannedRevision|lock|fileURL|try TatwoFileLock.withExclusiveLock(for: fileURL) {",
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift|transitionCurrentToPlannedRevision|mutation_write|fileURL|to: fileURL, options: [.atomic])",
  ]);
});
