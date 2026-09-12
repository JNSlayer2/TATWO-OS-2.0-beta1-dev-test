import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const mainPath = path.join(
  repoRoot,
  "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift",
);
const sessionPath = path.join(
  repoRoot,
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/SessionPointer.swift",
);
const sessionTestsPath = path.join(
  repoRoot,
  "Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/SessionPointerTests.swift",
);
const authorityPath = path.join(
  repoRoot,
  "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalAuthorityTransaction.swift",
);
const chatModelPath = path.join(
  repoRoot,
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel.swift",
);
const appBootstrapPath = path.join(
  repoRoot,
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppAuthorityBootstrap.swift",
);
const appShellPath = path.join(
  repoRoot,
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift",
);
const formalCallerPaths = [
  "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/AppShellModesIntegrationTests.swift",
  "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/GoalRevisionConfirmationTests.swift",
  "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/PanelSnapshotExporterTests.swift",
  "Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/GoalRevisionPromotionTests.swift",
  "Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/GoalRevisionBootstrapRecoveryTests.swift",
];
const main = fs.readFileSync(mainPath, "utf8");
const session = fs.readFileSync(sessionPath, "utf8");
const sessionTests = fs.readFileSync(sessionTestsPath, "utf8");
const authority = fs.readFileSync(authorityPath, "utf8");
// ChatPageModel.swift was split into topic files (2026-09-02); read the family.
const chatModel = fs
  .readdirSync(path.dirname(chatModelPath))
  .filter((name) => name === "ChatPageModel.swift" || name.startsWith("ChatPageModel+"))
  .sort()
  .map((name) => fs.readFileSync(path.join(path.dirname(chatModelPath), name), "utf8"))
  .join("\n");
const appBootstrap = fs.readFileSync(appBootstrapPath, "utf8");
const appShell = fs.readFileSync(appShellPath, "utf8");

function sliceBalanced(source, startMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `missing source marker: ${startMarker}`);
  let depth = 0;
  let seenStart = false;
  for (let i = start; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === "(") {
      depth += 1;
      seenStart = true;
    } else if (ch === ")") {
      depth -= 1;
      if (seenStart && depth === 0) {
        return source.slice(start, i + 1);
      }
    }
  }
  assert.fail(`unbalanced call starting at ${startMarker}`);
}

const sessionOffset = main.indexOf('case "session":');
assert.notEqual(sessionOffset, -1, "os session command must remain discoverable");
const sessionSurface = main.slice(sessionOffset, sessionOffset + 12_000);
const startCase = sessionSurface.match(
  /case "start":([\s\S]*?)case "status":/,
)?.[1];
assert.ok(startCase, "os session start case must remain discoverable");

