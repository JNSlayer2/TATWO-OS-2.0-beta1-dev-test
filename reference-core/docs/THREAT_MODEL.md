# Threat Model

## Protected assets

Provider credentials and sessions, source repositories, user files, browser state, device identity, private prompts, reports, and deployment authority.

## Primary threats

- Accidental publication of local paths, account identifiers, logs, fixtures, Git history, or secrets.
- Prompt or tool input escaping the selected working root.
- A provider adapter inheriting another provider's configuration or credentials.
- Arbitrary shell execution hidden behind a friendly collaboration command.
- Public TCP listeners, unauthenticated local sockets, symlink traversal, or world-readable runtime files.
- Treating a running process, generated report, or merged text as verified success.
- Dependency or workflow code gaining mutation authority during install or test.

## Public-package controls

- No runtime dependencies and no lifecycle install scripts.
- Dry-run only; no process spawning, shell execution, networking, sockets, worktree creation, or credential discovery.
- Strict schemas with unknown-field rejection and bounded input sizes.
- Canonical-path checks require an explicit allowed root and reject traversal.
- Synthetic tests only.
- The bundled scanner is a small tripwire for symlinks, binaries, large files, selected secret markers, private absolute paths, account-like identifiers, and sensitive artifact directories. It is not a complete secret scanner and never replaces an independent tool plus human review.
- The 2.0 source tree starts from a fresh public root with no private repository history or metadata.

## Residual risk

A downstream integrator can add unsafe authority. No in-process validator can defend against code running with the same user privileges and intentionally bypassing it. Production safety therefore also requires operating-system permissions, isolated accounts or sandboxes, secure secret storage, authenticated owner-only IPC, audit logs, and human approval for irreversible actions.
