#!/bin/bash
# Read-only continuity gate. No private key access and no TCC modifications.
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: verify-update-identity.sh trusted-previous.app candidate.app' >&2; exit 1; }
for APP in "$1" "$2"; do
  [[ -d "$APP" && ! -L "$APP" ]] || exit 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == ai.tatwo.tatwo2 ]] || exit 1
  codesign --verify --deep --strict "$APP"
  DETAILS="$(codesign -dv "$APP" 2>&1)"
  if [[ "$DETAILS" == *Signature=adhoc* ]]; then
    echo 'Ad-hoc signatures cannot preserve the release identity.' >&2; exit 1
  fi
done
REQUIREMENT="$(codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$REQUIREMENT" ]] || exit 1
codesign --verify --deep --strict -R "$REQUIREMENT" "$2"
# Require compatibility in both directions: a silently weakened new requirement is rejected.
REQUIREMENT="$(codesign -dr - "$2" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$REQUIREMENT" ]] || exit 1
codesign --verify --deep --strict -R "$REQUIREMENT" "$1"
