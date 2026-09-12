import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// BotPageAntiSmuggleSourceTests — Gen-4 U2 anti-smuggle source contract.
// Style: tests/gen3-governance-adapter-source-contract.test.mjs
// Pins the same rg assertions as harness-exam/g4/antismuggle-report.md.

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const srcDir = path.join(
  repoRoot,
  "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac",
);
const botPagePath = path.join(srcDir, "BotPage.swift");
const botFixturePath = path.join(srcDir, "BotPageFixture.swift");
const chatPagePath = path.join(srcDir, "ChatPage.swift");
const botPageFiles = [botPagePath, botFixturePath];
const botPage = fs.readFileSync(botPagePath, "utf8");
const botFixture = fs.readFileSync(botFixturePath, "utf8");
// ChatPage.swift was split into topic files (2026-09-02); read the family.
const readChatPageFamily = (dir) => fs.readdirSync(dir)
  .filter((n) => n === "ChatPage.swift" || n.startsWith("ChatPage+"))
  .sort()
  .map((n) => fs.readFileSync(path.join(dir, n), "utf8"))
  .join("\n");
const chatPage = readChatPageFamily(srcDir);

function rg(args, files) {
  try {
    const stdout = execFileSync("rg", [...args, ...files], {
      encoding: "utf8",
      cwd: repoRoot,
    });
    return { status: 0, stdout };
  } catch (err) {
    if (err.status === 1) {
      return { status: 1, stdout: err.stdout || "" };
    }
    throw err;
  }
}

function assertNoRgHits(pattern, files, extraArgs = []) {
  const result = rg(["-n", ...extraArgs, pattern], files);
  assert.equal(
    result.status,
    1,
    `expected zero hits for ${pattern}, got:\n${result.stdout}`,
  );
  assert.equal(result.stdout.trim(), "");
}

function slice(source, start, end) {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing start marker: ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker after ${start}: ${end}`);
  return source.slice(from, to);
}

test("BotPage files exist as a sibling surface, not ChatPageModel", () => {
  assert.equal(fs.existsSync(botPagePath), true);
  assert.equal(fs.existsSync(botFixturePath), true);
  assert.match(botPage, /struct BotPageRootView: View/);
  assert.match(botFixture, /struct BotPageFixture/);
  assert.doesNotMatch(botPage, /ChatPageModel/);
  assert.doesNotMatch(botFixture, /ChatPageModel/);
});

test("no ChatPageModel.send / func send / botDispatcher / gateway.dispatch in BotPage*", () => {
  assertNoRgHits(
    String.raw`ChatPageModel\.send|func send\(|botDispatcher|gateway\.dispatch`,
    botPageFiles,
  );
  assert.doesNotMatch(botPage, /ChatPageModel\.send/);
  assert.doesNotMatch(botFixture, /ChatPageModel\.send/);
  assert.doesNotMatch(botPage, /func send\(/);
  assert.doesNotMatch(botFixture, /func send\(/);
});

test("ChatPage .bot branch does not call send", () => {
  assertNoRgHits(String.raw`ChatPageModel\.send`, [chatPagePath]);
  // `chatSidebar` lost `private` when ChatPage.swift was split (2026-09-02).
  const sidebar = slice(chatPage, "        case .bot:", "    var chatSidebar");
  assert.match(sidebar, /EmptyView\(\)/);
  assert.doesNotMatch(sidebar, /send\s*\(/);
  assert.doesNotMatch(sidebar, /ensureNativeTerminal/);

  const mainBot = slice(
    chatPage,
    "            if model.mode == .bot {",
    "            } else if model.mode == .cli {",
  );
  assert.match(mainBot, /BotPageRootView\.forScene/);
  assert.doesNotMatch(mainBot, /send\s*\(/);
  assert.doesNotMatch(mainBot, /ensureNativeTerminal/);
  assert.doesNotMatch(mainBot, /composer\(/);

  const composerGate = slice(
    chatPage,
    "            if model.mode != .cli, model.mode != .bot {",
    "        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)",
  );
  assert.match(composerGate, /composer\(/);
});

test("no Toggle / Slider / Stepper / Picker / NSOpenPanel in BotPage files", () => {
  assertNoRgHits(
    String.raw`Toggle\s*\(|Slider\s*\(|Stepper\s*\(|NSOpenPanel|Picker\s*\(`,
    botPageFiles,
  );
});

test("no WKWebView in BotPage files or ChatPage", () => {
  assertNoRgHits(
    String.raw`WKWebView|WKWebViewConfiguration|WebKit`,
    [...botPageFiles, chatPagePath],
  );
});

test("no Line / Discord / Telegram SDK import in BotPage files", () => {
  assertNoRgHits(
    String.raw`^import[[:space:]].*(Line|Discord|Telegram)|LineSDK|DiscordSDK|DiscordKit|TelegramBotSDK|TelegramBot\b`,
    botPageFiles,
  );
  const imports = [...botPage.matchAll(/^import\s+(\S+)/gm)].map((m) => m[1]);
  const fixtureImports = [...botFixture.matchAll(/^import\s+(\S+)/gm)].map(
    (m) => m[1],
  );
  assert.deepEqual(imports, ["SwiftUI"]);
  assert.deepEqual(fixtureImports, ["Foundation"]);
});

test("no UserDefaults / FileManager writes in BotPage files", () => {
  assertNoRgHits(
    String.raw`UserDefaults|FileManager|NSOpenPanel|NSSavePanel|\.write\(|createDirectory`,
    botPageFiles,
  );
});

test("fixture ids all use the fixture- prefix", () => {
  const negative = rg(
    ["-n", "--pcre2", String.raw`id:\s*"(?!fixture-)[^"]+"`],
    [botFixturePath],
  );
  assert.equal(negative.status, 1, negative.stdout);
  const ids = [...botFixture.matchAll(/\bid:\s*"([^"]+)"/g)].map((m) => m[1]);
  assert.ok(ids.length >= 20, `expected many fixture ids, got ${ids.length}`);
  for (const id of ids) {
    assert.ok(id.startsWith("fixture-"), `id missing fixture- prefix: ${id}`);
  }
});

test("no runner / gateway / MCP / sandbox service import in BotPage files", () => {
  assertNoRgHits(
    String.raw`^import[[:space:]].*(Runner|Channel|Auth|Sandbox|Gateway|MCP|Line|Discord|Telegram)`,
    botPageFiles,
  );
});

test("onChange of model.mode only starts terminal on .cli", () => {
  assertNoRgHits(String.raw`onChange|ensureNativeTerminal`, botPageFiles);
  const onChange = slice(
    chatPage,
    ".onChange(of: model.mode) { _, newMode in",
    ".onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier]",
  );
  assert.match(
    onChange,
    /if newMode == \.cli, model\.isCLIRuntimeEnabled \{\s*model\.ensureNativeTerminal\(\)/,
  );
  assert.doesNotMatch(onChange, /newMode == \.bot/);
  assert.doesNotMatch(onChange, /newMode != \.chat/);

  const lines = chatPage.split("\n");
  const idx = lines.findIndex((line) =>
    line.includes(".onChange(of: model.mode)"),
  );
  assert.ok(idx >= 0, "onChange(of: model.mode) must exist in the ChatPage family");
  assert.match(lines[idx + 1], /if newMode == \.cli, model\.isCLIRuntimeEnabled/);
  assert.match(lines[idx + 2], /model\.ensureNativeTerminal\(\)/);
  assert.equal(lines[idx + 3].trim(), "}");
});
