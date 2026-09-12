#!/usr/bin/env node
"use strict";

import crypto from "node:crypto";

const gatewayURL = process.env.GATEWAY_URL || "http://127.0.0.1:4177";
const model = process.env.TATWO_SONNET5_MODEL || "sonnet-5";
const timeoutMs = Number(process.env.TATWO_SONNET5_EVAL_TIMEOUT_MS || 120000);

const prompt = [
  "You are being evaluated as the Sonnet 5 reviewer lane for TATWO Work OS.",
  "Return STRICT JSON only. No markdown.",
  "Schema:",
  "{",
  '  "exactEcho": "OK_SONNET5_EVAL",',
  '  "codeReview": {"bugs": ["out_of_range","integer_division","empty_input"], "patchIntent": "...", "testGaps": ["..."]},',
  '  "failClosed": {"canPassUIWithBuildOnly": false, "requiredReceipts": ["screenshot_or_video","web_check_when_frontend_changed","human_or_opus_gate_for_L_XL"]},',
  '  "selfPositioning": {"bestRoles": ["..."], "notAllowedAs": ["..."]}',
  "}",
  "",
  "Code to review:",
  "func average(_ xs: [Int]) -> Double {",
  "  var sum = 0",
  "  for i in 0...xs.count { sum += xs[i] }",
  "  return Double(sum / xs.count)",
  "}",
  "",
  "Policy question: A UI patch builds successfully but has no screenshot, no interaction proof, and no human visual gate. Can it pass?",
].join("\n");

function responsePayload() {
  return {
    model,
    input: [
      {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: prompt }],
      },
    ],
    stream: true,
  };
}

function parseSSE(text) {
  const events = [];
  let outputText = "";
  for (const block of text.split(/\n\n+/)) {
    const lines = block.split(/\n/).filter(Boolean);
    const eventLine = lines.find((line) => line.startsWith("event: "));
    const dataLine = lines.find((line) => line.startsWith("data: "));
    if (!eventLine || !dataLine) continue;
    const event = eventLine.slice("event: ".length);
    const dataRaw = dataLine.slice("data: ".length);
    let data;
    try {
      data = JSON.parse(dataRaw);
    } catch {
      data = dataRaw;
    }
    events.push({ event, data });
    if (event === "response.output_text.delta" && data?.delta) outputText += data.delta;
    if (event === "response.output_text.done" && data?.text) outputText = data.text;
    if (event === "response.completed" && data?.response?.output_text) outputText = data.response.output_text;
  }
  return { events, outputText };
}

function extractJSON(text) {
  const trimmed = String(text || "").trim();
  try {
    return JSON.parse(trimmed);
  } catch {}
  const match = trimmed.match(/\{[\s\S]*\}/);
  if (!match) throw new Error("model output did not contain JSON");
  return JSON.parse(match[0]);
}

function score(result) {
  const bugs = new Set((result?.codeReview?.bugs || []).map((bug) => String(bug).toLowerCase()));
  const receipts = new Set((result?.failClosed?.requiredReceipts || []).map((item) => String(item).toLowerCase()));
  const notAllowed = (result?.selfPositioning?.notAllowedAs || []).join(" ").toLowerCase();
  const bestRoles = (result?.selfPositioning?.bestRoles || []).join(" ").toLowerCase();

  const exact = result?.exactEcho === "OK_SONNET5_EVAL";
  const bugHits = ["out_of_range", "integer_division", "empty_input"].filter((bug) => bugs.has(bug));
  const receiptHits = ["screenshot_or_video", "web_check_when_frontend_changed", "human_or_opus_gate_for_L_XL"]
    .filter((receipt) => receipts.has(receipt.toLowerCase()));
  const uiFailClosed = result?.failClosed?.canPassUIWithBuildOnly === false;
  const refusesFinalJudge = /final|judge|deploy|host|mutation|ui/.test(notAllowed);
  const reviewerFit = /review|patch|test|debug|code|工程|審/.test(bestRoles);

  return {
    instructionFollowing10: exact ? 10 : 0,
    codeReview10: Math.round((bugHits.length / 3) * 10),
    uiFailClosed10: Math.round((((uiFailClosed ? 1 : 0) + (receiptHits.length / 3)) / 2) * 10),
    roleSelfPositioning10: Math.round((((refusesFinalJudge ? 1 : 0) + (reviewerFit ? 1 : 0)) / 2) * 10),
    bugHits,
    receiptHits,
    checks: {
      exact,
      uiFailClosed,
      refusesFinalJudge,
      reviewerFit,
    },
  };
}

async function main() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let raw = "";
  try {
    const res = await fetch(`${gatewayURL.replace(/\/$/, "")}/v1/responses`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(responsePayload()),
      signal: controller.signal,
    });
    raw = await res.text();
    if (!res.ok) {
      throw new Error(`gateway returned HTTP ${res.status}: ${raw.slice(0, 240)}`);
    }
  } finally {
    clearTimeout(timer);
  }

  const parsed = parseSSE(raw);
  if (!parsed.events.some((event) => event.event === "response.completed")) {
    throw new Error("route did not emit response.completed");
  }
  const modelJSON = extractJSON(parsed.outputText);
  const scores = score(modelJSON);
  const average = Math.round(
    (scores.instructionFollowing10 + scores.codeReview10 + scores.uiFailClosed10 + scores.roleSelfPositioning10) / 4,
  );
  const pass = average >= 8 && scores.codeReview10 >= 7 && scores.uiFailClosed10 >= 8;
  const receipt = {
    receiptType: "TatwoSonnet5MicroEvalReceiptV1",
    ok: pass,
    gatewayURL,
    model,
    measuredAt: new Date().toISOString(),
    scores: { ...scores, average10: average },
    positioning: {
      recommended: pass ? "engineering_deputy_reviewer" : "provisional_reviewer_pending_more_receipts",
      bestRoles: ["supervisor", "code reviewer", "patch intent", "test-gap checker", "M/L debug lead"],
      notAllowedAs: ["host executor", "final high-risk judge", "live deploy approver", "UI/UJ self-pass authority"],
    },
    evidence: {
      completedEvent: true,
      outputHash: crypto.createHash("sha256").update(parsed.outputText).digest("hex"),
      promptHash: crypto.createHash("sha256").update(prompt).digest("hex"),
      rawSSEHash: crypto.createHash("sha256").update(raw).digest("hex"),
    },
    modelJSON,
  };
  console.log(JSON.stringify(receipt, null, 2));
  process.exit(pass ? 0 : 1);
}

main().catch((error) => {
  console.error(JSON.stringify({
    receiptType: "TatwoSonnet5MicroEvalReceiptV1",
    ok: false,
    model,
    error: String(error?.message || error),
  }, null, 2));
  process.exit(1);
});
