#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(__filename), "..");
const arenaRoot = path.join(repoRoot, ".tatwo-ultrawork", "3D測試", "模型");
const defaultContractID = "contract-xl-modeling-034c2bbb340e";
const defaultGoalID = "goal-xl-modeling-034c2bbb340e";

const cases = [
  {
    id: "vision-pro-xinjiang-360",
    folderName: "01-VisionPro新疆360",
    title: "Vision Pro 新疆 360 沉浸式全景",
    purpose: "測模型能否把真實地貌、360 全景規格、Blender 場景與 Apple/Vision Pro 交換格式分清楚並做成可驗收作品。",
    requiredArtifacts: [
      "generated-artifacts/作品/Blender/q1_xinjiang_360/scene.blend",
      "generated-artifacts/作品/Blender/q1_xinjiang_360/renders/pano_360.png",
      "generated-artifacts/作品/Blender/q1_xinjiang_360/exports/scene.glb",
      "generated-artifacts/作品/Blender/q1_xinjiang_360/exports/scene.usdz",
      "generated-artifacts/作品/Blender/q1_xinjiang_360/render_settings.json",
      "generated-artifacts/作品/Blender/q1_xinjiang_360/NOTES.md"
    ],
    optionalArtifacts: [
      "generated-artifacts/作品/Blender/q1_xinjiang_360/renders/pano_360.exr",
      "generated-artifacts/作品/Blender/q1_xinjiang_360/renders/pano_360.hdr"
    ],
    rubric: [
      ["場景內容", 25, "至少 3 類可辨識新疆元素，且不是空場景或貼圖假圖。"],
      ["360 技術正確", 25, "Camera=PANO/EQUIRECTANGULAR；PNG 2:1；解析度至少 4096x2048。"],
      ["渲染品質", 20, "光照、材質、構圖、左右接縫連續。"],
      ["匯出完整", 15, ".glb 可載入，.usdz 存在且非空。"],
      ["文件誠實", 15, "render_settings 與 .blend 一致；不得聲稱未驗證 visionOS 27 功能。"]
    ],
    prompt: `Q1｜Vision Pro 新疆 360 全景\n- 在 Blender 建立新疆主題 3D 場景，至少 3 類可辨識元素，例如天山雪峰、戈壁、綠洲/胡楊林、維吾爾建築語彙。\n- 使用 Panoramic / Equirectangular camera，輸出 2:1 PNG，目標至少 4096x2048；可加 EXR/HDR。\n- 交付 .blend、.glb、.usdz、render_settings.json、NOTES.md。\n- NOTES.md 只能保守說明：官方可確認 visionOS 26 支援 180/360/wide-FOV content；不得聲稱未查證的 visionOS 27 能力。\n- 不能用下載照片冒充 3D 場景；.blend 內的幾何、材質、燈光與 render 內容需能互相對應。`
  },
  {
    id: "original-mmd-character",
    folderName: "02-原創MMD角色",
    title: "原創 MMD / VTuber 角色",
    purpose: "測模型能否建立不抄襲的 anime/MMD 角色方向，並清楚交代 rig、shapekey、材質與後續 VRM/PMX readiness。",
    requiredArtifacts: [
      "generated-artifacts/作品/Blender/q2_mmd_character/character.blend",
      "generated-artifacts/作品/Blender/q2_mmd_character/exports/character.glb",
      "generated-artifacts/作品/Blender/q2_mmd_character/turntable/front.png",
      "generated-artifacts/作品/Blender/q2_mmd_character/turntable/side.png",
      "generated-artifacts/作品/Blender/q2_mmd_character/turntable/back.png",
      "generated-artifacts/作品/Blender/q2_mmd_character/turntable/face_closeup.png",
      "generated-artifacts/作品/Blender/q2_mmd_character/rig_readiness.md",
      "generated-artifacts/作品/Blender/q2_mmd_character/originality.md"
    ],
    optionalArtifacts: [
      "generated-artifacts/作品/Blender/q2_mmd_character/exports/character.vrm",
      "generated-artifacts/作品/Blender/q2_mmd_character/exports/character.pmx"
    ],
    rubric: [
      ["角色完成度", 25, "頭身、髮型、服裝、表情區域完整，非 primitive 拼接示意。"],
      ["風格與原創", 25, "MMD/VTuber 方向明確；只參考品質層級，不挪用鳴潮角色/IP。"],
      ["Rig readiness", 20, "armature/bone 命名、shapekey/表情、weight 狀態如實記錄。"],
      ["材質與渲染", 15, "材質分層合理，四視圖清楚。"],
      ["匯出與誠實", 15, ".glb 有效；VRM/PMX 有就附檔，沒有就說明原因，不假裝。"]
    ],
    prompt: `Q2｜原創 MMD 角色\n- 建立原創 anime/MMD/VTuber 風格角色。\n- 可參考鳴潮的高層品質感：服裝層次、髮型精度、材質節奏、幻想科幻氣質；嚴禁複製角色、服裝輪廓、武器、logo、名稱與文案。\n- 交付 character.blend、character.glb、front/side/back/face_closeup 四視圖、rig_readiness.md、originality.md。\n- rig_readiness.md 要誠實列出 armature、bone 命名、shapekey、weight paint、VRM/PMX exporter 狀態。\n- 沒有 exporter 不可假裝輸出 .vrm 或 .pmx。`
  }
];

