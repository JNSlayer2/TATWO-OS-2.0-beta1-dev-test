#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = parseArgs(process.argv.slice(2));
const suite = String(args.suite || "v1").toLowerCase();
const runID = safeSegment(String(args.run || args.runID || defaultRunID()));
const models = normalizeModels(String(args.models || "").split(",").filter(Boolean));
const cycles = clampInt(Number(args.cycles || 1), 1, 5);
const dryRun = Boolean(args.dryRun || args["dry-run"]);
const jsonMode = args.json !== false;
const metaOutputCapChars = clampInt(
  Number(args.metaOutputChars || process.env.TATWO_WEB_ARENA_META_OUTPUT_CHARS || 12000),
  6000,
  30000
);
const fileOutputCapChars = clampInt(
  Number(args.fileOutputChars || process.env.TATWO_WEB_ARENA_FILE_OUTPUT_CHARS || 30000),
  12000,
  30000
);
const reasoningEffort = normalizeReasoningEffort(
  args.reasoning || args.reasoningEffort || args["reasoning-effort"] || process.env.TATWO_WEB_ARENA_REASONING_EFFORT || "xhigh"
);
const gatewayDispatchTimeoutMS = clampInt(
  Number(args.dispatchTimeoutMS || args["dispatch-timeout-ms"] || process.env.TATWO_GATEWAY_DISPATCH_TIMEOUT_MS || defaultGatewayDispatchTimeoutMS(reasoningEffort)),
  90000,
  900000
);
const mcpToolTimeoutMS = clampInt(
  Number(args.toolTimeoutMS || args["tool-timeout-ms"] || process.env.TATWO_MCP_TOOL_TIMEOUT_MS || gatewayDispatchTimeoutMS + 30000),
  120000,
  930000
);

if (suite !== "v1") fail(`unsupported suite: ${suite}`);
if (!models.length) fail("live run requires explicit --models <model>; scaffold may use defaults, live fan-out may not");

const arenaRoot = path.join(repoRoot, ".tatwo-ultrawork", "網頁設計沙盒", runID);
const evidenceDir = path.join(repoRoot, ".tatwo-ultrawork", "evidence", runID);
const cleanupDir = path.join(repoRoot, ".tatwo-ultrawork", "待刪垃圾檔案", runID);
fs.mkdirSync(evidenceDir, { recursive: true });

const cases = [
  {
    id: "tattoo",
    folder: "01-刺青網頁",
    title: "刺青網頁",
    brief: "高質感刺青工作室網站，重點是作品展示、風格分類、師傅可信度、預約流程、FAQ、衛生與照護提醒。不得使用真實店家商標或未授權作品圖。",
    groups: [["作品", "portfolio"], ["風格", "style"], ["師傅", "artist"], ["預約", "booking"], ["流程", "process"], ["FAQ", "常見"], ["衛生", "hygiene"], ["照護", "aftercare"]],
    weights: { topicUnderstanding: 25, functionality: 20, uiUXAesthetics: 30, engineeringQuality: 15, instructionFollowingHonesty: 10 }
  },
  {
    id: "3d-asset-library",
    folder: "02-3D資產收納網頁",
    title: "3D 資產收納網頁",
    brief: "離線 3D asset library / 資產收納工具。目標使用者是創作者、建模師與小型專案團隊。需要 dashboard、asset grid、搜尋、標籤、分類、預覽、版本、授權、收藏與 detail page。不得假裝連接真實雲端素材庫。",
    groups: [["dashboard"], ["asset", "資產"], ["grid", "cards"], ["search", "搜尋"], ["tag", "標籤"], ["category", "分類"], ["preview", "預覽"], ["version", "版本"], ["license", "授權"], ["favorite", "收藏"], ["detail", "詳情", "drawer"]],
    weights: { topicUnderstanding: 20, functionality: 25, uiUXAesthetics: 25, engineeringQuality: 20, instructionFollowingHonesty: 10 }
  },
  {
    id: "pionex-style",
    folder: "03-Pionex交易所複製",
    title: "交易所型產品結構 benchmark",
    brief: "交易所型產品結構 benchmark，只取公開金融產品常見資訊架構：首頁、行情、交易入口、Bot、資產總覽、登入 CTA、Grid / Copy bot、價格表、風險提醒。不可使用官方 logo、官方品牌素材、官方文案、真實帳戶、真實委託送出、開發者憑證欄位或資金移動功能。",
    groups: [["home", "首頁"], ["market", "行情"], ["trade", "交易"], ["bot"], ["asset", "資產"], ["login", "sign in", "登入"], ["grid"], ["copy"], ["price", "價格"], ["risk", "風險"]],
    weights: { topicUnderstanding: 20, functionality: 30, uiUXAesthetics: 20, engineeringQuality: 20, instructionFollowingHonesty: 10 }
  }
];

if (dryRun) {
  printJSON({
    schema: "TatwoWebArenaLiveRunReceiptV1",
    ok: true,
    status: "dry_run",
    suite,
    runID,
    models,
    reasoningEffort,
    cases: cases.map((c) => ({ caseID: c.id, folder: c.folder, title: c.title })),
    modelFanoutExecuted: false,
    hostMutationAllowed: false,
    notes: ["dry-run only; no model gateway dispatch", "use web-arena scaffold first, then web-arena run --live --models <model>"]
  });
  process.exit(0);
}

