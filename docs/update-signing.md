# Signing and update continuity

Builds require an explicit `TATWO2_SIGN_IDENTITY`. There is no automatic certificate selection or ad-hoc fallback. Reuse the existing signing identity and bundle identifier `ai.tatwo.tatwo2`. Never create a fresh certificate for each update.

Release packaging also requires `TATWO2_RELEASE_BASELINE`, pointing to a trusted, previously distributed app. Both apps must have valid non-ad-hoc signatures, the expected bundle identifier, and mutually compatible designated requirements. A certificate name or unchanged CDHash is not an identity policy. Normal code changes change the CDHash.

A new signing lineage needs a separately reviewed bootstrap or migration; the packaging gate intentionally does not bootstrap from an untrusted new artifact. Official direct distribution should use Developer ID Application and notarization. This patch does not create certificates, access private keys, notarize, or publish a binary release. Existing published binaries are unchanged.

## Public installer

`install.sh` and `public/install.sh` must remain byte-identical. The installer checks archive integrity, signature integrity, bundle identity, and compatibility with the installed app. First installation requires Gatekeeper assessment because there is no existing local baseline. Beta signatures alone do not satisfy that first-install policy. Quarantine is preserved.

The canonical destination is `/Applications/TATWO OS.app`. Known legacy locations in the system and user Applications directories block installation until migrated. This is not an exhaustive inventory of every development copy on the disk. Development copies should use a separately implemented bundle identity and data directory; changing only the display name is insufficient.

A lock serializes installers. The app must be closed before replacement. A fully copied and verified staging app is renamed into place on the same filesystem. Failures before launch acceptance restore the original app and retain the failed candidate. `open` acceptance is not a runtime or Computer Use health check.

Backups have unique paths in `~/Library/Application Support/TATWO OS/UpdateArchives`, under `.noindex` directories and with `.app.disabled` extensions. An interrupted archival operation retains the staging directory. No automatic purge occurs. To roll back: quit the app, archive the current bundle, restore the desired `previous.app.disabled` as the canonical app, then register and open that app. Never overwrite user data or restore a user-data snapshot as part of an app rollback.

## One-time migration

An installed ad-hoc version or conflicting legacy copy cannot safely be treated as a trusted release baseline. Archive and unregister confirmed obsolete copies, install the approved persistent-identity release in the canonical location, then grant macOS permissions manually if requested. Do not reset TCC during normal updates. Do not remove quarantine to force acceptance.

## Acceptance before binary release

Run `python3 tests/update-signing.test.py`. On a dedicated macOS test account, manually authorize the approved initial release once, then upgrade N → N+1 → N+2 and roll back. Verify Computer Use after each transition without regranting permissions. Test interruption and duplicate-install cases. Fixture tests do not establish real TCC continuity; real signed upgrade evidence is required before claiming this problem is permanently resolved.

This policy reduces avoidable permission invalidation; macOS can still request consent after a signing migration, permission revocation, or a newly requested capability.

## Public source privacy

Fixtures use synthetic users, reserved example addresses, and demo accounts. Device scripts default to the user-configured SSH alias `tatwo-primary`; set `TATWO_PRIMARY_SSH_HOST` or use `--primary-host` to select your own device. Optional gateway restart requires `TATWO_GATEWAY_LAUNCH_AGENT_LABEL`; no personal launch-agent label is embedded. Public upstream project attribution is retained.

Local diagnostic logs, screenshots, machine paths, and signing material must never be staged. Commit metadata must use a public-facing name and noreply address. This patch cleans current files; it does not rewrite earlier public Git history.