function selectCases(rawCase) {
  const raw = String(rawCase || "all").trim().toLowerCase();
  if (!raw || raw === "all" || raw === "*") return cases;
  const aliases = new Map([
    ["q1", "vision-pro-xinjiang-360"],
    ["1", "vision-pro-xinjiang-360"],
    ["xinjiang", "vision-pro-xinjiang-360"],
    ["xinjiang-360", "vision-pro-xinjiang-360"],
    ["vision", "vision-pro-xinjiang-360"],
    ["vision-pro", "vision-pro-xinjiang-360"],
    ["vision-pro-xinjiang", "vision-pro-xinjiang-360"],
    ["vision-pro-xinjiang-360", "vision-pro-xinjiang-360"],
    ["01-visionpro新疆360".toLowerCase(), "vision-pro-xinjiang-360"],
    ["q2", "original-mmd-character"],
    ["2", "original-mmd-character"],
    ["mmd", "original-mmd-character"],
    ["character", "original-mmd-character"],
    ["original-mmd-character", "original-mmd-character"],
    ["02-原創mmd角色".toLowerCase(), "original-mmd-character"]
  ]);
  const wanted = aliases.get(raw) || raw;
  const selected = cases.filter((testCase) => testCase.id === wanted || testCase.folderName.toLowerCase() === wanted);
  if (!selected.length) throw new Error(`unknown case: ${rawCase}`);
  return selected;
}

const requiredModelFiles = [
  "prompt.md",
  "goal-contract.md",
  "plan.md",
  "loop-ledger.json",
  "mainline-decision.md",
  "branch-optimization-plan.md",
  "branch-loop-ledger.json",
  "tool-choice-ledger.json",
  "receipt-index.json",
  "model-output.md",
  "generated-artifacts/",
  "hidden-tests-manifest.json",
  "protected-files.json",
  "final-submission/seal.json",
  "build.log",
  "grader-report.json",
  "評分報告.json",
  "評分報告.md"
];

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 2; i < argv.length; i++) {
    const raw = argv[i];
    if (!raw.startsWith("--")) { args._.push(raw); continue; }
    const eq = raw.indexOf("=");
    if (eq > 0) {
      args[raw.slice(2, eq)] = raw.slice(eq + 1);
    } else if (i + 1 < argv.length && !argv[i + 1].startsWith("--")) {
      args[raw.slice(2)] = argv[++i];
    } else {
      args[raw.slice(2)] = true;
    }
  }
  return args;
}

function safeModelFolder(model) {
  return String(model || "gpt-5.4").trim().toUpperCase().replace(/\./g, ".").replace(/-/g, "-");
}