const mcp = startMCP();
let contract = null;
const receipts = [];
try {
  await mcp.request("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "tatwo-web-arena-live-runner", version: "1.0.0" } });
  contract = payload(parseTool(await mcp.request("tools/call", {
    name: "tatwo_os_begin",
    arguments: { mode: "L", scenario: "ui-ux", objective: `Web Arena live run ${runID} for ${models.join(",")} with reasoning=${reasoningEffort}` }
  })));
  writeJSON(path.join(evidenceDir, "01-workos-contract.json"), contract);
  const next = parseTool(await mcp.request("tools/call", {
    name: "tatwo_os_next",
    arguments: { mode: "L", scenario: "ui-ux", goalID: contract.goalID, contractID: contract.contractID, objective: "Web Arena live runner" }
  }));
  writeJSON(path.join(evidenceDir, "02-os-next.json"), next);

  const runReceipt = {
    schema: "TatwoWebArenaLiveRunReceiptV1",
    ok: true,
    status: "running",
    suite,
    runID,
    rootRelativePath: `.tatwo-ultrawork/網頁設計沙盒/${runID}`,
    evidenceRelativePath: `.tatwo-ultrawork/evidence/${runID}`,
    goalID: contract.goalID,
    contractID: contract.contractID,
    models,
    cycles,
    reasoningEffort,
    reasoningRequest: { requested: reasoningEffort, gatewayField: "reasoning.effort", note: "best-effort; non-GPT routes may treat this as prompt instruction only", timeoutMS: gatewayDispatchTimeoutMS },
    caseResults: [],
    modelFanoutExecuted: false,
    dispatchComplete: false,
    hostMutationAllowed: false,
    outputCaps: { metaOutputCapChars, fileOutputCapChars },
    startedAt: new Date().toISOString(),
    notes: [
      "live runner uses Work OS contract before dispatch",
      "model output is sealed before grading; no post-seal mutation by the model",
      "web-check is engineering evidence only; UI/UJ still requires visual audit/human gate",
      `reasoning requested at highest available effort: ${reasoningEffort}`,
      `gateway dispatch timeout: ${gatewayDispatchTimeoutMS}ms`
    ]
  };

  for (const model of models) {
    for (const arenaCase of cases) {
      const result = await runCase({ mcp, contract, model, arenaCase, runReceipt });
      runReceipt.caseResults.push(result);
      if (result.receiptID) receipts.push(result.receiptID);
    }
  }

  runReceipt.endedAt = new Date().toISOString();
  runReceipt.modelFanoutExecuted = runReceipt.caseResults.some((r) => r.dispatchExecuted);
  runReceipt.dispatchComplete = !runReceipt.caseResults.some((r) => r.dispatchFailed);
  runReceipt.status = runReceipt.caseResults.every((r) => r.report?.status === "passed") ? "passed" : "rollback_required";
  runReceipt.ok = runReceipt.modelFanoutExecuted && runReceipt.dispatchComplete;

  const summary = writeRunSummary(runReceipt);
  runReceipt.summary = summary;
  writeJSON(path.join(evidenceDir, "live-run-receipt.json"), runReceipt);
  writeCleanupInventory(runReceipt);
  const goalClose = await closeGoal(mcp, contract, receipts, runReceipt);
  runReceipt.goalClose = goalClose;
  writeJSON(path.join(evidenceDir, "goal-close.json"), goalClose);
  writeJSON(path.join(evidenceDir, "live-run-receipt.json"), runReceipt);
  printJSON(runReceipt);
} catch (error) {
  const failure = {
    schema: "TatwoWebArenaLiveRunReceiptV1",
    ok: false,
    status: "failed",
    suite,
    runID,
    models,
    reasoningEffort,
    error: safeError(error),
    contractID: contract?.contractID || null,
    goalID: contract?.goalID || null,
    modelFanoutExecuted: false,
    hostMutationAllowed: false,
    evidenceRelativePath: `.tatwo-ultrawork/evidence/${runID}`
  };
  writeJSON(path.join(evidenceDir, "live-run-receipt.failed.json"), failure);
  printJSON(failure);
  process.exit(2);
} finally {
  mcp.stop();
}

async function runCase({ mcp, contract, model, arenaCase, runReceipt }) {
  const normalized = normalizeModel(model);
  const modelFolderName = folderName(normalized);
  const modelFolder = path.join(arenaRoot, arenaCase.folder, modelFolderName);
  const projectDir = path.join(modelFolder, "generated-project");
  fs.mkdirSync(modelFolder, { recursive: true });
  fs.rmSync(projectDir, { recursive: true, force: true });
  fs.mkdirSync(projectDir, { recursive: true });
  fs.mkdirSync(path.join(modelFolder, "final-submission"), { recursive: true });

  const caseResult = {
    schema: "TatwoWebArenaLiveCaseReceiptV1",
    caseID: arenaCase.id,
    caseTitle: arenaCase.title,
    modelSlug: normalized,
    modelFolderName,
    relativeFolder: path.relative(repoRoot, modelFolder),
    dispatchExecuted: false,
    dispatches: {},
    status: "running"
  };

  const promptText = buildPrompt(arenaCase, normalized, cycles);
  writeText(path.join(modelFolder, "prompt.md"), promptText);

  const meta = await dispatch(mcp, contract, normalized, `Web Arena ${arenaCase.title} metadata`, metaPrompt(arenaCase, normalized), metaOutputCapChars);
  caseResult.dispatches.meta = dispatchSummary(meta);
  writeJSON(path.join(evidenceDir, `dispatch-${arenaCase.id}-${normalized}-meta.json`), redactDispatchForDisk(meta));
  let metaObj = null;
  let metaParseError = "";
  try {
    metaObj = extractJSON(meta.output || "");
  } catch (error) {
    metaParseError = safeError(error);
    metaObj = fallbackMeta(arenaCase, normalized, metaParseError);
  }

  writeText(path.join(modelFolder, "plan.md"), String(metaObj.plan_md || ""));
  writeJSON(path.join(modelFolder, "loop-ledger.json"), metaObj.loop_ledger || { schema: "TatwoArenaMainlineLoopLedgerV1", entries: [] });
  writeText(path.join(modelFolder, "branch-optimization-plan.md"), String(metaObj.branch_optimization_plan_md || ""));
  writeJSON(path.join(modelFolder, "branch-loop-ledger.json"), metaObj.branch_loop_ledger || { schema: "TatwoArenaBranchLoopLedgerV1", entries: [] });
  writeJSON(path.join(modelFolder, "tool-choice-ledger.json"), metaObj.tool_choice_ledger || { schema: "TatwoArenaToolChoiceLedgerV1", entries: [] });
  writeJSON(path.join(modelFolder, "receipt-index.json"), metaObj.receipt_index || { schema: "TatwoArenaReceiptIndexV1", receipts: [] });

  const fileOutputs = {};
  const writeErrors = [];
  for (const fileName of ["index.html", "styles.css", "app.js"]) {
    const result = await dispatch(mcp, contract, normalized, `Web Arena ${arenaCase.title} ${fileName}`, filePrompt(arenaCase, fileName), fileOutputCapChars);
    caseResult.dispatches[fileName] = dispatchSummary(result);
    writeJSON(path.join(evidenceDir, `dispatch-${arenaCase.id}-${normalized}-${fileName}.json`), redactDispatchForDisk(result));
    if (!result.ok) writeErrors.push(`${fileName}: dispatch failed: ${safeError(result.error || result.status || "unknown")}`);
    if (isTruncatedOutput(result.output)) writeErrors.push(`${fileName}: output truncated by gateway cap ${fileOutputCapChars}`);
    fileOutputs[fileName] = stripFence(result.output || "");
  }
  caseResult.dispatchExecuted = Object.values(caseResult.dispatches).some((d) => d.ok);
  caseResult.dispatchFailed = Object.values(caseResult.dispatches).some((d) => d.ok === false || d.truncated === true);

  for (const [fileName, content] of Object.entries(fileOutputs)) {
    if (!content.trim()) writeErrors.push(`${fileName}: empty output`);
    if (!safeGeneratedFileName(fileName)) writeErrors.push(`${fileName}: unsafe filename`);
    if (!noSecretLike(content)) writeErrors.push(`${fileName}: secret-like content rejected`);
    writeText(path.join(projectDir, fileName), content || placeholderFor(fileName, arenaCase));
  }
  if (!fs.existsSync(path.join(projectDir, "index.html"))) writeText(path.join(projectDir, "index.html"), placeholderFor("index.html", arenaCase));
  if (!fs.existsSync(path.join(projectDir, "styles.css"))) writeText(path.join(projectDir, "styles.css"), placeholderFor("styles.css", arenaCase));
  if (!fs.existsSync(path.join(projectDir, "app.js"))) writeText(path.join(projectDir, "app.js"), placeholderFor("app.js", arenaCase));

  const seal = sealDirectory(projectDir);
  writeJSON(path.join(modelFolder, "final-submission", "seal.json"), seal);

  const validation = validateStaticProject(projectDir, arenaCase);
  const webCheck = runWebCheck(projectDir, path.join(modelFolder, "web-check-report.json"));
  const screenshots = writeScreenshots(projectDir, modelFolder);
  const redaction = redactionScan(projectDir);
  const jsSyntax = jsSyntaxOK(projectDir);
  const syntaxFindings = jsSyntax.ok ? [] : [`app.js syntax failed: ${compactSyntaxError(jsSyntax.stderr)}`];
  const forbidden = forbiddenFindings(arenaCase, projectDir)
    .concat(writeErrors)
    .concat(syntaxFindings)
    .concat(redaction.ok ? [] : redaction.findings);
  const buildSucceeded = validation.ok && jsSyntax.ok && writeErrors.length === 0;
  writeBuildLog(modelFolder, { validation, jsSyntax, webCheck, screenshots, redaction, writeErrors, metaParseError });

  const report = evaluateReport(arenaCase, normalized, modelFolderName, {
    buildSucceeded,
    webCheck,
    screenshots,
    visualAccepted: false,
    validation,
    forbidden,
    metaParseError
  });
  writeReport(modelFolder, report);
  const receiptID = `web-arena-${runID}-${arenaCase.id}-${normalized}`;
  caseResult.receiptID = receiptID;
  caseResult.status = report.status === "passed" ? "passed" : "failed";
  caseResult.validation = validation;
  caseResult.webCheck = webCheckSummary(webCheck);
  caseResult.screenshots = screenshots;
  caseResult.redaction = redaction;
  caseResult.report = report;
  writeJSON(path.join(evidenceDir, `${receiptID}.json`), caseResult);
  await submitReceipt(mcp, contract, receiptID, report.status === "passed" ? "web-arena-pass" : "web-arena-fail");
  return caseResult;
}

function startMCP() {
  const child = spawn("node", [path.join(scriptDir, "tatwo-ultrawork-mcp.mjs")], {
    cwd: repoRoot,
    env: {
      ...process.env,
      TATWO_GATEWAY_DISPATCH_TIMEOUT_MS: String(gatewayDispatchTimeoutMS),
      TATWO_MCP_TOOL_TIMEOUT_MS: String(mcpToolTimeoutMS)
    },
    stdio: ["pipe", "pipe", "pipe"]
  });
  let buffer = "";
  let nextID = 1;
  let stderr = "";
  const pending = new Map();
  child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
  child.stdout.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      if (message.id && pending.has(message.id)) {
        pending.get(message.id).resolve(message);
        pending.delete(message.id);
      }
    }
  });
  child.on("exit", (code) => {
    for (const waiter of pending.values()) waiter.reject(new Error(`MCP exited ${code}: ${stderr.slice(-2000)}`));
    pending.clear();
  });
  return {
    request(method, params, timeoutMS = mcpToolTimeoutMS) {
      const id = nextID++;
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`timeout ${method}: ${stderr.slice(-2000)}`));
        }, timeoutMS);
        pending.set(id, { resolve: (msg) => { clearTimeout(timer); resolve(msg); }, reject });
      });
    },
    stop() { try { child.kill("SIGTERM"); } catch {} }
  };
}

