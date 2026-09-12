# Public Packaging Inventory — 2026-09-04

## Decision

Build a clean-room public reference core. Do not make the private development repository public and do not copy its tree into this repository.

## Included

| Area | Public form | Reason |
|---|---|---|
| OS constitution | Short provider-neutral rules | Explains the product philosophy without machine-specific policy |
| Engine boundary | Documented newline-delimited JSON event model | Lets integrators understand the adapter seam without provider sessions |
| Ultrawork rooms | Pure validation and dry-run preview | Demonstrates bounded delegation without host authority |
| Report collection | Explicitly unverified text aggregation | Preserves the distinction between reports, integration, and acceptance |
| Portable skill | Re-authored skill plus two references and selftest | Reusable without local installation topology |
| Safety | Threat model, boundary policy, scanner, tests, restricted CI | Makes public assumptions reviewable |

## Excluded

| Private category | Reason |
|---|---|
| Full desktop UI and copied visual source | Large private product surface; provenance and release scope need separate approval |
| Provider sidecars and login/session plumbing | Credential and configuration inheritance risk |
| Host process launch, shell, worktree mutation, sockets, browser and device control | Expands attack surface and requires operating-system enforcement |
| Installers, background agents, signing and update machinery | Persistent host mutation and supply-chain risk |
| Logs, reports, receipts, screenshots, fixtures and historical documents | May reveal projects, prompts, identities, paths or machine state |
| Private Git history and repository metadata | Redaction cannot reliably remove historical secrets or identifiers |
| Real model outputs and vendor routing receipts | Not needed for a portable implementation and may contain private context |

## Provenance rule

Public files are newly authored for this package. Architectural concepts were summarized; private source files were not bulk-copied. Any future code extraction requires file-level license and privacy review.

## Repository provenance

The public 2.0 tree was authored in a fresh Git history and imported without private commits, remotes, hooks, ignored files, or repository metadata. The prior public 1.0 history remains reachable through its release tags and archive reference.
