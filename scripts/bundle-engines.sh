#!/bin/bash
# 把 Tatwo2 執行所需的自含 runtime 放進 App。用法：scripts/bundle-engines.sh <app-bundle>
set -euo pipefail

NODE_VERSION="24.20.0"
CODEX_VERSION="0.153.2"
GITHUB_MCP_VERSION="1.0.5"
CACHE_ROOT="${TATWO2_ENGINE_CACHE:-$HOME/Library/Application Support/tatwo2/engine-cache}"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <app-bundle>" >&2
  exit 64
fi

APP="$1"
RESOURCES="$APP/Contents/Resources"
RUNTIME_BIN="$RESOURCES/runtime/bin"
mkdir -p "$CACHE_ROOT" "$RUNTIME_BIN"

NODE_BASENAME="node-v${NODE_VERSION}-darwin-arm64"
NODE_ARCHIVE="$CACHE_ROOT/$NODE_BASENAME.tar.gz"
NODE_CACHE="$CACHE_ROOT/$NODE_BASENAME"
if [[ ! -x "$NODE_CACHE/bin/node" ]]; then
  if [[ ! -f "$NODE_ARCHIVE" ]]; then
    echo "下載 node v${NODE_VERSION}…"
    curl --fail --location --retry 3 \
      "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_BASENAME}.tar.gz" \
      --output "$NODE_ARCHIVE"
  fi
  (
    cd "$CACHE_ROOT"
    expected="$(curl --fail --location --retry 3 \
      "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
      | awk -v file="${NODE_BASENAME}.tar.gz" '$2 == file { print }')"
    [[ -n "$expected" ]] || { echo "找不到 node checksum" >&2; exit 1; }
    printf '%s\n' "$expected" | shasum -a 256 -c -
  )
  stage="$(mktemp -d "$CACHE_ROOT/node-stage.XXXXXX")"
  tar -xzf "$NODE_ARCHIVE" -C "$stage"
  if [[ -e "$NODE_CACHE" ]]; then
    mv "$NODE_CACHE" "$NODE_CACHE.previous-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  mv "$stage/$NODE_BASENAME" "$NODE_CACHE"
  rmdir "$stage"
fi
cp "$NODE_CACHE/bin/node" "$RUNTIME_BIN/node"
chmod +x "$RUNTIME_BIN/node"

CODEX_CACHE="$CACHE_ROOT/codex-$CODEX_VERSION"
if [[ ! -d "$CODEX_CACHE/node_modules/@openai/codex" ]]; then
  mkdir -p "$CODEX_CACHE"
  npm install --prefix "$CODEX_CACHE" --no-audit --no-fund "@openai/codex@$CODEX_VERSION"
fi
CODEX_NATIVE="$(find "$CODEX_CACHE/node_modules/@openai" -type f \
  \( -path '*/vendor/aarch64-apple-darwin/bin/codex' \
     -o -path '*/vendor/aarch64-apple-darwin/codex/codex' \) \
  -print -quit)"
if [[ -z "$CODEX_NATIVE" ]]; then
  echo "找不到 @openai/codex 的 aarch64-apple-darwin 原生二進位" >&2
  exit 1
fi
# codex 0.153 的工具要靠同目錄的 codex-code-mode-host、codex-path/rg、codex-resources/zsh；整個 vendor 目錄搬進來，
# runtime/bin/codex 做成薄包裝指過去（只複製 codex 本體會讓所有工具呼叫失敗：「找不到 codex-code-mode-host」，2026-09-05 GPT-6 首測抓到）
CODEX_VENDOR_SRC="$(dirname "$(dirname "$CODEX_NATIVE")")"
if [[ "$(basename "$CODEX_VENDOR_SRC")" != "aarch64-apple-darwin" ]]; then CODEX_VENDOR_SRC="$(dirname "$CODEX_NATIVE")"; fi
rm -rf "$RUNTIME_BIN/../codex-vendor"
mkdir -p "$RUNTIME_BIN/../codex-vendor"
cp -R "$CODEX_VENDOR_SRC" "$RUNTIME_BIN/../codex-vendor/aarch64-apple-darwin"
cat > "$RUNTIME_BIN/codex" <<'WRAP'
#!/bin/sh
exec "$(cd "$(dirname "$0")/.." && pwd)/codex-vendor/aarch64-apple-darwin/bin/codex" "$@"
WRAP
chmod +x "$RUNTIME_BIN/codex" "$RUNTIME_BIN/../codex-vendor/aarch64-apple-darwin/bin/"* 2>/dev/null || true