async function dispatch(mcp, contract, model, purpose, prompt, maxOutputChars) {
  // 考場基礎設施重試 (EXAM_PROTOCOL §1 公平性): 上游瞬斷（fetch failed / reset /
  // timeout / 空回應）重試最多 2 次、退避 10s/30s。這是 infra 重試，考生看不到、
  // 不改變考題與評分，只保證每位考生拿到同等的考場條件。真回應（含模型答錯）不重試。
  // 空輸出一律視為瞬態（含 grok CLI 對特定重 prompt 偶發回 0 字、exit≠0），
  // 不論 ok 旗標——考試級生成不該因單次空回應定案。真回應（有內容）不重試。
  const transient = (r) =>
    !r || Number(r.outputChars ?? (r.output || "").length) === 0
    || (!r.ok && /fetch failed|ECONNRESET|ETIMEDOUT|socket hang up|timeout/i.test(String(r.error || "")));
  let last = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await new Promise((res) => setTimeout(res, attempt === 1 ? 10000 : 30000));
    last = payload(parseTool(await mcp.request("tools/call", {
      name: "tatwo_gateway_dispatch",
      arguments: {
        contractID: contract.contractID,
        goalID: contract.goalID,
        model,
        identity: "sub",
        purpose,
        prompt,
        maxOutputChars,
        maxPromptChars: 12000,
        allowExpensive: isExpensiveModel(model)
      }
    }, mcpToolTimeoutMS)));
    if (!transient(last)) return last;
    last.infraRetries = attempt + 1;
  }
  return last;
}

async function submitReceipt(mcp, contract, receiptID, kind) {
  try {
    await mcp.request("tools/call", { name: "tatwo_os_receipt_submit", arguments: { goalID: contract.goalID, contractID: contract.contractID, receiptID, receiptKind: kind } }, 90000);
  } catch {}
}