assert.match(
  startCase,
  /if args\.contains\("--initialize-authority-locks"\) \{[\s\S]*?bootstrapFormalWorkOSAuthorityLocksOnly/,
  "authority-lock bootstrap must be an explicit terminal CLI branch",
);
assert.match(
  startCase,
  /\} else \{[\s\S]*?beginFormalWorkOSSession/,
  "bootstrap and begin must be mutually exclusive in one invocation",
);
assert.doesNotMatch(
  startCase,
  /bootstrapFormalWorkOSAuthorityLocksOnly[\s\S]*?beginFormalWorkOSSession[\s\S]*?bootstrapFormalWorkOSAuthorityLocksOnly/,
  "bootstrap branch must not fall through into begin",
);

const formalBegin = main.match(
  /static func beginFormalWorkOSSession\(([\s\S]*?)\n  static func bootstrapFormalWorkOSAuthorityLocksOnly/,
)?.[1] ?? "";
assert.ok(formalBegin, "formal begin helper must remain source-auditable");
assert.match(formalBegin, /requiredCanonicalSessionOwner\(in: args\)/);
const canonicalOwnerParser = main.match(
  /static func requiredCanonicalSessionOwner\(([\s\S]*?)\n  \}\n\n  \/\//,
)?.[1] ?? "";
assert.ok(
  canonicalOwnerParser,
  "canonical owner parser must remain source-auditable",
);
assert.match(
  canonicalOwnerParser,
  /requiredOption\("--provider", in: args\)/,
);
assert.match(
  canonicalOwnerParser,
  /requiredExactlyOneOption\(\s*\["--owner-session", "--owner-thread"\]/,
);
assert.match(
  canonicalOwnerParser,
  /requiredOption\("--workspace", in: args\)/,
);
assert.match(canonicalOwnerParser, /isAbsolutePath/);
assert.match(canonicalOwnerParser, /TatwoCanonicalSessionOwnerV1\(/);
assert.match(canonicalOwnerParser, /\.thread\(ownerSelection\.value\)/);
assert.match(canonicalOwnerParser, /\.session\(ownerSelection\.value\)/);
assert.match(formalBegin, /WorkOSFactory\.beginCanonical\(/);
assert.match(formalBegin, /store: goalStore/);
assert.match(formalBegin, /registry: dispatchRegistry/);
assert.match(formalBegin, /sessionStore: sessionStore/);
assert.match(formalBegin, /owner: owner/);
assert.doesNotMatch(
  formalBegin,
  /bootstrapExplicitly|initializeSessionAuthorityLocksCreateOnly/,
  "ordinary session writer must not bootstrap authority locks implicitly",
);

const bootstrapOnly = main.match(
  /static func bootstrapFormalWorkOSAuthorityLocksOnly\(([\s\S]*?)\n  static func scenarioConfigModels/,
)?.[1] ?? "";
assert.ok(bootstrapOnly, "bootstrap-only helper must remain discoverable");
assert.match(bootstrapOnly, /WorkOSFactory\.projectContract\(/);
assert.match(bootstrapOnly, /initializeSessionAuthorityLocksCreateOnly\(/);
assert.doesNotMatch(bootstrapOnly, /beginCanonical|beginCurrent/);

assert.match(
  main,
  /static func initializeSessionAuthorityLocksCreateOnly\([\s\S]*?TatwoSessionAuthorityLockBootstrap\.bootstrapExplicitly/,
);
assert.doesNotMatch(
  main.match(
    /static func initializeSessionAuthorityLocksCreateOnly\([\s\S]*?\n  \}/,
  )?.[0] ?? "",
  /TatwoGoalStore(Global|Lifecycle)Lock\.initializeCreateOnly/,
  "CLI must delegate to the one shared Core bootstrap primitive",
);

const bootstrapOffset = authority.indexOf(
  "public enum TatwoSessionAuthorityLockBootstrap",
);
assert.notEqual(bootstrapOffset, -1);
const bootstrapSurface = authority.slice(bootstrapOffset, bootstrapOffset + 16_000);
assert.match(
  bootstrapSurface,
  /withRootBootstrapFence\(root: root\)/,
  "execution-time preflight must be fenced by the existing root directory",
);
assert.match(
  bootstrapSurface,
  /expectedPreflight != authoritativePreflight[\s\S]*?preflightChanged/,
  "stale human preflight must fail inside the root-scoped fence",
);
assert.match(bootstrapSurface, /let allAbsent = present\.isEmpty/);
assert.match(
  bootstrapSurface,
  /let allComplete = present == expectedNameSet/,
);
assert.match(
  bootstrapSurface,
  /let legacyLifecycleDirectoryOnly =[\s\S]*?present == Set\(\[lifecycleDirectoryName\]\)/,
  "the exact legacy lifecycle-directory-only state must be identified separately",
);
const preflightGuardOffset = bootstrapSurface.indexOf(
  "allAbsent || allComplete || legacyLifecycleDirectoryOnly",
);
const globalCreateOffset = bootstrapSurface.indexOf(
  "TatwoGoalStoreGlobalLock.initializeCreateOnly",
);
assert.ok(
  preflightGuardOffset >= 0 && preflightGuardOffset < globalCreateOffset,
  "all global/lifecycle artifacts must be preflighted before the first create",
);
assert.match(
  bootstrapSurface,
  /else if legacyLifecycleDirectoryOnly \{[\s\S]*?TatwoGoalStoreGlobalLock\.initializeCreateOnly[\s\S]*?TatwoGoalStoreLifecycleLock\.initializeContractCreateOnly[\s\S]*?createdGlobalAndContractLifecycle/,
  "legacy migration must preserve the existing lifecycle directory while creating only the missing global and requested-contract artifacts",
);
assert.match(
  bootstrapSurface,
  /guard[\s\S]*?allAbsent \|\| allComplete \|\| legacyLifecycleDirectoryOnly[\s\S]*?\|\| globalCompleteContractLifecycleAbsent[\s\S]*?mixedOrPartialState/,
  "every state outside the exact supported create, validation, and legacy migration shapes must remain fail closed",
);
assert.match(
  bootstrapSurface,
  /TatwoGoalStoreGlobalLock\.withExclusiveLock[\s\S]*?TatwoGoalStoreLifecycleLock\.withExclusiveLock/,
  "complete existing artifacts require existing-only validation",
);
assert.match(
  bootstrapSurface,
  /open\([\s\S]*?O_DIRECTORY \| O_NOFOLLOW \| O_CLOEXEC[\s\S]*?flock\(descriptor, LOCK_EX\)/,
  "bootstrap fence must lock the existing state-root directory without creating a fifth lock artifact",
);

assert.match(
  appBootstrap,
  /final class TatwoAppAuthorityBootstrapModel: ObservableObject/,
);
assert.match(
  appBootstrap,
  /let owner: TatwoCanonicalSessionOwnerV1/,
  "the staged App proposal must retain the exact canonical owner kind",
);
assert.match(
  appBootstrap,
  /confirmed\.proposal\.authoritySubjectDigest[\s\S]*?== proposal\.authoritySubjectDigest[\s\S]*?confirmed\.readback\.canonicalGoalStoreRootPath[\s\S]*?== proposal\.canonicalGoalStoreRootPath[\s\S]*?confirmed\.readback\.contractID == proposal\.contractID[\s\S]*?confirmed\.readback\.validatedPreflight == proposal\.preflight/,
  "confirmation/readback matching must bind the canonical owner-bearing subject digest plus exact root, contract, and preflight",
);
const confirmStart = appBootstrap.indexOf("func confirmPending() async {");
const confirmEnd = appBootstrap.indexOf("    #if DEBUG", confirmStart);
assert.ok(
  confirmStart >= 0 && confirmEnd > confirmStart,
  "App authority confirmation surface must remain discoverable",
);
const confirmSurface = appBootstrap.slice(confirmStart, confirmEnd);
assert.equal(
  [...confirmSurface.matchAll(/\.bootstrapExplicitly\(/g)].length,
  2,
  "App human confirmation must perform a fresh second readback",
);
assert.match(confirmSurface, /expectedPreflight:\s*proposal\.preflight/);
assert.match(
  confirmSurface,
  /expectedPreflight:\s*first\.validatedPreflight/,
);
assert.match(
  appBootstrap,
  /guard readback\.disposition == \.validatedExisting/,
);
assert.match(
  appShell,
  /Button\("檢查並初始化"\)[\s\S]*?showsAuthorityBootstrapConfirmation = true/,
);
assert.match(
  appShell,
  /\.confirmationDialog\([\s\S]*?await authorityBootstrapModel\.confirmPending\(\)/,
);

const productionBeginOffset = chatModel.indexOf(
  "let attachment = try sessionStore.beginCurrent(",
);
assert.notEqual(productionBeginOffset, -1);
const productionBeginSurface = chatModel.slice(
  Math.max(0, productionBeginOffset - 4_000),
  productionBeginOffset + 2_000,
);
assert.match(
  productionBeginSurface,
  /guard let canonicalOwner else/,
);
assert.match(
  productionBeginSurface,
  /TatwoAppAuthorityBootstrapProposalV1\(/,
);
assert.match(
  productionBeginSurface,
  /TatwoSessionAuthorityLockBootstrap\.preflightSnapshot/,
);
assert.match(
  productionBeginSurface,
  /authorityBootstrapModel\.consumeConfirmedReadback/,
);
assert.match(productionBeginSurface, /owner: canonicalOwner/);
assert.match(productionBeginSurface, /goalStore: goalRunStore/);
assert.match(productionBeginSurface, /dispatchRegistry: dispatchRegistry/);
assert.doesNotMatch(
  productionBeginSurface,
  /bootstrapExplicitly|initializeCreateOnly/,
  "Chat /goal flow may stage/consume confirmation but must not bootstrap",
);

for (const relativePath of formalCallerPaths) {
  const source = fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
  assert.match(
    source,
    /TatwoSessionAuthorityLockBootstrap\.bootstrapExplicitly/,
    `${relativePath} must explicitly bootstrap its isolated fixture root`,
  );
  for (let index = source.indexOf(".beginCurrent("); index !== -1; ) {
    const call = sliceBalanced(source.slice(index), ".beginCurrent(");
    assert.match(call, /owner:/, `${relativePath} beginCurrent missing owner`);
    assert.match(
      call,
      /dispatchRegistry:/,
      `${relativePath} beginCurrent missing same-root registry`,
    );
    index = source.indexOf(".beginCurrent(", index + call.length);
  }
}
const historicalSource = fs.readFileSync(
  path.join(
    repoRoot,
    "Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/GoalRevisionChatRebindTests.swift",
  ),
  "utf8",
);
assert.match(
  historicalSource,
  /beginHistoricalCurrentForMigrationTest[\s\S]*?production `beginCurrent`[\s\S]*?TatwoSessionPointerV1[\s\S]*?TatwoSessionPointerV2/,
);
const lifecycleLock = fs.readFileSync(
  path.join(
    repoRoot,
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalStoreLifecycleLock.swift",
  ),
  "utf8",
);
assert.match(
  lifecycleLock,
  /globalInitializationReceiptSHA256[\s\S]*?reason: "global_lock_binding"/,
  "lifecycle receipt must bind the exact global receipt hash and lock identity",
);

assert.match(session, /owner: TatwoCanonicalSessionOwnerV1,/);
assert.doesNotMatch(
  session.match(/public func beginCurrent\(([\s\S]*?)\) throws/)?.[1] ?? "",
  /owner: TatwoSessionOwnerExpectationV1\?|owner: .* = nil/,
);
assert.match(
  session,
  /this route never bootstraps or[\s/]*repairs authority locks implicitly/,
);
assert.match(
  sessionTests,
  /testBeginCurrentRejectsEmptyTypedOwnerBeforeCreatingArtifacts/,
);
assert.match(
  sessionTests,
  /testBeginCurrentRejectsMissingAuthorityLocksWithoutImplicitBootstrap/,
);
assert.match(
  sessionTests,
  /testBeginCurrentPublishesOneCanonicalGoalAndPointerAttachment[\s\S]*?TatwoSessionAuthorityPointerV3/,
);
assert.match(
  sessionTests,
  /beginHistoricalV2CurrentForMutationTest[\s\S]*?TatwoSessionPointerV2/,
);

console.log("tatwo-session-start-cli-source-contract: PASS");
