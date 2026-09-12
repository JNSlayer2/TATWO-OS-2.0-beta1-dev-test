import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const mcp = fs.readFileSync(
  path.join(
    repoRoot,
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/MCPFramework.swift"),
  "utf8");
const cli = fs.readFileSync(
  path.join(
    repoRoot,
    "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/main.swift"),
  "utf8");
const recoveryCLI = fs.readFileSync(
  path.join(
    repoRoot,
    "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/GoalRevisionRecoveryCLI.swift"),
  "utf8");
const rootAdminEnrollment = fs.readFileSync(
  path.join(
    repoRoot,
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/GoalRevisionRootAdminEnrollment.swift"),
  "utf8");

function between(source, start, end) {
  const startIndex = source.indexOf(start);
  assert.notEqual(startIndex, -1, `missing source marker: ${start}`);
  const endIndex = source.indexOf(end, startIndex + start.length);
  assert.notEqual(endIndex, -1, `missing source marker: ${end}`);
  return source.slice(startIndex, endIndex);
}

test("MCP exposes canonical revise as consume-only and no authorization issuer", () => {
  const definition = between(
    mcp,
    'name: "tatwo.os.session.revise"',
    'name: "tatwo.os.next"');
  assert.match(definition, /requiredArguments: \["authorizationID"\]/);
  assert.match(definition, /只能消費可信 human-gate issuer 已核發/);
  assert.match(definition, /不簽發任何 App／host／recovery 授權/);
  assert.match(definition, /human_gate_unavailable/);
  assert.match(definition, /TatwoGoalRevisionPromotionResultV1/);

  const call = between(
    mcp,
    'case "tatwo.os.session.revise":',
    'case "tatwo.os.next":');
  assert.match(call, /transitionCurrentToPlannedRevision/);
  assert.match(call, /authorizationID: authorizationID/);
  assert.match(call, /missing_required:authorizationID/);
  assert.match(mcp, /"tatwo_os_session_revise": "tatwo\.os\.session\.revise"/);

  for (const forbidden of [
    "issueHumanGate",
    "issuePromotion",
    "issueHostOperation",
    "issueHostApproval",
  ]) {
    assert.doesNotMatch(mcp, new RegExp(`name: "${forbidden}`));
    assert.doesNotMatch(mcp, new RegExp(`name: "tatwo\\.[^"]*${forbidden}`, "i"));
  }
  for (const forbidden of [
    "TatwoGoalRevisionBootstrapRecoveryIssuer",
    "authorizeAfterBootstrapRecovery",
    "TatwoBootstrapRecoveryHost",
    "host.tatwo.ultrawork.user-instruction-recovery",
  ]) {
    assert.doesNotMatch(mcp, new RegExp(forbidden.replaceAll(".", "\\."), "i"));
    assert.doesNotMatch(cli, new RegExp(forbidden.replaceAll(".", "\\."), "i"));
  }
});

test("CLI and MCP exchange an App-issued revision host authorization without minting it", () => {
  const definition = between(
    mcp,
    'name: "tatwo.host.authorize_revision"',
    'name: "tatwo.host.read_file"');
  assert.match(definition, /requiredArguments: \["authorizationID"\]/);
  assert.match(definition, /消費 App 已核發/);
  assert.match(definition, /不簽發人類授權/);
  assert.match(definition, /TatwoHostApprovalLeaseV1/);

  const call = between(
    mcp,
    'case "tatwo.host.authorize_revision":',
    'case "tatwo.host.read_file":');
  assert.match(call, /issueHostOperationBound/);
  assert.match(call, /TatwoSessionStore\.default/);
  assert.match(mcp, /"tatwo_host_authorize_revision": "tatwo\.host\.authorize_revision"/);

  const host = between(
    cli,
    "static func handleHost",
    "static func handleComputer");
  assert.match(host, /case "authorize-revision":/);
  assert.match(host, /requiredOption\("--authorization"/);
  assert.match(host, /issueHostOperationBound/);
  assert.doesNotMatch(host, /authorizeAfterHumanConfirmation/);
});

test("MCP begin cannot repair current session and attach remains exact rehydrate", () => {
  const beginDefinition = between(
    mcp,
    'name: "tatwo.os.begin"',
    'name: "tatwo.os.session.attach"');
  assert.match(beginDefinition, /不接受 existing ID/);
  assert.doesNotMatch(beginDefinition, /contractID|goalID/);

  const attachCall = between(
    mcp,
    'case "tatwo.os.session.attach":',
    'case "tatwo.os.session.revise":');
  assert.match(attachCall, /let provider = nonemptyStringArg\("provider"/);
  assert.match(attachCall, /workspace\.hasPrefix\("\/"\)/);
  assert.match(
    attachCall,
    /\(ownerSession == nil\) != \(ownerThread == nil\)/);
  assert.doesNotMatch(attachCall, /ownerSession\s*\?\?\s*""/);
  assert.doesNotMatch(attachCall, /ownerThread\.map/);
  assert.match(attachCall, /TatwoCanonicalSessionOwnerV1\(/);
  assert.match(
    attachCall,
    /ownerVerification: \.canonicalV3\(canonicalOwner\)/);
  assert.match(attachCall, /attachCurrent/);
  assert.match(attachCall, /expectedContractID/);
  assert.match(attachCall, /expectedGoalID/);
  assert.doesNotMatch(attachCall, /legacyV2|TatwoSessionOwnerExpectationV1/);
  assert.doesNotMatch(attachCall, /WorkOSFactory\.begin/);
  assert.doesNotMatch(attachCall, /beginCurrent/);
});

test("CLI help and parser expose revise while start and stop use safe session APIs", () => {
  assert.match(
    cli,
    /tatwo-ultrawork os session revise --authorization <externally-issued-id> --json/);
  assert.match(cli, /"authorization": "authorizationID"/);

  const session = between(
    cli,
    'case "session":',
    "\n    default:\n      throw CLIError.usage(");
  for (const subcommand of [
    '"start"',
    '"status"',
    '"attach"',
    '"revise"',
    '"revision-recovery-plan"',
    '"revision-recovery-enroll"',
    '"stop"',
  ]) {
    assert.match(session, new RegExp(subcommand));
  }
  assert.match(session, /case "start":[\s\S]*beginFormalWorkOSSession/);
  assert.doesNotMatch(
    between(session, 'case "start":', 'case "status":'),
    /WorkOSFactory\.begin|sessionStore\.save/);

  const attach = between(session, 'case "attach":', 'case "revise":');
  assert.match(attach, /requiredCanonicalSessionOwner\(in: args\)/);
  assert.match(
    attach,
    /ownerVerification: \.canonicalV3\(owner\)/);
  assert.doesNotMatch(attach, /legacyV2|expectedOwner/);

  const revise = between(session, 'case "revise":', "\n      default:");
  assert.match(revise, /requiredOption\("--authorization"/);
  assert.match(revise, /transitionCurrentToPlannedRevision/);
  assert.match(revise, /attachCurrent/);
  assert.match(revise, /TatwoSessionRevisionCLIOutputV1/);

  const stop = session.slice(session.indexOf("\n      default:"));
  assert.match(stop, /requiredCanonicalSessionOwner\(in: args\)/);
  assert.match(stop, /sessionStore\.stopCurrent/);
  assert.match(
    stop,
    /ownerVerification: \.canonicalV3\(owner\)/);
  assert.doesNotMatch(stop, /sessionStore\.clear/);

  const recoveryPlan = between(
    recoveryCLI,
    "static func preparePlan",
    "\n}");
  const recoveryEnroll = between(
    recoveryCLI,
    "static func enroll",
    "static func preparePlan");
  for (const command of [recoveryPlan, recoveryEnroll]) {
    assert.match(command, /args\.contains\("--help"\)/);
    assert.match(command, /args\.contains\("-h"\)/);
    assert.ok(
      command.indexOf('args.contains("--help")')
        < command.indexOf("requiredAnyOption"),
      "nested help must return before required-option parsing");
  }
});

test("bootstrap recovery plan is explicitly untrusted until fresh root-admin review", () => {
  assert.match(recoveryCLI, /let candidateOnly = true/);
  assert.match(recoveryCLI, /let callerSuppliedEvidenceTrusted = false/);
  assert.match(recoveryCLI, /let trustedHumanConfirmationPresent = false/);
  assert.match(recoveryCLI, /let readyForFreshAdminEnrollment = false/);
  assert.match(recoveryCLI, /let requiresFreshRootAdminInteractiveReview = true/);
  assert.match(recoveryCLI, /let adminMustRereadSourceFiles = true/);
  assert.match(recoveryCLI, /humanMessageSourcePath/);
  assert.match(recoveryCLI, /legacyUnavailableEvidenceSourcePath/);
  assert.match(recoveryCLI, /canonicalCurrentSession/);
  assert.match(recoveryCLI, /canonicalPredecessorGoal/);
  assert.match(recoveryCLI, /canonicalSuccessorGoal/);
  assert.match(recoveryCLI, /DO NOT write this candidate yet/);
  assert.match(recoveryCLI, /reopen the two source files without following symlinks/);
  assert.match(recoveryCLI, /display and review their complete UTF-8/);
  assert.match(recoveryCLI, /grant file digest and short code through/);
  assert.match(recoveryCLI, /\/dev\/tty/);
});

test("root-admin enrollment is fixed-root, interactive, create-only, and enrollment-only", () => {
  const realProcessConstructor = /\bProcess\s*\(\s*\)/;
  assert.match(
    "let child = Process()",
    realProcessConstructor,
    "the source guard must continue rejecting a real Process constructor");
  assert.match(
    cli,
    /os session revision-recovery-enroll --successor <planned-contract-id>/);
  assert.match(recoveryCLI, /static func enroll\(_ args: \[String\]\) throws/);
  assert.match(
    recoveryCLI,
    /TatwoGoalRevisionRootAdminEnrollment\.enrollProduction/);
  const enrollmentCLI = between(
    recoveryCLI,
    "static func enroll",
    "static func preparePlan");
  assert.match(enrollmentCLI, /humanMessageSourcePath: humanMessageFile/);
  assert.match(
    enrollmentCLI,
    /legacyUnavailableEvidenceSourcePath: legacyEvidenceFile/);
  assert.doesNotMatch(enrollmentCLI, /standardizedFileURL|resolvingSymlinksInPath/);

  assert.match(rootAdminEnrollment, /Darwin\.geteuid\(\) == 0/);
  assert.match(rootAdminEnrollment, /environment\["SUDO_UID"\]/);
  assert.match(rootAdminEnrollment, /Darwin\.getpwuid\(localUID\)/);
  assert.match(rootAdminEnrollment, /"Library"[\s\S]*"Application Support"[\s\S]*"Tatwo Ultrawork"[\s\S]*"state"/);
  assert.match(rootAdminEnrollment, /"\/dev\/tty"/);
  assert.match(rootAdminEnrollment, /O_RDONLY \| O_NOFOLLOW \| O_CLOEXEC/);
  assert.match(rootAdminEnrollment, /O_RDWR \| O_CREAT \| O_EXCL \| O_NOFOLLOW \| O_CLOEXEC/);
  assert.match(rootAdminEnrollment, /status\.st_nlink == 1/);
  assert.match(rootAdminEnrollment, /Darwin\.fchown/);
  assert.match(rootAdminEnrollment, /Darwin\.fchmod\(fileFD, 0o444\)/);
  assert.match(rootAdminEnrollment, /Darwin\.fsync\(fileFD\)/);
  assert.match(rootAdminEnrollment, /confirmation == first\.prepared\.plan\.evidence\.shortCode/);
  assert.match(rootAdminEnrollment, /guard first == second/);
  assert.match(rootAdminEnrollment, /goalMutationPerformed: false/);
  assert.match(rootAdminEnrollment, /grantConsumed: false/);
  assert.match(rootAdminEnrollment, /authorizationCreated: false/);
  assert.doesNotMatch(
    rootAdminEnrollment,
    /transitionCurrentToPlannedRevision|acceptRootOwnedGrantEvidence|authorizeAfterBootstrapRecovery/);
  assert.doesNotMatch(
    rootAdminEnrollment,
    new RegExp(
      `${realProcessConstructor.source}|posix_spawn|/usr/bin/sudo|/usr/bin/osascript`));
});