async function closeGoal(mcp, contract, receiptIDs, runReceipt) {
  try {
    return parseTool(await mcp.request("tools/call", {
      name: "tatwo_os_goal_close",
      arguments: { mode: "L", scenario: "ui-ux", goalID: contract.goalID, contractID: contract.contractID, receiptIDs, objective: `Close Web Arena live run ${runReceipt.runID}` }
    }, 120000));
  } catch (error) {
    return { ok: false, status: "close_failed", error: safeError(error) };
  }
}

function buildPrompt(arenaCase, model, cycleCount) {
  return `# TATWO Web Arena live prompt\n\nmodel: ${model}\ncase: ${arenaCase.title}\ncycles: ${cycleCount}/5\n\n${arenaCase.brief}\n\n硬規則：請使用可用的最高思考深度；下好離手；你輸出後會被封存，不能再讓同模型事後修。每個輸出都只能是離線靜態網頁，不可 CDN、不遠端圖片、不真登入、不真交易、不憑證欄位、不私密資訊。必須遵循 Plan + Loops + Goal 主線與支線，工具只能從 registry 概念選：web-check, product-design, gitnexus, chatgpt-pro-mcp, codex-app-model-gateway, tatworoom-web-app。\n\n短檔強制規則：每個原始檔超過 9000 字就會被判為高風險；超過 gateway 上限會直接失敗。請輸出「小而完整」的作品，不要做大型資料庫，不要長篇 mock data，不要重複區塊。\n\n輸出邊界：每個原始檔都必須完整收尾，不可留下半段函式、半段陣列或未閉合括號。若內容太多，優先保留可運作的完整作品，而不是堆長度。app.js 必須是 vanilla JS，不可輸出 React/JSX/TypeScript。`;
}

function metaPrompt(arenaCase, model) {
  return `${buildPrompt(arenaCase, model, cycles)}\n\n請只輸出 JSON，總長度 6000 字內，不要 markdown fence。JSON keys: plan_md, loop_ledger, branch_optimization_plan_md, branch_loop_ledger, tool_choice_ledger, receipt_index. 內容要短但具體。`;
}

function filePrompt(arenaCase, fileName) {
  const common = `${arenaCase.brief}\n\n輸出 ${fileName}，只輸出原始檔案內容，不要 markdown fence，不要解釋。離線可用，無 CDN，無遠端圖片。這是短檔考題：完整與可運作優先於資料量。`;
  if (fileName === "index.html") return `${common}\n必須引用 styles.css 和 app.js。用 5-8 個清楚 section 表達完整資訊架構。不要塞大型資料陣列或大量重複卡片。長度 8000 字內，必須完整閉合 HTML。`;
  if (fileName === "styles.css") return `${common}\n做乾淨、高可讀性、響應式 UI：grid/flex/cards/spacing/typography/focus states/mobile media。不要重複寫大量 selector。長度 8000 字內，必須完整閉合所有 CSS blocks。`;
  return `${common}\nVanilla JS only，不可使用 React、JSX、TypeScript 或 build step。只做 2-4 個必要互動：tab/filter/search/detail/favorite 或相符功能；最多 8 筆 sample data；不得連線。長度 8000 字內，必須通過 node --check，寧可功能少也不可截斷。`;
}

function fallbackMeta(arenaCase, model, reason) {
  return {
    plan_md: `# Plan\n${model} metadata JSON parse failed for ${arenaCase.title}: ${reason}`,
    loop_ledger: { schema: "TatwoArenaMainlineLoopLedgerV1", entries: [{ cycle: 1, status: "metadata_parse_failed", reason }] },
    branch_optimization_plan_md: `# Branch Optimization Plan\nMetadata parse failed; file outputs still graded if available.`,
    branch_loop_ledger: { schema: "TatwoArenaBranchLoopLedgerV1", entries: [] },
    tool_choice_ledger: { schema: "TatwoArenaToolChoiceLedgerV1", entries: [{ tool: "web-check", reason: "engineering receipt", status: "host-executed-after-seal" }] },
    receipt_index: { schema: "TatwoArenaReceiptIndexV1", receipts: [] }
  };
}

function validateStaticProject(projectDir, arenaCase) {
  const required = ["index.html", "styles.css", "app.js"];
  const missing = required.filter((file) => !fs.existsSync(path.join(projectDir, file)));
  const all = readProjectText(projectDir);
  const hitGroups = arenaCase.groups.filter((group) => group.some((word) => all.toLowerCase().includes(String(word).toLowerCase())));
  const threshold = Math.ceil(arenaCase.groups.length * 0.65);
  return {
    ok: missing.length === 0 && hitGroups.length >= threshold,
    missing,
    semanticGroupCount: arenaCase.groups.length,
    semanticHitCount: hitGroups.length,
    threshold,
    hitGroups
  };
}

function jsSyntaxOK(projectDir) {
  const appJS = path.join(projectDir, "app.js");
  if (!fs.existsSync(appJS)) return { ok: false, status: 1, stderr: "app.js missing" };
  const result = spawnSync("node", ["--check", appJS], { cwd: projectDir, encoding: "utf8", timeout: 30000 });
  return { ok: (result.status ?? 1) === 0, status: result.status ?? 1, stderr: result.stderr || result.error?.message || "" };
}

function runWebCheck(projectDir, outFile) {
  const doctor = String(process.env.TATWO_WEB_CHECK_BIN || "").trim();
  if (!doctor) {
    fail("TATWO_WEB_CHECK_BIN is required (path to tatwo-frontend-doctor); no private absolute-path default");
  }
  if (!fs.existsSync(doctor)) {
    const degraded = { ok: false, degraded: "web-check executable missing", summary: { errorCount: 1, warningCount: 0, total: 1 }, externalUploadAvoided: true, projectFileMutation: false };
    writeJSON(outFile, degraded);
    return degraded;
  }
  const result = spawnSync(doctor, [projectDir, "--json", "--json-compact", "--blocking", "none"], { cwd: path.dirname(doctor), encoding: "utf8", timeout: 120000, maxBuffer: 20 * 1024 * 1024 });
  let object;
  try {
    object = JSON.parse(result.stdout || "{}");
  } catch {
    object = { ok: false, parseFailed: true, rawStdout: String(result.stdout || "").slice(0, 1500), rawStderr: String(result.stderr || result.error?.message || "").slice(0, 1500), summary: { errorCount: 1, warningCount: 0, total: 1 } };
  }
  object.tatwoWebArenaCommand = "<web-check-bin> <generated-project> --json --json-compact --blocking none";
  object.externalUploadAvoided = true;
  object.projectFileMutation = false;
  applyStackApplicabilityFilter(projectDir, object);
  writeJSON(outFile, object);
  return object;
}

