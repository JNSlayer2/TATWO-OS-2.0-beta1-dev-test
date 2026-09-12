// Engines/cli/tatwo-engine.mjs 的測試。不呼叫真引擎：用一個假 sidecar 走同一份協議。
// 跑法：node --test Engines/cli/tatwo-engine.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const CLI = path.resolve(__dirname, "tatwo-engine.mjs");
const REPO_ROOT = path.resolve(__dirname, "..", "..");

function makeSandbox() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-engine-test-"));
  return { root, log: path.join(root, "audit.jsonl"), cwd: root };
}

// 用一個假 sidecar 取代真引擎：把它擺到 <sandbox>/Engines/<name>-sidecar/sidecar.mjs，
// 再把 CLI 複製進同一棵樹，這樣 CLI 的 REPO_ROOT 推導就會指到 sandbox。
function installFakeEngine(sandboxRoot, engine, body) {
  const dir = path.join(sandboxRoot, "Engines", `${engine}-sidecar`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "sidecar.mjs"), body);
  const cliDir = path.join(sandboxRoot, "Engines", "cli");
  fs.mkdirSync(cliDir, { recursive: true });
  fs.copyFileSync(CLI, path.join(cliDir, "tatwo-engine.mjs"));
  return path.join(cliDir, "tatwo-engine.mjs");
}

const ECHO_SIDECAR = `
import readline from "node:readline";
const emit = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
emit({ ev: "sdk", msg: { type: "system", subtype: "init", session_id: "fake-session", model: "fake-model-1" } });
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const cmd = JSON.parse(line);
  if (cmd.op === "send") {
    for (const piece of ["收到：", cmd.text]) {
      emit({ ev: "sdk", msg: { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: piece } } } });
    }
    emit({ ev: "sdk", msg: { type: "result", subtype: "success", is_error: false, session_id: "fake-session", duration_ms: 12 } });
  }
  if (cmd.op === "close") process.exit(0);
});
`;

// 每收到 send 就要求用一個工具，把 CLI 的許可判斷結果回報出來。
const TOOL_SIDECAR = (tool, input) => `
import readline from "node:readline";
const emit = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
emit({ ev: "sdk", msg: { type: "system", subtype: "init", session_id: "s", model: "m" } });
let decision = null;
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const cmd = JSON.parse(line);
  if (cmd.op === "send") {
    emit({ ev: "permission_request", id: "p1", tool: ${JSON.stringify(tool)}, input: ${JSON.stringify(input)} });
    return;
  }
  if (cmd.op === "permission") {
    decision = cmd;
    const text = (cmd.allow ? "ALLOW" : "DENY") + "|" + String(cmd.message || "");
    emit({ ev: "sdk", msg: { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text } } } });
    emit({ ev: "sdk", msg: { type: "result", subtype: "success", is_error: false, session_id: "s" } });
    return;
  }
  if (cmd.op === "close") process.exit(0);
});
`;

// 測試一律釘死 sidecar 來源，否則 CLI 會找到已安裝 App 裡的真 sidecar，
// 測試就會打真引擎（會燒額度、結果也不是我們要驗的）。
function runCLI(cliPath, args, sandbox, extraEnv = {}) {
  return spawnSync(process.execPath, [cliPath, ...args, "--log", sandbox.log], {
    encoding: "utf8",
    timeout: 30000,
    env: {
      ...process.env,
      TATWO_ENGINE_SIDECAR_ROOT: path.join(sandbox.root, "Engines"),
      ...extraEnv,
    },
  });
}

test("ask 模式拿得到回覆並寫下稽核紀錄", () => {
  const s = makeSandbox();
  const cli = installFakeEngine(s.root, "claude", ECHO_SIDECAR);
  const r = runCLI(cli, ["ask", "--engine", "claude", "--cwd", s.cwd, "你好"], s);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /收到：你好/);
  const rows = fs.readFileSync(s.log, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  assert.equal(rows.length, 1);
  assert.equal(rows[0].engine, "claude");
  assert.equal(rows[0].mode, "ask");
  assert.equal(rows[0].exit_status, 0);
  assert.equal(rows[0].engine_session_id, "fake-session");
  assert.equal(rows[0].model_reported, "fake-model-1");
});

test("三家引擎都走同一條路", () => {
  for (const engine of ["codex", "claude", "grok"]) {
    const s = makeSandbox();
    const cli = installFakeEngine(s.root, engine, ECHO_SIDECAR);
    const extra = engine === "claude" ? [] : ["--unsafe-no-readonly"];
    const r = runCLI(cli, ["ask", "--engine", engine, "--cwd", s.cwd, ...extra, "ping"], s);
    assert.equal(r.status, 0, `${engine}: ${r.stderr}`);
    assert.match(r.stdout, /收到：ping/);
    const row = JSON.parse(fs.readFileSync(s.log, "utf8").trim());
    assert.equal(row.engine, engine);
  }
});