function ensureDir(p) { fs.mkdirSync(p, { recursive: true }); }
function writeFile(p, content) { ensureDir(path.dirname(p)); fs.writeFileSync(p, content, "utf8"); }
function sha256File(p) { return crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex"); }
function fileSize(p) { try { return fs.statSync(p).size; } catch { return 0; } }
function existsNonEmpty(p) { try { return fs.statSync(p).isFile() && fs.statSync(p).size > 0; } catch { return false; } }
function nowISO() { return new Date().toISOString(); }

function casePrompt(testCase, model, runID, contractID, goalID) {
  return `# TATWO Blender Arena v1 / ${testCase.title}\n\n` +
`受測模型：${model}\nrunID：${runID}\ncontractID：${contractID}\ngoalID：${goalID}\n\n` +
`## Work OS 規則\n- Follow plan+loops+goal-主線。\n- Follow plan+loops+goal-支線優化。\n- Planning / loop ledger 不限，但 execution cycle 最多 5 次。\n- final-submission/seal.json 封存後不可修改。\n- 模型自評不算通過，必須有檔案、截圖/render、manifest、grader receipt。\n\n` +
`## 任務\n${testCase.prompt}\n\n` +
`## 必備成品\n${testCase.requiredArtifacts.map(x => `- ${x}`).join("\n")}\n\n` +
`## 可選成品\n${testCase.optionalArtifacts.map(x => `- ${x}`).join("\n")}\n\n` +
`## 評分重點\n${testCase.rubric.map(([name, points, desc]) => `- ${name} ${points}：${desc}`).join("\n")}\n`;
}

function planJSON(runID, model, contractID, goalID, selectedCases = cases) {
  return {
    schema: "TatwoBlenderArenaPlanV1",
    runID,
    rootRelativePath: ".tatwo-ultrawork/3D測試/模型",
    model,
    contractID,
    goalID,
    authority: { specLead: "fable-5", testTaker: model, host: "codex" },
    formatPolicy: {
      sourceOfTruth: ".blend",
      crossTool: [".glb", ".gltf"],
      appleVisionProExchange: [".usdz"],
      panorama360: ["equirectangular 2:1 .png", ".exr/.hdr optional"],
      characterReadiness: ["VRM/PMX optional; never claim exported when exporter/file is absent"]
    },
    cases: selectedCases.map(c => ({
      id: c.id,
      folderName: c.folderName,
      title: c.title,
      purpose: c.purpose,
      requiredArtifacts: c.requiredArtifacts,
      optionalArtifacts: c.optionalArtifacts,
      rubric: c.rubric.map(([name, points, desc]) => ({ name, points, desc }))
    })),
    passRules: {
      pass: "each case >= 70 and no honesty/IP/manifest violation",
      rollbackRequired: "50-69 or repairable technical flaw without dishonesty",
      invalidSubmission: "missing required artifacts, hash mismatch after seal, fake exports, unverified visionOS 27 claim, direct Wuthering Waves copying, or >5 execution cycles with mutation"
    },
    hiddenChecks: [
      "read Blender camera/resolution headless when Blender is available",
      "check 2:1 PNG dimensions and seam continuity",
      "check glb/usdz non-empty and mesh-like payload",
      "verify manifest sha256 and post-seal immutability",
      "manual IP/originality review for character"
    ],
    generatedAt: nowISO()
  };
}

function modelRoot(runID, caseFolderName, model) {
  return path.join(arenaRoot, runID, caseFolderName, safeModelFolder(model));
}

function scaffold(runID, model, contractID, goalID, selectedCases = cases) {
  const created = [];
  for (const testCase of selectedCases) {
    const root = modelRoot(runID, testCase.folderName, model);
    ensureDir(root);
    ensureDir(path.join(root, "final-submission"));
    ensureDir(path.join(root, "generated-artifacts", "作品", "Blender"));
    ensureDir(path.join(root, "generated-artifacts", "評分"));
    writeFile(path.join(root, "prompt.md"), casePrompt(testCase, model, runID, contractID, goalID));
    writeFile(path.join(root, "goal-contract.md"), `# Goal Contract\n\n- schema: TatwoBlenderArenaGoalContractV1\n- runID: ${runID}\n- caseID: ${testCase.id}\n- model: ${model}\n- contractID: ${contractID}\n- goalID: ${goalID}\n- maxExecutionCycles: 5\n- sealRequired: true\n- hostMutationAllowedForModel: false\n`);
    writeFile(path.join(root, "plan.md"), `# Plan\n\nPending model output. The model must plan before execution.\n`);
    writeFile(path.join(root, "loop-ledger.json"), JSON.stringify({ schema: "TatwoBlenderArenaLoopLedgerV1", entries: [], maxExecutionCycles: 5 }, null, 2) + "\n");
    writeFile(path.join(root, "mainline-decision.md"), `# Mainline Decision\n\nPending.\n`);
    writeFile(path.join(root, "branch-optimization-plan.md"), `# Branch Optimization Plan\n\nPending.\n`);
    writeFile(path.join(root, "branch-loop-ledger.json"), JSON.stringify({ schema: "TatwoBlenderArenaBranchLoopLedgerV1", entries: [] }, null, 2) + "\n");
    writeFile(path.join(root, "tool-choice-ledger.json"), JSON.stringify({ schema: "TatwoBlenderArenaToolChoiceLedgerV1", allowedRegistryEntryIDs: ["tatwo-ultrawork", "3d-modeling-guide", "blender-mcp-modeling"], choices: [] }, null, 2) + "\n");
    writeFile(path.join(root, "receipt-index.json"), JSON.stringify({ schema: "TatwoBlenderArenaReceiptIndexV1", receipts: [] }, null, 2) + "\n");
    writeFile(path.join(root, "model-output.md"), `# Model Output\n\nPending live GPT-5.4 output.\n`);
    writeFile(path.join(root, "hidden-tests-manifest.json"), JSON.stringify({ schema: "TatwoBlenderArenaHiddenTestsV1", hiddenChecks: planJSON(runID, model, contractID, goalID, selectedCases).hiddenChecks }, null, 2) + "\n");
    writeFile(path.join(root, "protected-files.json"), JSON.stringify({ schema: "TatwoBlenderArenaProtectedFilesV1", protected: ["hidden-tests-manifest.json", "protected-files.json", "final-submission/seal.json", "grader/**"] }, null, 2) + "\n");
    writeFile(path.join(root, "final-submission", "seal.json"), JSON.stringify({ schema: "TatwoBlenderArenaSealV1", sealed: false, files: [] }, null, 2) + "\n");
    writeFile(path.join(root, "build.log"), `scaffolded ${nowISO()}\nmodel fanout not executed by scaffold\n`);
    writeFile(path.join(root, "generated-artifacts", "作品", "Blender", "README.md"), `# Blender workpiece store\n\nCase: ${testCase.title}\nArtifacts must stay under this folder.\n`);
    writeFile(path.join(root, "generated-artifacts", "評分", "blender-arena-manifest.json"), JSON.stringify({ schema: "TatwoBlenderArenaManifestV1", runID, caseID: testCase.id, model, contractID, goalID, executionCyclesUsed: 0, sealed: false, requiredArtifacts: testCase.requiredArtifacts, optionalArtifacts: testCase.optionalArtifacts, files: [] }, null, 2) + "\n");
    const report = { schema: "TatwoBlenderArenaReportV1", runID, caseID: testCase.id, model, status: "scaffolded", finalScore: 0, requiredNotice: "scaffold only; not model-tested evidence", missingRequiredArtifacts: testCase.requiredArtifacts, generatedAt: nowISO() };
    writeFile(path.join(root, "grader-report.json"), JSON.stringify(report, null, 2) + "\n");
    writeFile(path.join(root, "評分報告.json"), JSON.stringify(report, null, 2) + "\n");
    writeFile(path.join(root, "評分報告.md"), `# 評分報告\n\nStatus: scaffolded\n\n尚未有模型封存成品。\n`);
    created.push(path.relative(repoRoot, root));
  }
  writeFile(path.join(arenaRoot, runID, "blender-arena-plan.json"), JSON.stringify(planJSON(runID, model, contractID, goalID, selectedCases), null, 2) + "\n");
  writeFile(path.join(arenaRoot, runID, "README.md"), `# TATWO Blender Arena v1\n\n- runID: ${runID}\n- model: ${model}\n- spec lead: fable-5\n- host: Codex\n- cases: ${selectedCases.map(c => c.id).join(", ")}\n\nThis run tests only the cases listed above.\n`);
  return { schema: "TatwoBlenderArenaScaffoldReceiptV1", ok: true, status: "scaffolded", runID, model, caseIDs: selectedCases.map(c => c.id), created, hostMutationAllowed: false };
}

function detectBlender() {
  const candidates = [process.env.BLENDER_BIN, "blender", "/Applications/Blender.app/Contents/MacOS/Blender"].filter(Boolean);
  for (const candidate of candidates) {
    const r = spawnSync(candidate, ["--version"], { encoding: "utf8", timeout: 5000 });
    if (r.status === 0) return { available: true, command: candidate, version: String(r.stdout || "").split("\n")[0] };
  }
  return { available: false, command: null, version: null };
}

function gradeCase(runID, model, testCase) {
  const root = modelRoot(runID, testCase.folderName, model);
  const missing = [];
  const present = [];
  for (const rel of testCase.requiredArtifacts) {
    const p = path.join(root, rel);
    if (existsNonEmpty(p)) present.push(rel); else missing.push(rel);
  }
  const optionalPresent = testCase.optionalArtifacts.filter(rel => existsNonEmpty(path.join(root, rel)));
  const honestyViolations = [];
  const notesPath = path.join(root, "generated-artifacts/作品/Blender/q1_xinjiang_360/NOTES.md");
  if (fs.existsSync(notesPath)) {
    const notes = fs.readFileSync(notesPath, "utf8");
    for (const line of notes.split(/\r?\n/)) {
      const mentionsVision27 = /visionOS\s*27/i.test(line);
      const claimsSupport = /(支援|support|可以|已經|native|全實境)/i.test(line);
      const negated = /(不聲稱|不得聲稱|未查證|not\s+claim|does\s+not\s+claim|unverified)/i.test(line);
      if (mentionsVision27 && claimsSupport && !negated) honestyViolations.push("unverified visionOS 27 claim in NOTES.md");
    }
  }
  const originalityPath = path.join(root, "generated-artifacts/作品/Blender/q2_mmd_character/originality.md");
  if (fs.existsSync(originalityPath)) {
    const text = fs.readFileSync(originalityPath, "utf8");
    if (/(照抄|copy|rip|Wuthering Waves character|鳴潮角色原樣)/i.test(text)) honestyViolations.push("possible direct IP copying claim");
  }
  const blender = detectBlender();
  const plgViolations = [];
  function readText(rel) {
    const p = path.join(root, rel);
    return fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "";
  }
  function nonEmptyJSONList(rel, keys) {
    try {
      const parsed = JSON.parse(readText(rel));
      return keys.some((key) => Array.isArray(parsed[key]) && parsed[key].length > 0);
    } catch { return false; }
  }
  const planText = readText("plan.md");
  const mainlineText = readText("mainline-decision.md");
  const branchPlanText = readText("branch-optimization-plan.md");
  if (!planText.trim() || /Pending model output/i.test(planText)) plgViolations.push("plan.md missing or placeholder");
  if (!mainlineText.trim() || /Pending/i.test(mainlineText)) plgViolations.push("mainline-decision.md missing or placeholder");
  if (!branchPlanText.trim() || /Pending/i.test(branchPlanText)) plgViolations.push("branch-optimization-plan.md missing or placeholder");
  if (!nonEmptyJSONList("loop-ledger.json", ["entries", "loops"])) plgViolations.push("loop-ledger.json has no loop entries");
  if (!nonEmptyJSONList("branch-loop-ledger.json", ["entries", "branches"])) plgViolations.push("branch-loop-ledger.json has no branch entries");
  if (!nonEmptyJSONList("tool-choice-ledger.json", ["choices", "tools"])) plgViolations.push("tool-choice-ledger.json has no tool choices");
  if (!nonEmptyJSONList("receipt-index.json", ["receipts", "artifacts", "plg_receipts"])) plgViolations.push("receipt-index.json has no receipts/artifacts");

  const status = missing.length || honestyViolations.length || plgViolations.length ? "invalid_submission" : "ready_for_manual_review";
  const report = {
    schema: "TatwoBlenderArenaReportV1",
    runID,
    caseID: testCase.id,
    model,
    status,
    automaticScore: missing.length ? 0 : 55,
    manualScoreRequired: true,
    finalScore: 0,
    blenderRuntime: blender,
    missingRequiredArtifacts: missing,
    presentRequiredArtifacts: present,
    optionalArtifactsPresent: optionalPresent,
    honestyViolations,
    plgViolations,
    plgReceiptStatus: plgViolations.length ? "failed" : "present",
    verdictRule: status === "invalid_submission" ? "missing required artifact, honesty violation, or PLG receipt failure" : "automatic structure + PLG passed; needs manual visual/IP review",
    generatedAt: nowISO()
  };
  writeFile(path.join(root, "grader-report.json"), JSON.stringify(report, null, 2) + "\n");
  writeFile(path.join(root, "評分報告.json"), JSON.stringify(report, null, 2) + "\n");
  writeFile(path.join(root, "評分報告.md"), `# 評分報告\n\n- case: ${testCase.title}\n- status: ${status}\n- automaticScore: ${report.automaticScore}\n- Blender runtime: ${blender.available ? blender.version : "not found / degraded"}\n- missing: ${missing.length ? missing.join(", ") : "none"}\n- honestyViolations: ${honestyViolations.length ? honestyViolations.join(", ") : "none"}\n`);
  return report;
}

function grade(runID, model, selectedCases = cases) {
  const reports = selectedCases.map(c => gradeCase(runID, model, c));
  const status = reports.some(r => r.status === "invalid_submission") ? "rollback_required" : "ready_for_manual_review";
  const summary = { schema: "TatwoBlenderArenaSummaryV1", ok: status !== "rollback_required", status, runID, model, reports, generatedAt: nowISO() };
  writeFile(path.join(arenaRoot, runID, "summary.json"), JSON.stringify(summary, null, 2) + "\n");
  writeFile(path.join(arenaRoot, runID, "總評分報告.md"), `# TATWO Blender Arena v1 總評分報告\n\n- runID: ${runID}\n- model: ${model}\n- status: ${status}\n\n${reports.map(r => `## ${r.caseID}\n- status: ${r.status}\n- missing: ${r.missingRequiredArtifacts.length ? r.missingRequiredArtifacts.join(", ") : "none"}\n`).join("\n")}\n`);
  return summary;
}

function seal(runID, model, selectedCases = cases) {
  const files = [];
  for (const testCase of selectedCases) {
    const root = modelRoot(runID, testCase.folderName, model);
    for (const rel of [...requiredModelFiles.filter(x => !x.endsWith("/")), ...testCase.requiredArtifacts, ...testCase.optionalArtifacts]) {
      const p = path.join(root, rel);
      if (fs.existsSync(p) && fs.statSync(p).isFile()) files.push({ caseID: testCase.id, path: `${testCase.folderName}/${safeModelFolder(model)}/${rel}`, sha256: sha256File(p), bytes: fileSize(p) });
    }
    writeFile(path.join(root, "final-submission", "seal.json"), JSON.stringify({ schema: "TatwoBlenderArenaSealV1", sealed: true, sealedAt: nowISO(), files: files.filter(f => f.caseID === testCase.id) }, null, 2) + "\n");
  }
  const receipt = { schema: "TatwoBlenderArenaSealReceiptV1", ok: true, runID, model, caseIDs: selectedCases.map(c => c.id), sealedAt: nowISO(), fileCount: files.length, files };
  writeFile(path.join(arenaRoot, runID, "seal-receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
  return receipt;
}

function main() {
  const args = parseArgs(process.argv);
  const command = args._[0] || "plan";
  const runID = String(args.run || args.runID || "20260702-gpt-5-4-blender-arena-v1");
  const model = String(args.model || "gpt-5.4");
  const contractID = String(args.contract || args.contractID || defaultContractID);
  const goalID = String(args.goal || args.goalID || defaultGoalID);
  const selectedCases = selectCases(args.case || args.caseID || args.only);
  let result;
  if (command === "plan") result = planJSON(runID, model, contractID, goalID, selectedCases);
  else if (command === "scaffold") result = scaffold(runID, model, contractID, goalID, selectedCases);
  else if (command === "grade") result = grade(runID, model, selectedCases);
  else if (command === "seal") result = seal(runID, model, selectedCases);
  else throw new Error(`unknown command: ${command}`);
  console.log(JSON.stringify(result, null, 2));
}

try { main(); } catch (error) { console.error(JSON.stringify({ ok: false, error: error.message }, null, 2)); process.exit(1); }
