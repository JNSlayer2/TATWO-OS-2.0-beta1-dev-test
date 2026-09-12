# Security / 安全聲明

Tatwo Ultrawork is a local-first workflow controller. The public project is designed to ship workflow logic, UI, CLI, MCP schemas, and installer checks — not user credentials or private workspace data.

## Security posture

- Model and plugin connections should use the user's own official login or API flow.
- Tatwo defaults to planning, receipts, smoke checks, and explicit install prompts.
- Host-changing actions require clear user approval and should be reversible.
- Public issues should use minimal examples and should not include credentials or private machine data.

## Reporting

If you find a security problem, open a GitHub issue with a minimal reproduction, or contact the project maintainer privately if disclosure would expose user data.