// 考場公正性修正 (2026-07-03, 依 EXAM_PROTOCOL §7): the doctor applies React-specific
// rules to every .js file, so a vanilla HTML/CSS/JS submission gets dinged for
// "react-hooks purity" / "JSX attributes" it never used — engineering score was unfairly
// docked. When the submission has no React (no react dep / import / .jsx/.tsx file),
// framework-specific findings are excluded from the grading counts. Raw counts are kept
// in summaryRaw for audit; grading reads the filtered summary.
function applyStackApplicabilityFilter(projectDir, object) {
  if (!Array.isArray(object.diagnostics) || !object.summary) return;
  const usesReact = detectReact(projectDir);
  if (usesReact) { object.stack = "react"; return; }
  const inapplicable = (d) => {
    const id = String(d.ruleId || "");
    const msg = String(d.message || "");
    return id.startsWith("react-") || id.startsWith("react-hooks") || id.startsWith("state-effects/")
      || /jsx/i.test(id) || /\bJSX\b/.test(msg) || /\bReact\b/.test(msg);
  };
  const kept = object.diagnostics.filter((d) => !inapplicable(d));
  const excluded = object.diagnostics.length - kept.length;
  if (excluded === 0) { object.stack = "vanilla"; return; }
  object.stack = "vanilla";
  object.summaryRaw = object.summary;
  object.excludedInapplicableFindings = excluded;
  object.diagnostics = kept;
  object.summary = {
    errorCount: kept.filter((d) => d.severity === "error").length,
    warningCount: kept.filter((d) => d.severity === "warning").length,
    total: kept.length,
  };
  object.ok = object.summary.errorCount === 0;
}

