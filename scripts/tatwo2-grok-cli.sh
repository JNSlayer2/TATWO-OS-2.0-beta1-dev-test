#!/bin/sh
# Same native isolation as the OS Grok sidecar, with no auth copying or host-global config writes.
set -eu
: "${TATWO2_GROK_HOME:?OS Grok home is required}"
BIN="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/grok"
test -x "$BIN" || exit 127
exec /usr/bin/env \
  -u CLAUDE_CONFIG_DIR -u CLAUDE_HOME -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PLUGIN_DATA \
  -u CLAUDE_PROJECT_DIR -u ANTHROPIC_API_KEY -u CODEX_HOME -u OPENAI_API_KEY \
  HOME="$TATWO2_GROK_HOME" GROK_HOME="$TATWO2_GROK_HOME/.grok" \
  XDG_CONFIG_HOME="$TATWO2_GROK_HOME/.config" XDG_CACHE_HOME="$TATWO2_GROK_HOME/.cache" \
  "$BIN" "$@"
