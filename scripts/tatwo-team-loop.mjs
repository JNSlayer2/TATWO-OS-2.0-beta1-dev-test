#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = parseArgs(process.argv.slice(2));
const mode = String(args.mode ?? "M").toUpperCase();
const scenario = String(args.scenario ?? "coding");
const objective = String(args.objective ?? "Tatwo team loop dry-run");

const recommendation = runCLI(["teams", "recommend", "--mode", mode, "--scenario", scenario, "--json"]);
const workflow = runCLI(["workflow", "run", "--mode", mode, "--scenario", scenario, "--objective", objective, "--dry-run", "--json"]);
const stability = runCLI(["integration", "stability", "--json"]);
const traits = runCLI(["teams", "traits", "--json"]);

const selectedTeams = [
  recommendation.data?.primaryTeam,
  ...(recommendation.data?.supportingTeams ?? [])
].filter(Boolean);
const selectedModelIDs = new Set(selectedTeams.flatMap(team => (team.members ?? []).map(member => member.modelID)));
const modelTraitSummary = (traits.data ?? [])
  .filter(trait => selectedModelIDs.has(trait.id))
  .map(trait => ({
    id: trait.id,
    displayName: trait.displayName,
    plainSummary: trait.plainSummary,
    plainFailureMode: trait.plainFailureMode,
    verificationRule: trait.verificationRule,
    bestRoles: trait.bestRoles,
    avoidRoles: trait.avoidRoles,
    calibrationNotes: trait.calibrationNotes,
    scores: trait.scores,
    defaultAuthority: trait.defaultAuthority,
    canDirectlyMutateHost: trait.canDirectlyMutateHost
  }));

const packet = {
  schema: "TatwoTeamLoopPacketV1",
  mode,
  scenario,
  objective,
  hostMutationAllowed: false,
  sandboxFirst: ["L", "XL"].includes(mode) || recommendation.data?.primaryTeam?.id === "stability-team",
  primaryTeam: recommendation.data?.primaryTeam?.chineseName ?? recommendation.data?.primaryTeam?.id,
  teamIDs: selectedTeams.map(team => team.id),
  modelTraitSummary,
  roleBoundaries: recommendation.data?.primaryTeam?.roleBoundaries?.map(boundary => ({
    roleName: boundary.roleName,
    owner: boundary.owner,
    canDo: boundary.canDo,
    cannotDo: boundary.cannotDo,
    evidenceBeforePass: boundary.evidenceBeforePass
  })) ?? [],
  workflowLoops: recommendation.data?.workflowLoops?.map(loop => ({
    id: loop.id,
    title: loop.title,
    steps: loop.plainSteps,
    scriptsOrCommands: loop.scriptsOrCommands,
    sandboxPolicy: loop.sandboxPolicy,
    stopCondition: loop.stopCondition,
    requiredReceipts: loop.requiredReceipts
  })) ?? [],
  requiredGates: recommendation.data?.requiredGates ?? [],
  stabilityGuardIDs: stability.data?.guards?.map(guard => guard.id) ?? [],
  dryRunPlanID: workflow.data?.planID,
  receipts: [
    "This script is dry-run only.",
    "External models may suggest brain/patch intent only.",
    "Codex executor remains the only host mutation authority."
  ]
};

console.log(JSON.stringify(packet, null, 2));

function runCLI(cliArgs) {
  const result = spawnSync("swift", ["run", "--package-path", repoRoot, "tatwo-ultrawork", ...cliArgs], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024
  });
  if (result.status !== 0) {
    throw new Error(`tatwo-ultrawork ${cliArgs.join(" ")} failed:\n${result.stdout}\n${result.stderr}`);
  }
  return JSON.parse(result.stdout);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const inline = arg.indexOf("=");
    if (inline >= 0) {
      out[arg.slice(2, inline)] = arg.slice(inline + 1);
    } else {
      out[arg.slice(2)] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
    }
  }
  return out;
}
