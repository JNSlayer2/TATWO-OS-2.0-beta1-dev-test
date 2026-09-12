import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const productionScript = readFileSync(
  path.join(repoRoot, "script", "build_production_app.sh"),
  "utf8",
);
// ChatPageModel.swift was split into topic files (2026-09-02); read the family.
const chatPageModelDirectory = path.join(
  repoRoot,
  "Apps",
  "TatwoUltraworkMac",
  "Sources",
  "TatwoUltraworkMac",
);
const chatPageModel = readdirSync(chatPageModelDirectory)
  .filter((name) => name === "ChatPageModel.swift" || name.startsWith("ChatPageModel+"))
  .sort()
  .map((name) => readFileSync(path.join(chatPageModelDirectory, name), "utf8"))
  .join("\n");
const appShell = readFileSync(
  path.join(
    repoRoot,
    "Apps",
    "TatwoUltraworkMac",
    "Sources",
    "TatwoUltraworkMac",
    "AppShell.swift",
  ),
  "utf8",
);
// ChatPage.swift was split into topic files (2026-09-02); read the family.
const chatPage = readdirSync(chatPageModelDirectory)
  .filter((name) => name === "ChatPage.swift" || name.startsWith("ChatPage+"))
  .sort()
  .map((name) => readFileSync(path.join(chatPageModelDirectory, name), "utf8"))
  .join("\n");

test("production bundle explicitly launches App MCP on a validated portable port", () => {
  assert.match(
    productionScript,
    /APP_MCP_PORT="\$\{TATWO_PRODUCTION_APP_MCP_PORT:-17377\}"/,
  );
  assert.match(
    productionScript,
    /APP_MCP_PORT < 1 \|\| APP_MCP_PORT > 65535/,
  );
  assert.match(
    productionScript,
    /<key>TATWO_ULTRAWORK_APP_MCP_PORT<\/key><string>\$APP_MCP_PORT<\/string>/,
  );
  assert.match(
    productionScript,
    /printf 'TATWO_APP_MCP_URL=http:\/\/127\.0\.0\.1:%s\\n' "\$APP_MCP_PORT"/,
  );
});

test("production builder emits only production-intent markers before promotion", () => {
  assert.match(
    productionScript,
    /status --porcelain=v1 --untracked-files=all/,
  );
  assert.match(
    productionScript,
    /SOURCE_COMMIT="\$\(git -C "\$ROOT_DIR" rev-parse --verify 'HEAD\^\{commit\}'\)"/,
  );
  assert.match(
    productionScript,
    /SOURCE_TREE="\$\(git -C "\$ROOT_DIR" rev-parse --verify 'HEAD\^\{tree\}'\)"/,
  );
  assert.match(
    productionScript,
    /current_tree="\$\(git -C "\$ROOT_DIR" rev-parse --verify 'HEAD\^\{tree\}'\)"/,
  );
  assert.match(
    productionScript,
    /current_commit" != "\$SOURCE_COMMIT"[\s\S]*current_tree" != "\$SOURCE_TREE"/,
  );
  assert.match(productionScript, /BUILD_JOBS=2/);
  assert.equal(
    (productionScript.match(/--jobs "\$BUILD_JOBS"/g) ?? []).length,
    2,
  );
  assert.match(
    productionScript,
    /<key>TatwoSourceTree<\/key><string>\$SOURCE_TREE<\/string>/,
  );
  assert.match(
    productionScript,
    /<key>TatwoBuildClass<\/key><string>production-intent<\/string>/,
  );
  assert.match(
    productionScript,
    /<key>TatwoDistributionReady<\/key><false\/>/,
  );
  assert.match(
    productionScript,
    /<key>TatwoAutomaticUpdatesEnabled<\/key><false\/>/,
  );
});