test("ask 模式拒絕所有工具", () => {
  const s = makeSandbox();
  const cli = installFakeEngine(s.root, "claude", TOOL_SIDECAR("Read", { file_path: "/etc/hosts" }));
  const r = runCLI(cli, ["ask", "--engine", "claude", "--cwd", s.cwd, "看檔案"], s);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^DENY\|/m);
  const row = JSON.parse(fs.readFileSync(s.log, "utf8").trim());
  assert.equal(row.denied_tools.length, 1);
  assert.equal(row.denied_tools[0].tool, "Read");
});

test("review 模式放行唯讀、擋掉寫入", () => {
  const s1 = makeSandbox();
  const cli1 = installFakeEngine(s1.root, "codex", TOOL_SIDECAR("Read", { file_path: "a.txt" }));
  const allow = runCLI(cli1, ["review", "--engine", "codex", "--cwd", s1.cwd, "--unsafe-no-readonly", "審"], s1);
  assert.match(allow.stdout, /^ALLOW\|/m);

  const s2 = makeSandbox();
  const cli2 = installFakeEngine(s2.root, "codex", TOOL_SIDECAR("Write", { file_path: "a.txt" }));
  const deny = runCLI(cli2, ["review", "--engine", "codex", "--cwd", s2.cwd, "--unsafe-no-readonly", "審"], s2);
  assert.match(deny.stdout, /^DENY\|/m);
  assert.match(deny.stdout, /禁止 Write/);
});

test("review 模式的 Bash：白名單放行，改寫語意擋掉", () => {
  const ok = makeSandbox();
  const cliOk = installFakeEngine(ok.root, "claude", TOOL_SIDECAR("Bash", { command: "git status --short" }));
  assert.match(runCLI(cliOk, ["review", "--engine", "claude", "--cwd", ok.cwd, "審"], ok).stdout, /^ALLOW\|/m);

  for (const command of ["rm -rf /tmp/x", "cat a > b", "git commit -m x && git push", "curl http://x"]) {
    const s = makeSandbox();
    const cli = installFakeEngine(s.root, "claude", TOOL_SIDECAR("Bash", { command }));
    const r = runCLI(cli, ["review", "--engine", "claude", "--cwd", s.cwd, "審"], s);
    assert.match(r.stdout, /^DENY\|/m, `應該擋下：${command}`);
  }
});

test("未知工具 fail-closed", () => {
  const s = makeSandbox();
  const cli = installFakeEngine(s.root, "grok", TOOL_SIDECAR("SomeBrandNewTool", {}));
  const r = runCLI(cli, ["review", "--engine", "grok", "--cwd", s.cwd, "--unsafe-no-readonly", "審"], s);
  assert.match(r.stdout, /^DENY\|/m);
  assert.match(r.stdout, /fail-closed/);
});

// 2026-09-09 真機發現：只靠攔截 permission_request 是 fail-open——真 claude 在 default 模式
// 不會問就直接寫檔。現在唯讀改由 sidecar 原生模式強制，不支援的引擎必須明確接受風險。
test("無法強制唯讀的引擎，ask/review 一律 fail-closed", () => {
  for (const engine of ["codex", "grok"]) {
    for (const mode of ["ask", "review"]) {
      const s = makeSandbox();
      const cli = installFakeEngine(s.root, engine, ECHO_SIDECAR);
      const r = runCLI(cli, [mode, "--engine", engine, "--cwd", s.cwd, "x"], s);
      assert.equal(r.status, 2, `${engine} ${mode} 應該被擋`);
      assert.match(r.stderr, /沒有可強制的唯讀模式/);
      assert.equal(fs.existsSync(s.log), false, "被擋下時不留稽核紀錄");
    }
  }
});

test("claude 的 ask/review 會把 readOnly 傳給 sidecar", () => {
  // 假 sidecar 把收到的 argv 回報出來，驗證真的有帶 --permission-mode readOnly。
  const argvEcho = `
import readline from "node:readline";
const emit = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
emit({ ev: "sdk", msg: { type: "system", subtype: "init", session_id: "s", model: "m" } });
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const cmd = JSON.parse(line);
  if (cmd.op === "send") {
    emit({ ev: "sdk", msg: { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: process.argv.slice(2).join(" ") } } } });
    emit({ ev: "sdk", msg: { type: "result", subtype: "success", is_error: false, session_id: "s" } });
  }
  if (cmd.op === "close") process.exit(0);
});
`;
  for (const mode of ["ask", "review"]) {
    const s = makeSandbox();
    const cli = installFakeEngine(s.root, "claude", argvEcho);
    const r = runCLI(cli, [mode, "--engine", "claude", "--cwd", s.cwd, "x"], s);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /--permission-mode readOnly/, `${mode} 應帶 readOnly`);
    const row = JSON.parse(fs.readFileSync(s.log, "utf8").trim());
    assert.equal(row.read_only_enforced, true);
    assert.equal(row.unsafe_no_readonly, false);
  }
  // delegate 走 bypassPermissions，不帶 readOnly
  const s = makeSandbox();
  const cli = installFakeEngine(s.root, "claude", argvEcho);
  const r = runCLI(cli, ["delegate", "--engine", "claude", "--cwd", s.cwd, "--yes", "x"], s);
  assert.match(r.stdout, /--permission-mode bypassPermissions/);
  const row = JSON.parse(fs.readFileSync(s.log, "utf8").trim());
  assert.equal(row.read_only_enforced, false);
});