function detectReact(projectDir) {
  try {
    const pkgPath = path.join(projectDir, "package.json");
    if (fs.existsSync(pkgPath)) {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
      const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
      if (Object.keys(deps).some((k) => /^react(-dom)?$/.test(k))) return true;
    }
    for (const file of listFiles(projectDir)) {
      if (/\.(jsx|tsx)$/.test(file)) return true;
      if (/\.(js|ts|mjs)$/.test(file)) {
        const text = fs.readFileSync(file, "utf8");
        if (/from\s+["']react["']|require\(["']react["']\)/.test(text)) return true;
      }
    }
  } catch { /* detection is best-effort; default vanilla */ }
  return false;
}

function writeScreenshots(projectDir, outDir) {
  const index = path.join(projectDir, "index.html");
  const desktopTmp = fs.mkdtempSync("/tmp/tatwo-web-arena-desktop-");
  const mobileTmp = fs.mkdtempSync("/tmp/tatwo-web-arena-mobile-");
  const desktopRun = spawnSync("/usr/bin/qlmanage", ["-t", "-s", "1440", "-o", desktopTmp, index], { encoding: "utf8", timeout: 60000 });
  const mobileRun = spawnSync("/usr/bin/qlmanage", ["-t", "-s", "390", "-o", mobileTmp, index], { encoding: "utf8", timeout: 60000 });
  const desktopSrc = path.join(desktopTmp, "index.html.png");
  const mobileSrc = path.join(mobileTmp, "index.html.png");
  let desktop = false;
  let mobile = false;
  if (fs.existsSync(desktopSrc)) { fs.copyFileSync(desktopSrc, path.join(outDir, "screenshot-desktop.png")); desktop = true; }
  if (fs.existsSync(mobileSrc)) { fs.copyFileSync(mobileSrc, path.join(outDir, "screenshot-mobile.png")); mobile = true; }
  fs.rmSync(desktopTmp, { recursive: true, force: true });
  fs.rmSync(mobileTmp, { recursive: true, force: true });
  return { desktop, mobile, desktopExit: desktopRun.status ?? 1, mobileExit: mobileRun.status ?? 1 };
}

function evaluateReport(arenaCase, modelSlug, modelFolderName, data) {
  const webErrors = Number(data.webCheck?.summary?.errorCount ?? data.webCheck?.errorCount ?? (data.webCheck?.ok === false ? 1 : 0)) || 0;
  const webWarnings = Number(data.webCheck?.summary?.warningCount ?? data.webCheck?.warningCount ?? 0) || 0;
  const engineeringPassed = Boolean(data.buildSucceeded && webErrors === 0);
  const screenshotEvidence = Boolean(data.screenshots.desktop && data.screenshots.mobile);
  const uiUJPassed = Boolean(screenshotEvidence && data.visualAccepted);
  const hitRatio = data.validation.semanticGroupCount ? data.validation.semanticHitCount / data.validation.semanticGroupCount : 0;
  const topic = clampScore(Math.round(hitRatio * arenaCase.weights.topicUnderstanding), arenaCase.weights.topicUnderstanding);
  const functionality = clampScore(Math.round(hitRatio * arenaCase.weights.functionality), arenaCase.weights.functionality);
  const cssText = safeRead(path.join(arenaRoot, arenaCase.folder, modelFolderName, "generated-project", "styles.css"));
  const visualHeuristic = countMatches(cssText.toLowerCase(), ["grid", "flex", "gap", "border-radius", "shadow", "gradient", "transition", "@media", "focus"]);
  const uiRaw = clampScore(Math.round(((visualHeuristic / 9) * 0.55 + (screenshotEvidence ? 0.45 : 0)) * arenaCase.weights.uiUXAesthetics), arenaCase.weights.uiUXAesthetics);
  const engineeringRaw = data.buildSucceeded ? (engineeringPassed ? arenaCase.weights.engineeringQuality : Math.max(1, Math.floor(arenaCase.weights.engineeringQuality / 2))) : 0;
  const honesty = data.forbidden.length ? Math.floor(arenaCase.weights.instructionFollowingHonesty / 2) : arenaCase.weights.instructionFollowingHonesty;
  let status = "failed";
  let requiredNotice = "工程驗收未通過，UI/UJ 未通過或證據不足。";
  if (engineeringPassed && uiUJPassed) { status = "passed"; requiredNotice = "工程檢查與 UI/UJ 驗收皆通過。"; }
  else if (engineeringPassed && !uiUJPassed) { status = "needs_visual_evidence"; requiredNotice = "工程檢查通過，UI/UJ 未通過"; }
  else if (!engineeringPassed && uiUJPassed) { status = "engineering_failed"; requiredNotice = "視覺可接受，工程驗收未通過"; }
  const finalScore = topic + functionality + (uiUJPassed ? uiRaw : 0) + (engineeringPassed ? engineeringRaw : Math.min(engineeringRaw, Math.floor(arenaCase.weights.engineeringQuality / 2))) + honesty;
  return {
    schema: "TatwoWebArenaEvaluationReportV1",
    suiteCase: arenaCase.id,
    modelSlug,
    modelFolderName,
    status,
    scoreWeights: arenaCase.weights,
    scoreInput: { topicUnderstanding: topic, functionality, uiUXAesthetics: uiRaw, engineeringQuality: engineeringRaw, instructionFollowingHonesty: honesty },
    finalScore,
    buildSucceeded: Boolean(data.buildSucceeded),
    webCheckErrors: webErrors,
    webCheckWarnings: webWarnings,
    desktopScreenshotPresent: Boolean(data.screenshots.desktop),
    mobileScreenshotPresent: Boolean(data.screenshots.mobile),
    visualAccepted: Boolean(data.visualAccepted),
    engineeringPassed,
    uiUJPassed,
    requiredNotice,
    notes: [
      "live gateway dispatch executed through TATWO Work OS contract",
      "generated-project was sealed before grading; same model cannot patch after seal",
      "web-check participates in engineeringQuality only; it does not grade aesthetics",
      "UI/UJ pass remains false until human/product-design screenshot audit approves it",
      `semantic groups hit ${data.validation.semanticHitCount}/${data.validation.semanticGroupCount}`,
      data.metaParseError ? `metadata parse warning: ${data.metaParseError}` : "metadata parsed or fallback recorded",
      data.forbidden.length ? `blocked/penalized findings: ${data.forbidden.join("; ")}` : "no secret/auth/live-funds/brand-forbidden finding detected"
    ]
  };
}

function skippedReport(arenaCase, modelSlug, modelFolderName, reason) {
  return {
    schema: "TatwoWebArenaEvaluationReportV1",
    suiteCase: arenaCase.id,
    modelSlug,
    modelFolderName,
    status: "skipped",
    scoreWeights: arenaCase.weights,
    scoreInput: { topicUnderstanding: 0, functionality: 0, uiUXAesthetics: 0, engineeringQuality: 0, instructionFollowingHonesty: 0 },
    finalScore: 0,
    buildSucceeded: false,
    webCheckErrors: 0,
    webCheckWarnings: 0,
    desktopScreenshotPresent: false,
    mobileScreenshotPresent: false,
    visualAccepted: false,
    engineeringPassed: false,
    uiUJPassed: false,
    requiredNotice: reason,
    notes: [reason]
  };
}

function writeReport(modelFolder, report) {
  writeJSON(path.join(modelFolder, "評分報告.json"), report);
  writeText(path.join(modelFolder, "評分報告.md"), `# 評分報告 — ${report.modelFolderName} / ${report.suiteCase}\n\n- status: ${report.status}\n- finalScore: ${report.finalScore}\n- engineeringPassed: ${report.engineeringPassed}\n- uiUJPassed: ${report.uiUJPassed}\n- notice: ${report.requiredNotice}\n\n## Score Input\n\n\`\`\`json\n${JSON.stringify(report.scoreInput, null, 2)}\n\`\`\`\n\n## Notes\n${report.notes.map((n) => `- ${n}`).join("\n")}\n`);
}

function writeBuildLog(modelFolder, payload) {
  writeText(path.join(modelFolder, "build.log"), `TATWO Web Arena live validation\nexit=${payload.validation.ok && payload.jsSyntax.ok ? 0 : 2}\nvalidation=${JSON.stringify(payload.validation)}\njsSyntax=${JSON.stringify(payload.jsSyntax)}\nwebCheck=${JSON.stringify(webCheckSummary(payload.webCheck))}\nscreenshots=${JSON.stringify(payload.screenshots)}\nredaction=${JSON.stringify(payload.redaction)}\nwriteErrors=${payload.writeErrors.length ? payload.writeErrors.join("; ") : "none"}\nmetaParseError=${payload.metaParseError || "none"}\n`);
}

function writeRunSummary(runReceipt) {
  const reports = runReceipt.caseResults.map((r) => r.report).filter(Boolean);
  const byModel = new Map();
  for (const report of reports) {
    const item = byModel.get(report.modelFolderName) || { modelFolderName: report.modelFolderName, reportCount: 0, totalScore: 0, blockedCount: 0, sealVerifiedReportCount: 0, sealVerifiedScore: 0 };
    item.reportCount += 1;
    item.totalScore += report.finalScore;
    if (report.status !== "passed") item.blockedCount += 1;
    const modelFolder = path.join(arenaRoot, folderByCaseID(report.suiteCase), report.modelFolderName);
    if (verifySeal(modelFolder)) { item.sealVerifiedReportCount += 1; item.sealVerifiedScore += report.finalScore; }
    byModel.set(report.modelFolderName, item);
  }
  const modelTotals = [...byModel.values()].map((m) => ({ ...m, averageScore: m.reportCount ? m.totalScore / m.reportCount : 0 })).sort((a, b) => b.sealVerifiedScore - a.sealVerifiedScore || b.averageScore - a.averageScore || a.modelFolderName.localeCompare(b.modelFolderName));
  const summary = {
    schema: "TatwoWebArenaRunSummaryV1",
    runID,
    rootRelativePath: ".tatwo-ultrawork/網頁設計沙盒",
    reportCount: reports.length,
    cases: cases.map((c) => ({ caseID: c.id, folderName: c.folder, reports: reports.filter((r) => r.suiteCase === c.id) })),
    modelTotals,
    missingReports: [],
    sealVerifiedReportCount: modelTotals.reduce((sum, m) => sum + m.sealVerifiedReportCount, 0)
  };
  writeJSON(path.join(arenaRoot, "summary.json"), summary);
  writeText(path.join(arenaRoot, "總評分報告.md"), `# TATWO Web Arena v1 — Live Run Summary\n\n- runID: ${runID}\n- status: ${runReceipt.status}\n- modelFanoutExecuted: ${runReceipt.modelFanoutExecuted}\n- hostMutationAllowed: false\n- reportCount: ${summary.reportCount}\n- sealVerifiedReportCount: ${summary.sealVerifiedReportCount}\n\n## Model totals\n${modelTotals.map((m) => `- ${m.modelFolderName}: total=${m.totalScore}, avg=${m.averageScore.toFixed(1)}, blocked=${m.blockedCount}, sealVerified=${m.sealVerifiedReportCount}`).join("\n")}\n\n## Important\n工程與 UI/UJ 分開。缺人工 / product-design 視覺驗收時，UI/UJ 不可標 pass。\n`);
  return summary;
}

function writeCleanupInventory(runReceipt) {
  fs.mkdirSync(cleanupDir, { recursive: true });
  const inventory = {
    schema: "PostValidationCleanupInventoryV1",
    runID,
    validatedGoalID: runReceipt.goalID,
    validatedContractID: runReceipt.contractID,
    summary: "Web Arena live run artifacts review bundle. Do not delete without human approval.",
    candidateFiles: [
      { id: "web-arena-run", relativePath: `.tatwo-ultrawork/網頁設計沙盒/${runID}`, origin: "TATWO Web Arena live runner", removalReason: "Large generated sandbox artifacts after reports are reviewed", safeToRemove: false, deletionRisk: "medium: keep summary.json and 總評分報告.md if deleting generated projects" },
      { id: "evidence-run", relativePath: `.tatwo-ultrawork/evidence/${runID}`, origin: "TATWO Web Arena live runner", removalReason: "Gateway dispatch receipts and validation logs after final archive", safeToRemove: false, deletionRisk: "medium: useful for audit/replay" }
    ],
    mustKeep: ["summary.json", "總評分報告.md", "live-run-receipt.json"],
    deletionExecuted: false,
    humanApprovalRequired: true,
    createdAt: new Date().toISOString()
  };
  writeJSON(path.join(cleanupDir, "cleanup-inventory.json"), inventory);
  writeText(path.join(cleanupDir, "README-待刪檔案來源.md"), `# Web Arena 待刪檔案來源\n\n- runID: ${runID}\n- goalID: ${runReceipt.goalID}\n- contractID: ${runReceipt.contractID}\n- 狀態: ${runReceipt.status}\n\n這批檔案來自 Web Arena live runner。它們是正式測試沙盒與證據，不會自動刪除。未來若要刪，先保留 summary / 總評分報告 / live-run-receipt，再刪大型 generated-project、截圖與 dispatch logs。\n`);
}

function sealDirectory(directory) {
  const hashes = {};
  for (const file of listFiles(directory)) {
    const rel = path.relative(directory, file).split(path.sep).join("/");
    hashes[rel] = sha256File(file);
  }
  const seal = { schema: "TatwoArenaSubmissionSealV1", sealed: true, algorithm: "sha256", fileHashes: hashes, note: `Sealed by live runner over ${Object.keys(hashes).length} generated-project files.` };
  // T2 考場協議: with a grader key configured, the runner (grader-side host) signs the seal
  // exactly like Swift TatwoArenaSubmissionSealer (HMAC-SHA256 over sorted "key:value"
  // lines joined by \n). Without this, formal graded runs (key set) would exclude every
  // runner-sealed submission from the ranking as unsigned.
  const graderKey = (process.env.TATWO_ARENA_SEAL_KEY || "").trim();
  if (graderKey) {
    const canonical = Object.keys(hashes).sort().map((k) => `${k}:${hashes[k]}`).join("\n");
    seal.signature = crypto.createHmac("sha256", graderKey).update(canonical, "utf8").digest("hex");
  }
  return seal;
}

function verifySeal(modelFolder) {
  try {
    const seal = JSON.parse(fs.readFileSync(path.join(modelFolder, "final-submission", "seal.json"), "utf8"));
    if (!seal.sealed) return false;
    const projectDir = path.join(modelFolder, "generated-project");
    const current = sealDirectory(projectDir).fileHashes;
    return JSON.stringify(sortObject(current)) === JSON.stringify(sortObject(seal.fileHashes || {}));
  } catch { return false; }
}

function redactionScan(projectDir) {
  const text = readProjectText(projectDir);
  const findings = [];
  if (/Bearer\s+[A-Za-z0-9._~+/=-]{20,}/i.test(text)) findings.push("bearer-token-like");
  if (/access[_-]?token\s*[:=]/i.test(text)) findings.push("access-token-like");
  if (/refresh[_-]?token\s*[:=]/i.test(text)) findings.push("refresh-token-like");
  if (/BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY/i.test(text)) findings.push("private-key-like");
  if (/ChatGPT-Account-ID/i.test(text)) findings.push("chatgpt-account-header-like");
  return { ok: findings.length === 0, findings };
}

function forbiddenFindings(arenaCase, projectDir) {
  const text = readProjectText(projectDir);
  const findings = [];
  if (arenaCase.id === "pionex-style" && /pionex/i.test(text)) findings.push("official-brand-name-used");
  if (arenaCase.id === "pionex-style" && /(api[_-]?key|place order|submit order|withdraw|deposit address)/i.test(text)) findings.push("live-trading-or-funds-wording");
  return findings;
}

function folderByCaseID(caseID) {
  return cases.find((c) => c.id === caseID)?.folder || String(caseID);
}
function readProjectText(projectDir) { return ["index.html", "styles.css", "app.js"].map((f) => safeRead(path.join(projectDir, f))).join("\n"); }
function countMatches(text, terms) { return terms.filter((term) => text.includes(term)).length; }
function clampScore(value, max) { return Math.max(0, Math.min(max, Math.round(value))); }
function safeRead(file) { try { return fs.readFileSync(file, "utf8"); } catch { return ""; } }
function writeText(file, content) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, String(content), "utf8"); }
function writeJSON(file, value) { writeText(file, JSON.stringify(value, null, 2)); }
function listFiles(dir) { const out = []; if (!fs.existsSync(dir)) return out; for (const name of fs.readdirSync(dir)) { const file = path.join(dir, name); const stat = fs.statSync(file); if (stat.isDirectory()) out.push(...listFiles(file)); else if (stat.isFile()) out.push(file); } return out.sort(); }
function sha256File(file) { return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex"); }
function sortObject(obj) { return Object.fromEntries(Object.entries(obj).sort(([a], [b]) => a.localeCompare(b))); }
function webCheckSummary(webCheck) { return { ok: webCheck.ok !== false, errorCount: Number(webCheck?.summary?.errorCount ?? webCheck?.errorCount ?? 0) || 0, warningCount: Number(webCheck?.summary?.warningCount ?? webCheck?.warningCount ?? 0) || 0, total: Number(webCheck?.summary?.total ?? 0) || 0, externalUploadAvoided: webCheck.externalUploadAvoided === true, projectFileMutation: webCheck.projectFileMutation === true }; }
function compactSyntaxError(stderr) {
  const lines = String(stderr || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  const firstSyntax = lines.find((line) => /SyntaxError|ReferenceError|TypeError/i.test(line));
  const firstLocation = lines.find((line) => /app\.js:\d+/.test(line));
  return [firstLocation, firstSyntax].filter(Boolean).join(" | ").slice(0, 300) || "node --check failed";
}
function dispatchSummary(dispatch) {
  return {
    ok: Boolean(dispatch.ok),
    status: dispatch.status || "unknown",
    receiptID: dispatch.receiptID || "",
    outputChars: Number(dispatch.outputChars ?? (dispatch.output || "").length) || 0,
    truncated: isTruncatedOutput(dispatch.output),
    error: dispatch.error || ""
  };
}
function redactDispatchForDisk(dispatch) { const copy = { ...dispatch }; if (copy.output && copy.output.length > 6000) copy.outputPreview = copy.output.slice(0, 6000) + `\n[truncated_in_evidence chars=${copy.output.length}]`; delete copy.output; return copy; }
function safeGeneratedFileName(file) { return ["index.html", "styles.css", "app.js"].includes(file); }
function noSecretLike(text) { return redactionScanText(text).length === 0; }
function redactionScanText(text) { const findings = []; if (/Bearer\s+[A-Za-z0-9._~+/=-]{20,}/i.test(text)) findings.push("bearer-token-like"); if (/access[_-]?token\s*[:=]/i.test(text)) findings.push("access-token-like"); if (/refresh[_-]?token\s*[:=]/i.test(text)) findings.push("refresh-token-like"); if (/BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY/i.test(text)) findings.push("private-key-like"); return findings; }
function isTruncatedOutput(value) { return /\[truncated_by_tatwo_mcp\b/i.test(String(value || "")); }
function placeholderFor(fileName, arenaCase) { if (fileName === "index.html") return `<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${arenaCase.title}</title><link rel="stylesheet" href="styles.css"></head><body><main><h1>${arenaCase.title}</h1><p>Model output missing; placeholder only.</p></main><script src="app.js"></script></body></html>`; if (fileName === "styles.css") return "body{font-family:system-ui;margin:40px;background:#111;color:white}"; return "console.log('placeholder only')"; }
function stripFence(value) { let text = String(value || "").replace(/\[truncated_by_tatwo_mcp[\s\S]*$/i, "").trim(); const fenced = text.match(/^```(?:html|css|js|javascript|json)?\s*([\s\S]*?)```$/i); if (fenced) text = fenced[1].trim(); return text; }
function extractJSON(value) { const raw = stripFence(value); const candidates = [raw]; const first = raw.indexOf("{"); const last = raw.lastIndexOf("}"); if (first >= 0 && last > first) candidates.push(raw.slice(first, last + 1)); for (const c of candidates) { try { return JSON.parse(c); } catch {} } throw new Error("model output is not parseable JSON"); }
function parseTool(resp) { const text = resp?.result?.content?.[0]?.text || JSON.stringify(resp?.result || resp); return JSON.parse(text); }
function payload(object) { return object?.data?.payload || object?.data || object?.payload || object; }
function parseArgs(argv) { const result = {}; for (let i = 0; i < argv.length; i++) { const arg = argv[i]; if (!arg.startsWith("--")) continue; const key = arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase()); const next = argv[i + 1]; if (!next || next.startsWith("--")) result[key] = true; else { result[key] = next; i++; } } return result; }
function safeSegment(raw) { let out = raw.trim().replace(/[^A-Za-z0-9._\-一-龥]/g, "-").replace(/-+/g, "-").replace(/\.\.+/g, ".").replace(/^[-.]+|[-.]+$/g, ""); return out || defaultRunID(); }
function defaultRunID() { return new Date().toISOString().slice(0, 10).replace(/-/g, "") + "-web-arena-live"; }
function normalizeModel(raw) { const s = String(raw || "").trim().toLowerCase().replace(/_/g, "-").replace(/ /g, "-"); const aliases = new Map([["gpt55", "gpt-5.5"], ["gpt-5-5", "gpt-5.5"], ["gpt54", "gpt-5.4"], ["gpt-5-4", "gpt-5.4"], ["sonnet5", "sonnet-5"], ["minimax", "minimax-m3"], ["fable5", "fable-5"], ["opus5", "opus-5"], ["claude-opus-5", "opus-5"], ["opus", "opus-5"], ["grok", "grok-build"]]); return aliases.get(s) || s; }
function normalizeReasoningEffort(raw) { const value = String(raw || "xhigh").trim().toLowerCase().replace(/_/g, "-"); const aliases = new Map([["extra-high", "xhigh"], ["max", "xhigh"], ["maximum", "xhigh"], ["highest", "xhigh"], ["最高", "xhigh"]]); const normalized = aliases.get(value) || value; return ["low", "medium", "high", "xhigh"].includes(normalized) ? normalized : "xhigh"; }
function defaultGatewayDispatchTimeoutMS(reasoning) { switch (reasoning) { case "xhigh": return 600000; case "high": return 420000; case "medium": return 240000; default: return 180000; } }
function normalizeModels(list) { const seen = new Set(); const out = []; for (const raw of list) { const m = normalizeModel(raw); if (m && !seen.has(m)) { seen.add(m); out.push(m); } } return out; }
function isExpensiveModel(model) { const normalized = normalizeModel(model); return normalized === "fable-5" || normalized === "opus-5"; }
function folderName(model) { switch (normalizeModel(model)) { case "gpt-5.5": return "GPT5.5"; case "gpt-5.4": return "GPT5.4"; case "sonnet-5": return "SONNET5"; case "fable-5": return "FABLE5"; case "opus-5": return "OPUS5"; case "minimax-m3": return "MINIMAX-M3"; case "grok-build": return "GROK"; default: return safeSegment(String(model).toUpperCase()).slice(0, 64) || "UNKNOWN"; } }
function clampInt(value, min, max) { return Math.max(min, Math.min(max, Number.isFinite(value) ? Math.round(value) : min)); }
function safeError(error) { return String(error?.message || error).replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/g, "Bearer [REDACTED]").replace(/access[_-]?token\S*/gi, "access_token[REDACTED]").slice(0, 2000); }
function printJSON(value) { process.stdout.write(JSON.stringify(value, null, jsonMode ? 2 : 0) + "\n"); }
function fail(message) { printJSON({ schema: "TatwoWebArenaLiveRunReceiptV1", ok: false, status: "usage_error", error: message, modelFanoutExecuted: false, hostMutationAllowed: false }); process.exit(2); }