test("production bundle fails closed on missing resources and writes an evidence receipt", () => {
  assert.match(
    productionScript,
    /TatwoUltrawork_TatwoUltraworkCore\.bundle/,
  );
  assert.match(
    productionScript,
    /TatwoUltrawork_TatwoUltraworkMac\.bundle/,
  );
  assert.match(
    productionScript,
    /if \[\[ "\$COPIED_RESOURCE_BUNDLES" == "0" \]\]/,
  );
  assert.match(
    productionScript,
    /required production resource bundle is missing/,
  );
  assert.match(
    productionScript,
    /schema=TatwoProductionIntentBuildReceiptV1/,
  );
  for (const field of [
    "source_commit=$SOURCE_COMMIT",
    "source_tree=$SOURCE_TREE",
    "build_class=production-intent",
    "distribution_ready=false",
    "automatic_updates_enabled=false",
    "helper_sha256=$HELPER_SHA256",
    "resource_bundle_count=$COPIED_RESOURCE_BUNDLES",
  ]) {
    assert.ok(
      productionScript.includes(field),
      `production build receipt must include ${field}`,
    );
  }
  assert.match(
    productionScript,
    /printf 'SOURCE_TREE=%s\\n' "\$SOURCE_TREE"/,
  );
  assert.match(
    productionScript,
    /printf 'ANCHOR_HELPER_SHA256=%s\\n' "\$HELPER_SHA256"/,
  );
  assert.match(
    productionScript,
    /printf 'BUILD_RECEIPT=%s\\n' "\$BUILD_RECEIPT"/,
  );
});

test("Chat uses the user home fallback until a configured or restored project wins", () => {
  assert.match(
    chatPageModel,
    /@Published var workspacePath: String = FileManager\.default\.homeDirectoryForCurrentUser\.path/,
  );
  assert.doesNotMatch(
    chatPageModel,
    /@Published var workspacePath: String = FileManager\.default\.currentDirectoryPath/,
  );
  assert.match(
    chatPageModel,
    /if let rawWorkdir = environment\["TATWO_ULTRAWORK_CHAT_WORKDIR"\], !rawWorkdir\.trimmingCharacters\(in: \.whitespacesAndNewlines\)\.isEmpty \{\s*let configuredWorkdir = rawWorkdir\.trimmingCharacters\(in: \.whitespacesAndNewlines\)\s*self\.workspacePath = configuredWorkdir\s*self\.configuredChatWorkdirOverride = configuredWorkdir\s*\}/,
  );
  assert.match(
    chatPageModel,
    /if mode == \.chat, isSelectedThreadStandalone \{\s*if let configuredChatWorkdirOverride \{\s*let configured = URL\(fileURLWithPath: configuredChatWorkdirOverride\)\s*\.standardizedFileURL\s*if !Self\.isUnsafeChatWorkspaceRoot\(configured\) \{\s*return RuntimeWorkspaceResolution\(\s*url: configured,\s*skipGitRepoCheck: !Self\.looksLikeGitWorkTree\(configured\)\)\s*\}\s*\}/,
  );
  assert.match(
    chatPageModel,
    /runtimeRootURL:\s*injectedChatRuntimeRootURL\s*\?\?\s*injectedProcessStorageLayout\?\.chatRuntimeRootURL\s*\?\?\s*self\.store\.url\.deletingLastPathComponent\(\)\s*\.appendingPathComponent\(\s*"chat-cli-runtime-v1",\s*isDirectory: true\)/,
  );
  assert.equal(
    (
      appShell.match(
        /TatwoChatProcessCompositionRegistry\.chatPageModel\(/g,
      ) ?? []
    ).length,
    2,
    "snapshot export and the live first-frame path must reuse the same process-local Chat model",
  );
  assert.match(
    appShell,
    /enum TatwoChatProcessCompositionRegistry[\s\S]*private static var sharedChatPageModel: ChatPageModel\?[\s\S]*if let sharedChatPageModel \{[\s\S]*return sharedChatPageModel[\s\S]*let model = shared\.makeChatPageModel\(/,
  );
  assert.match(
    appShell,
    /TatwoChatLaunchSweepRootResolver\.runtimeRoot\(\s*for: TatwoChatProcessCompositionRegistry\.shared\)/,
  );
  assert.doesNotMatch(
    appShell,
    /temporaryDirectory\s*\.appendingPathComponent\("tatwo-ultrawork-chat-cli"/,
  );
  assert.match(
    chatPage,
    /ProjectFileBrowserView\(\s*rootPath: model\.currentConversationWorkspaceURL\(\)\.path\)/,
  );
  assert.match(
    chatPageModel,
    /let cwd = workdir \?\? currentConversationWorkspaceURL\(\)\.path/,
  );
  assert.match(
    chatPageModel,
    /openCLITab\(\s*engine: \.generic,\s*workdir: currentConversationWorkspaceURL\(\)\.path\)/,
  );
  assert.match(chatPageModel, /workspacePath = firstProject\.workdir/);
  assert.match(
    chatPageModel,
    /workspacePath = document\.projects\.first\(where: \{ \$0\.id == projectID \}\)\?\.workdir \?\? workspacePath/,
  );
});