GITHUB_MCP_BASENAME="github-mcp-server_Darwin_arm64"
GITHUB_MCP_ARCHIVE_NAME="${GITHUB_MCP_BASENAME}.tar.gz"
GITHUB_MCP_CACHE="$CACHE_ROOT/github-mcp-server-$GITHUB_MCP_VERSION"
GITHUB_MCP_ARCHIVE="$CACHE_ROOT/github-mcp-server_${GITHUB_MCP_VERSION}_Darwin_arm64.tar.gz"
GITHUB_MCP_CHECKSUMS="$CACHE_ROOT/github-mcp-server_${GITHUB_MCP_VERSION}_checksums.txt"
if [[ ! -x "$GITHUB_MCP_CACHE/github-mcp-server" ]]; then
  mkdir -p "$GITHUB_MCP_CACHE"
  if (
    set -e
    base="https://github.com/github/github-mcp-server/releases/download/v${GITHUB_MCP_VERSION}"
    curl --fail --location --retry 3 "$base/$GITHUB_MCP_ARCHIVE_NAME" --output "$GITHUB_MCP_ARCHIVE"
    curl --fail --location --retry 3 \
      "$base/github-mcp-server_${GITHUB_MCP_VERSION}_checksums.txt" \
      --output "$GITHUB_MCP_CHECKSUMS"
    expected="$(awk -v file="$GITHUB_MCP_ARCHIVE_NAME" '$2 == file { print }' "$GITHUB_MCP_CHECKSUMS")"
    [[ -n "$expected" ]]
    (
      cd "$CACHE_ROOT"
      printf '%s\n' "$expected" | shasum -a 256 -c -
    )
    tar -xzf "$GITHUB_MCP_ARCHIVE" -C "$GITHUB_MCP_CACHE"
    chmod +x "$GITHUB_MCP_CACHE/github-mcp-server"
  ); then
    :
  else
    echo "ENGINE-BUNDLE WARN github-mcp-server：下載或驗證 v${GITHUB_MCP_VERSION} 失敗，本次跳過" >&2
  fi
fi
if [[ -x "$GITHUB_MCP_CACHE/github-mcp-server" ]]; then
  cp "$GITHUB_MCP_CACHE/github-mcp-server" "$RUNTIME_BIN/github-mcp-server"
  chmod +x "$RUNTIME_BIN/github-mcp-server"
else
  echo "ENGINE-BUNDLE WARN github-mcp-server：快取沒有可執行檔，本次跳過" >&2
fi

CLAUDE_SIDECAR="$RESOURCES/claude-sidecar"
if [[ -f "$CLAUDE_SIDECAR/package-lock.json" \
      && ! -d "$CLAUDE_SIDECAR/node_modules/@anthropic-ai/claude-agent-sdk" ]]; then
  (cd "$CLAUDE_SIDECAR" && npm ci --omit=dev --no-audit --no-fund)
fi
CLAUDE_NATIVE="$(find "$CLAUDE_SIDECAR/node_modules" \
  -type f -path '*/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude' -print -quit 2>/dev/null || true)"
if [[ -n "$CLAUDE_NATIVE" ]]; then
  chmod +x "$CLAUDE_NATIVE"
fi

GROK_SOURCE="$HOME/.grok/bin/grok"
if [[ -x "$GROK_SOURCE" ]]; then
  cp -L "$GROK_SOURCE" "$RUNTIME_BIN/grok"
  chmod +x "$RUNTIME_BIN/grok"
else
  echo "ENGINE-BUNDLE WARN grok：找不到 $GROK_SOURCE；Grok 沒有公開下載網址，本次跳過" >&2
fi

echo "ENGINE-BUNDLE node $("$RUNTIME_BIN/node" --version)"
echo "ENGINE-BUNDLE codex $("$RUNTIME_BIN/codex" --version)"
if [[ -x "$RUNTIME_BIN/grok" ]]; then
  echo "ENGINE-BUNDLE grok $("$RUNTIME_BIN/grok" --version 2>&1 | head -1)"
else
  echo "ENGINE-BUNDLE grok unavailable"
fi
if [[ -x "$RUNTIME_BIN/github-mcp-server" ]]; then
  echo "ENGINE-BUNDLE github-mcp-server v${GITHUB_MCP_VERSION}"
else
  echo "ENGINE-BUNDLE github-mcp-server unavailable"
fi
