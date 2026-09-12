import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const repo = path.resolve(import.meta.dirname, "..");
const cli = fs.readFileSync(
  path.join(repo, "Tools/TatwoUltraworkCLI/Sources/TatwoUltraworkCLI/RemoteRunnerCLI.swift"),
  "utf8",
);
const wrapper = fs.readFileSync(path.join(repo, "scripts/tatwo-remote-runner.sh"), "utf8");
const channelSync = fs.readFileSync(
  path.join(repo, "scripts/tatwo-remote-channel-sync.sh"),
  "utf8",
);
const protocol = fs.readFileSync(
  path.join(repo, "docs/protocol/REMOTE_COMPUTE_FLEET_V1.md"),
  "utf8",
);

test("remote runner exposes target readiness publication", () => {
  assert.match(cli, /case "readiness":\s+try readiness\(args\)/);
  assert.match(cli, /remote-runner readiness publish/);
  assert.match(cli, /TatwoRemoteDispatchReadinessTargetSnapshotBuilderV1\.build/);
  assert.match(cli, /TatwoRemoteDispatchReadinessRegistryStoreV1\.production/);
  assert.match(cli, /readinessChannelManifestURL/);
  assert.match(cli, /channelManifestPath:/);
  assert.match(cli, /writeReadinessManifest/);
  assert.match(channelSync, /readiness\/manifests/);
  assert.match(
    channelSync,
    /local -a pull_dirs=\([\s\S]*readiness\/manifests[\s\S]*?\n  \)/,
  );
  assert.doesNotMatch(
    channelSync.match(/local -a push_dirs=\([\s\S]*?\n  \)/)?.[0] ?? "",
    /readiness\/manifests/,
  );
  assert.match(wrapper, /start\|seal-install\|readiness\|dispatch/);
  assert.match(protocol, /Target readiness publication/);
});

test("production tatwo-loop dispatch binds manifest, session, grant, and exact route", () => {
  assert.match(cli, /--readiness-manifest/);
  assert.match(cli, /--session-id/);
  assert.match(cli, /--grant-id/);
  assert.match(cli, /--model-route/);
  assert.match(cli, /TatwoRemoteBorrowInvocationV1/);
  assert.match(cli, /manifest\.binding\(challengeNonce: challengeNonce\)/);
  assert.match(
    cli,
    /TatwoRemoteWorkspaceLocatorV1\([\s\S]*workspaceBindingID:\s*manifest\.workspaceBindingID,[\s\S]*registryGeneration:\s*manifest\.registryGeneration/,
  );
  assert.match(cli, /workspaceLocator:\s*workspaceLocator/);
  assert.match(cli, /workPath\s*=\s*""/);
  assert.match(cli, /targetReadinessManifest: targetReadinessManifest/);
  assert.match(cli, /isRegularFileKey/);
  assert.match(cli, /isSymbolicLinkKey/);
  assert.match(protocol, /Shell-safe[\s\S]*separate path/);
});

test("portable manifest contract does not serialize target-local path fields", () => {
  const manifestSection = cli.slice(
    cli.indexOf("private static func writeReadinessManifest"),
    cli.indexOf("private static func readReadinessManifest"),
  );
  assert.doesNotMatch(manifestSection, /canonicalWorkspacePath/);
  assert.doesNotMatch(manifestSection, /executablePin/);
  assert.doesNotMatch(manifestSection, /skilletRoot/);
  assert.match(protocol, /must not contain the target workspace\s+path/);
});

test("fleet agent queue preserves target authorization and reloads sealed readiness", () => {
  assert.match(
    cli,
    /remote-runner fleet dispatch tatwo-loop requires --agent and --model-route/,
  );
  assert.match(cli, /"--target-device-id", in: args/);
  assert.match(cli, /remoteDispatchReadiness = manifest\.binding/);
  assert.match(cli, /remoteBorrowInvocation:\s*remoteBorrowInvocation/);
  assert.match(cli, /remoteDispatchReadiness:\s*remoteDispatchReadiness/);
  assert.match(cli, /workspaceLocator:\s*workspaceLocator/);
  assert.match(
    cli,
    /case let \.tatwoLoop\(loop\):[\s\S]*readinessChannelManifestURL\([\s\S]*let manifest = try readReadinessManifest[\s\S]*targetReadinessManifest = manifest/,
  );
  assert.match(
    cli,
    /manifest\.validateCurrentProductionAgentBinding\([\s\S]*for:\s*job,[\s\S]*trust:\s*boot\.channel\.trust/,
  );
  assert.match(
    cli,
    /currentOriginLease:\s*currentOriginLease,\s*targetReadinessManifest:\s*targetReadinessManifest/,
  );
  assert.match(protocol, /Production fleet agent jobs are target-bound/);
  assert.match(protocol, /fresh readiness challenge/);
  assert.match(protocol, /must not rewrite a grant for another device/);
});
