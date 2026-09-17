# OS-managed GBrain

`GBrainService` owns `service.mjs`; engine clients run `server.mjs`, never the
GBrain helper. The public MCP registration remains `gbrain_allai`.

## Storage and modes

All local state is under `<entry>/gbrain/`. `connection.json` contains only
non-secret routing metadata:

- `pglite`: primary only. One `serve --http --bind 127.0.0.1` owns `brain/`.
- `legacy`: primary's existing absolute wrapper `command` and `args`; no new
  helper, init, migration, reindex or schema operations.
- `ssh-stdio`: secondary's paired `host`, optional `user`/`sshPort`, and remote
  wrapper `command`/`args`. Existing local SSH wrappers use `wrapper: true`.
- `remote`: generated from the paired primary's UUID/registry. Discovers the
  primary's state over existing SSH trust, then uses `ssh-stdio` or `ssh-http`.
- `ssh-http`: loopback-only SSH forwarding to the primary's current random port.
  Discovery-enabled connections rediscover the port on restart.

Recognized existing `gbrain-unified` / `gbrain-allai` wrappers are adopted from
the existing registry without copying environment values. Unsupported launch
shapes fail closed. An existing user-home GBrain configuration prevents an
implicit fresh PGLite initialization.

`state.json` is a time-limited projection of real MCP reads. Page count comes
from `get_stats`; last-write metadata includes the existing ingest log so
timeline/raw writes are visible without rewriting pages. Unknown provenance
is not invented.

## Secrets and safety

Provider credentials and HTTP bearer credentials belong to the local Keychain
service `TATWO.GBrain`. Credentials are never routing fields or argv. The App
injects credentials into the supervisor environment; adapters obtain their
bearer from the runtime environment or Keychain. The first-use macOS Keychain
access prompt / remote Keychain access still requires platform acceptance.

Only explicit read tools and `put_page`, `add_timeline_entry`, `put_raw_data`,
`log_ingest` are exposed. Other writes, arbitrary SQL, removal and schema tools
are rejected. The adapter stamps the current local device name, reserved device
tags and provenance independently of model-supplied values. Unsupported complex
frontmatter is rejected rather than silently damaged.

An atomic owner directory prevents a second supervisor. After an abnormal kill,
a stale `service.lock` intentionally blocks restart: verify the recorded owner
has stopped, then archive the stale directory before retrying. Never remove a
live owner's lock. Service shutdown scans the entire GBrain directory for
credential leakage, including binary database files.

Semantic enablement is primary/PGLite-only, requires a stored OpenAI key and
uses upstream guarded initialization at the existing 1024-dimensional width.
It does not migrate the legacy Postgres brain or backfill old vectors.

## Verification

Run Node tests only on the build host with external-volume `TMPDIR`.
`tests/w80b-*.test.mjs` uses synthetic homes. Set `W80B_GBRAIN_HELPER`,
`W80B_RELEASE_JSON`, `W80B_ASSET`, `W80B_LICENSE` to the retained W80a isolated
artifacts for the real helper and synthetic bundle checks; without these,
those artifact-dependent checks explicitly skip. No test uses the live brain.