test("接受風險時，稽核紀錄要留下 unsafe 標記", () => {
  const s = makeSandbox();
  const cli = installFakeEngine(s.root, "codex", ECHO_SIDECAR);
  const r = runCLI(cli, ["review", "--engine", "codex", "--cwd", s.cwd, "--unsafe-no-readonly", "x"], s);
  assert.equal(r.status, 0, r.stderr);
  const row = JSON.parse(fs.readFileSync(s.log, "utf8").trim());
  assert.equal(row.unsafe_no_readonly, true);
  assert.equal(row.read_only_enforced, false);
});

test("delegate 沒帶 --yes 直接拒絕啟動", () => {
  const s = makeSandbox();
  const cli = installFakeEngine(s.root, "claude", ECHO_SIDECAR);
  const r = runCLI(cli, ["delegate", "--engine", "claude", "--cwd", s.cwd, "動手"], s);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /--yes/);
  assert.equal(fs.existsSync(s.log), false, "被擋下時不該留稽核紀錄");
});

test("delegate 帶 --yes 才放行工具", () => {
  const s = makeSandbox();
  const cli = installFakeEngine(s.root, "claude", TOOL_SIDECAR("Write", { file_path: "a.txt" }));
  const r = runCLI(cli, ["delegate", "--engine", "claude", "--cwd", s.cwd, "--yes", "動手"], s);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^ALLOW\|/m);
});

test("逾時回 124 並記進稽核", () => {
  const s = makeSandbox();
  const hang = `
    import readline from "node:readline";
    process.stdout.write(JSON.stringify({ ev: "sdk", msg: { type: "system", subtype: "init", session_id: "s" } }) + "\\n");
    readline.createInterface({ input: process.stdin }).on("line", () => {});
    setInterval(() => {}, 1000);
  `;
  const cli = installFakeEngine(s.root, "claude", hang);
  const r = spawnSync(process.execPath,
    [cli, "ask", "--engine", "claude", "--cwd", s.cwd, "--timeout", "1", "--log", s.log, "會卡住"],
    { encoding: "utf8", timeout: 30000,
      env: { ...process.env, TATWO_ENGINE_SIDECAR_ROOT: path.join(s.root, "Engines") } });
  assert.equal(r.status, 124);
  assert.match(r.stderr, /逾時/);
  const row = JSON.parse(fs.readFileSync(s.log, "utf8").trim());
  assert.equal(row.exit_status, 124);
});

test("參數檢查：引擎、目錄、空請求", () => {
  const s = makeSandbox();
  const cli = installFakeEngine(s.root, "claude", ECHO_SIDECAR);
  assert.equal(runCLI(cli, ["ask", "--engine", "gemini", "--cwd", s.cwd, "x"], s).status, 2);
  assert.equal(runCLI(cli, ["ask", "--engine", "claude", "--cwd", "/does/not/exist", "x"], s).status, 2);
  assert.equal(runCLI(cli, ["ask", "--engine", "claude", "--cwd", s.cwd], s).status, 2);
});

test("doctor 會回報三家 sidecar 的實際解析結果", () => {
  const r = spawnSync(process.execPath, [CLI, "doctor"], { encoding: "utf8", timeout: 30000 });
  const report = JSON.parse(r.stdout);
  assert.equal(report.repo_root, REPO_ROOT);
  assert.deepEqual(report.sidecars.map((x) => x.engine), ["codex", "claude", "grok"]);
  for (const row of report.sidecars) {
    assert.equal(typeof row.script, "string");
    assert.equal(typeof row.has_node_modules, "boolean");
  }
  assert.equal(r.status, report.ok ? 0 : 1);
});

test("doctor 在釘死 sidecar 來源時只認那個來源", () => {
  const s = makeSandbox();
  installFakeEngine(s.root, "claude", ECHO_SIDECAR);
  const r = spawnSync(process.execPath, [CLI, "doctor"], {
    encoding: "utf8", timeout: 30000,
    env: { ...process.env, TATWO_ENGINE_SIDECAR_ROOT: path.join(s.root, "Engines") },
  });
  const report = JSON.parse(r.stdout);
  const claude = report.sidecars.find((x) => x.engine === "claude");
  assert.ok(claude.script.startsWith(s.root), `應解析到沙箱：${claude.script}`);
});
