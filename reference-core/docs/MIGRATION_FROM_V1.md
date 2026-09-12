# Replacing the Public OS 1.0 Tree

The public 2.0 tree follows the migration sequence below. The sequence preserves the public 1.0 history and does not import private development history.

## Safe migration sequence

1. Freeze the current public default branch with a signed or annotated release tag and downloadable source archive.
2. Export its license notices and release notes for historical access.
3. Review this new tree in a fresh directory with no inherited `.git`, remote, hooks, attributes, or ignored files.
4. Run tests, the public-safety scanner, an independent secret scanner, dependency review, and a clean-machine smoke test.
5. Obtain a separate security review and manually inspect every tracked file.
6. Create one new root commit for the 2.0 public tree. Do not graft private history.
7. Replace the public default-branch tree in a reviewable pull request or protected-branch flow. Do not force-push over the archived 1.0 tag.
8. Publish release notes explaining that 2.0 is a clean-room public reference core, not an in-place continuation of private development history.
9. Keep provider adapters and host-execution features disabled until each has its own threat model, tests, and explicit configuration.
10. After publication, verify the remote file list and downloadable archive independently; local scan results alone are insufficient.

## Rollback

Retain the 1.0 tag and archive. If the 2.0 review fails, restore the prior default-branch commit through normal branch protection rather than rewriting history.
