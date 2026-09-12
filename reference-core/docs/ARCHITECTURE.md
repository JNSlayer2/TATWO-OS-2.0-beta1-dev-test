# Architecture

## Public reference layers

1. **Thread layer** — a discussion owns the goal, plan, messages, engine binding, and evidence references.
2. **Sidecar boundary** — each engine adapter exchanges newline-delimited JSON over standard input/output. The public protocol normalizes lifecycle and permission events but contains no vendor login logic.
3. **Room layer** — the lead prepares bounded room briefs. A real host may map rooms to isolated worktrees, but this package only validates and previews them.
4. **Monitor layer** — liveness, pressure, and scope-drift signals are observations, never proof of completion.
5. **Verification layer** — the lead compares outputs with the original goal and reruns applicable checks. A reviewer is advisory and must not self-approve.

## Event protocol

App to adapter operations: `send`, `permission`, `interrupt`, `model`, `status`, `close`.

Adapter to app events: `init`, `text_delta`, `tool_use`, `tool_result`, `permission_request`, `result`, `stderr`, `error`, `closed`.

Every message is one JSON object on one line. Unknown operations and extra fields are rejected. Permission defaults to denied. The public core never launches an adapter.

## What integrators must provide

A production host must separately implement process supervision, engine authentication, secure storage, permission UI, workspace creation, resource limits, and teardown. Those capabilities are intentionally absent here.

## Path note

`lexicalWorkingRoot` is a lexical preview only. Before any real read or write, a host integration must resolve existing ancestors with operating-system `realpath`, reject unsafe symlinks, and re-check containment under the allowed root.
