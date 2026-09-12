---
name: tatwo-ultrawork
description: Portable public workflow for goal-first, bounded, multi-engine collaboration with honest verification and no implicit host authority.
---

# TATWO Ultrawork — Public Portable Edition

## Activation

Use when the user explicitly asks for TATWO Ultrawork, multi-engine rooms, lead/worker/reviewer coordination, or a goal-first collaboration loop.

State the actual surface:

- `Public workflow active` when only this skill is available.
- `Runtime connected` only when an independently configured host adapter is verifiably reachable.
- Never imply that this skill grants process, filesystem, network, credential, deployment, or device authority.

## Workflow

1. **Goal** — restate the desired outcome, success evidence, non-goals, constraints, and protected surfaces.
2. **Context** — inspect the smallest relevant evidence. Separate known facts, assumptions, contradictions, and inaccessible facts.
3. **Plan** — name the files or surfaces to touch, verification method, rollback, and human gates. Do not operationalize before context is sufficient.
4. **Loops** — use the fewest bounded workers needed. Every room receives a title, role, working root, brief, acceptance evidence, and stop condition.
5. **Review** — a different identity critiques the result. Review is advisory and cannot self-approve.
6. **Verify** — the lead reruns applicable checks, inspects primary artifacts, compares each success criterion, and reports missing evidence.
7. **Close** — distinguish completed, blocked, failed, skipped, and unverified work.

## Safety defaults

- Preview and read-only discovery come first.
- Provider adapters, credentials, sessions, host mutation, network access, installations, background services, deployment, device control, secrets, destructive actions, and live financial actions are outside this public skill.
- Never discover or inherit another provider's configuration automatically.
- Reject paths outside the explicitly allowed working root; treat symlinks as a separate trust decision.
- Do not place secrets, personal paths, account identifiers, browser state, private prompts, real receipts, or real project fixtures into shareable artifacts.
- A process being alive, a worker saying “done,” a generated report, or merged report text is not acceptance evidence.
- If the runtime or authority boundary is unclear, stop at a plan or preview and label the missing proof.

## Room brief

Each room brief must contain:

- objective and why it matters;
- exact scope and excluded surfaces;
- allowed working root;
- permitted operations;
- required evidence;
- stop conditions and escalation path.

Workers do not expand their own scope. Host integrations must isolate workspaces and terminate child processes; this skill does not implement those controls.

## Deletion and irreversible actions

Do not perform destructive deletion by default. Prefer reversible archival and describe restoration. Authentication changes, releases, deployments, branch replacement, remote pushes, live orders, and other irreversible external effects require a separate explicit user gate.

## Evidence language

Use precise states:

- `started` is not `completed`;
- `completed` is not `verified`;
- `merged report` is not `merged code`;
- `tests passed` covers only the tests actually run;
- `skipped` is visible and never counted as passed.

Read `references/public-contract.md` and `references/security-boundary.md` before connecting a runtime adapter. Run `node scripts/selftest.mjs` after changing this skill.
