#!/bin/bash
# Stage only reproducible device sources, never signing data or Xcode user state.
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 source-directory new-destination" >&2; exit 2; }
SOURCE="$1"
DESTINATION="$2"
FILES=(
  project.yml
  TatwoIPadDeviceTests/Info.plist
  TatwoIPadDeviceTests/TatwoIPadDeviceTests.swift
  TatwoIPadDevice.xcodeproj/project.pbxproj
  TatwoIPadDevice.xcodeproj/project.xcworkspace/contents.xcworkspacedata
  TatwoIPadDevice.xcodeproj/xcshareddata/xcschemes/TatwoIPadDevice.xcscheme
)
[[ -d "$SOURCE" && ! -L "$SOURCE" ]] || { echo "invalid device source directory" >&2; exit 1; }
[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || { echo "device destination must be new" >&2; exit 1; }
# Validate the entire input set before creating output; don't follow source symlinks.
for relative in "${FILES[@]}"; do
  [[ -f "$SOURCE/$relative" && -s "$SOURCE/$relative" ]] || {
    echo "missing device source: $relative" >&2; exit 1;
  }
  component="$relative"
  while [[ "$component" != "." ]]; do
    [[ ! -L "$SOURCE/$component" ]] || { echo "symlink in device source: $relative" >&2; exit 1; }
    component="$(dirname "$component")"
  done
done
mkdir -p "$(dirname "$DESTINATION")"
mkdir "$DESTINATION"
for relative in "${FILES[@]}"; do
  mkdir -p "$DESTINATION/$(dirname "$relative")"
  cp "$SOURCE/$relative" "$DESTINATION/$relative"
done
