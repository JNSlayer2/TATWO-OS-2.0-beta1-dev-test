#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_ROOT="/private/tmp/tatwo-loop-runner-package"
DRIVER_SOURCE="$REPO_ROOT/scripts/tatwo-loop-runner-driver.swift"

prepare_driver_package() {
  mkdir -p \
    "$PACKAGE_ROOT/Sources/TatwoLoopRunner" \
    "$PACKAGE_ROOT/Sources/TatwoUltraworkCore" \
    "$PACKAGE_ROOT/Sources/TatwoDomainContracts" \
    "$PACKAGE_ROOT/Sources/TatwoWorkReceiptContracts"
  for source in "$REPO_ROOT"/Packages/TatwoWorkReceiptContracts/Sources/TatwoWorkReceiptContracts/*.swift; do
    ln -sf "$source" "$PACKAGE_ROOT/Sources/TatwoWorkReceiptContracts/$(basename "$source")"
  done
  for source in "$REPO_ROOT"/Packages/TatwoDomainContracts/Sources/TatwoDomainContracts/*.swift; do
    ln -sf "$source" "$PACKAGE_ROOT/Sources/TatwoDomainContracts/$(basename "$source")"
  done
  for source in "$REPO_ROOT"/Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/*.swift; do
    ln -sf "$source" "$PACKAGE_ROOT/Sources/TatwoUltraworkCore/$(basename "$source")"
  done
  cp "$REPO_ROOT/Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoModelIdentityRegistryV1.json" \
    "$PACKAGE_ROOT/Sources/TatwoUltraworkCore/"
  cp "$REPO_ROOT/config/tatwo-sync-catalog-v1.json" \
    "$PACKAGE_ROOT/Sources/TatwoUltraworkCore/"
  cp "$REPO_ROOT/config/tatwo-durable-surface-inventory-v1.json" \
    "$PACKAGE_ROOT/Sources/TatwoUltraworkCore/"
  cp "$DRIVER_SOURCE" "$PACKAGE_ROOT/Sources/TatwoLoopRunner/main.swift"
  cat > "$PACKAGE_ROOT/Package.swift" <<'EOF'
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "TatwoLoopRunner",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "tatwo-loop-runner-driver", targets: ["TatwoLoopRunner"])
  ],
  targets: [
    .target(
      name: "TatwoWorkReceiptContracts",
      path: "Sources/TatwoWorkReceiptContracts"),
    .target(
      name: "TatwoDomainContracts",
      dependencies: ["TatwoWorkReceiptContracts"],
      path: "Sources/TatwoDomainContracts"),
    .target(
      name: "TatwoUltraworkCore",
      dependencies: ["TatwoWorkReceiptContracts", "TatwoDomainContracts"],
      path: "Sources/TatwoUltraworkCore",
      resources: [
        .copy("TatwoModelIdentityRegistryV1.json"),
        .copy("tatwo-sync-catalog-v1.json"),
        .copy("tatwo-durable-surface-inventory-v1.json")
      ]),
    .executableTarget(
      name: "TatwoLoopRunner",
      dependencies: ["TatwoUltraworkCore"],
      path: "Sources/TatwoLoopRunner")
  ])
EOF
}

usage() {
  cat >&2 <<'EOF'
Use:
  tatwo-loop-runner.sh run --device-id <device>
  tatwo-loop-runner.sh origin-enqueue --manifest <file> --work-path <dir>
  tatwo-loop-runner.sh converge --manifest <file>
  tatwo-loop-runner.sh verify --manifest <file>
  tatwo-loop-runner.sh negative-trust --work-path <dir>
  tatwo-loop-runner.sh negative-loop --work-path <dir>
  tatwo-loop-runner.sh negative-security --work-path <dir>
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
prepare_driver_package

# 專屬鎖，與外層 /tmp/tatwo-build.lock 分開：runner 常被包在已持 build lock 的
# 監工/e2e 流程內，共用同名鎖會不可重入自我死鎖（2026-07-28 三次誤判事故根因）。
LOCK=/tmp/tatwo-loop-runner.lock
while ! mkdir "$LOCK" 2>/dev/null; do sleep 30; done
cleanup() { rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

CACHE=/private/tmp/tatwo-swift-cache-ws1
mkdir -p "$CACHE/clang" "$CACHE/swift"
export SWIFT_MODULECACHE_PATH="$CACHE/swift"
export CLANG_MODULE_CACHE_PATH="$CACHE/clang"

case "$1" in
  run)
    shift
    swift run --disable-sandbox --jobs 2 --package-path "$PACKAGE_ROOT" \
      tatwo-loop-runner-driver runner "$@"
    ;;
  origin-enqueue|converge|verify|negative-trust|negative-loop|negative-security)
    command="$1"
    shift
    swift run --disable-sandbox --jobs 2 --package-path "$PACKAGE_ROOT" \
      tatwo-loop-runner-driver "$command" "$@"
    ;;
  *)
    usage
    ;;
esac
