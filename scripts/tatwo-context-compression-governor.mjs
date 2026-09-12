#!/usr/bin/env node
/**
 * TATWO Context Compression Governor V1 planner.
 * Pure deterministic planner: no network, no filesystem writes except CLI stdout.
 */
import crypto from 'node:crypto';
import assert from 'node:assert/strict';

const SCHEMA = 'TatwoContextCompressionGovernorPlanV1';
const DEFAULTS = {
  idleHoursThreshold: 24,
  softContextPct: 70,
  hardContextPct: 85,
  switchGuardPct: 60,
};

function parseBool(v, fallback = false) {
  if (v === undefined || v === null || v === '') return fallback;
  if (typeof v === 'boolean') return v;
  return /^(1|true|yes|on)$/i.test(String(v));
}

function parseRouteVision(v) {
  if (v === undefined || v === null || v === '') return 'unknown';
  if (/^(1|true|yes|on|vision|image)$/i.test(String(v))) return true;
  if (/^(0|false|no|off|none|text)$/i.test(String(v))) return false;
  return 'unknown';
}

function num(v, fallback = 0) {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function getArgv(argv = process.argv.slice(2)) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--selftest') out.selftest = true;
    else if (a === '--help' || a === '-h') out.help = true;
    else if (a === '--json') out.json = true;
    else if (a.startsWith('--')) {
      const key = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = 'true';
      else { out[key] = next; i++; }
    }
  }
  return out;
}

function triggerSet(input) {
  const triggers = new Set();
  const contextPct = effectiveContextPct(input);
  const targetPct = targetContextPct(input);
  if (input.trigger) triggers.add(input.trigger);
  if (input.idleHours >= DEFAULTS.idleHoursThreshold) triggers.add('thread_idle');
  if (input.modelSwitch) triggers.add('model_switch');
  if (contextPct >= DEFAULTS.hardContextPct || contextPct >= DEFAULTS.softContextPct) triggers.add('context_high');
  if (targetPct !== null && targetPct >= DEFAULTS.switchGuardPct) triggers.add('small_window_target');
  if (input.exactRisk || input.exactRiskCount > 0) triggers.add('exact_risk');
  if (input.secretRisk) triggers.add('secret_risk');
  if (input.routeVision === false || input.routeVision === 'unknown') triggers.add('route_image_support_unknown_or_false');
  if (input.wantImage) triggers.add('image_gist_requested');
  if (input.projectHandoff) triggers.add('project_handoff');
  if (input.detailImportant) triggers.add('detail_important');
  return [...triggers];
}

function effectiveContextPct(input) {
  if (input.contextPct > 0) return input.contextPct;
  if (input.currentTokens > 0 && input.currentWindow > 0) return (input.currentTokens / input.currentWindow) * 100;
  return 0;
}

function targetContextPct(input) {
  if (input.currentTokens > 0 && input.targetWindow > 0) return (input.currentTokens / input.targetWindow) * 100;
  return null;
}

function receiptRequirements(stage, pipeline) {
  const req = new Set();
  if (pipeline.includes('S1_text_compact')) {
    req.add('text-summary-receipt');
    req.add('input-hash');
  }
  if (pipeline.includes('S2_exact_sidecar')) {
    req.add('secret-scan');
    req.add('exact-sidecar');
    req.add('sidecar-sha256');
    req.add('coverage-report');
  }
  if (pipeline.includes('S3_image_gist')) {
    req.add('image-manifest');
    req.add('sidecar-ref');
    req.add('non-authoritative-image-label');
  }
  if (pipeline.includes('S4_handoff_pack')) {
    req.add('model-switch-preflight');
    req.add('handoff-pack');
    req.add('same-thread-smoke');
  }
  if (pipeline.includes('S5_new_thread')) {
    req.add('new-thread-handoff-receipt');
    req.add('rollback-pointer');
  }
  if (stage === 'S6_human_gate') req.add('human-gate-note');
  if (stage !== 'S0_none') req.add('TatwoCompressionReceiptV1');
  return [...req];
}

function addPipeline(pipeline, ...stages) {
  for (const s of stages) if (!pipeline.includes(s)) pipeline.push(s);
  return pipeline;
}

export function planContextCompression(raw = {}) {
  const input = {
    contractId: String(raw.contractId ?? raw.contract_id ?? '').trim(),
    threadRef: String(raw.threadRef ?? raw.thread_ref ?? '').trim(),
    trigger: String(raw.trigger ?? '').trim(),
    contextPct: num(raw.contextPct ?? raw.context_pct, 0),
    currentTokens: num(raw.currentTokens ?? raw.current_tokens, 0),
    currentWindow: num(raw.currentWindow ?? raw.current_window, 0),
    targetWindow: num(raw.targetWindow ?? raw.target_window, 0),
    idleHours: num(raw.idleHours ?? raw.idle_hours, 0),
    modelSwitch: parseBool(raw.modelSwitch ?? raw.model_switch, false),
    exactRisk: parseBool(raw.exactRisk ?? raw.exact_risk, false),
    exactRiskCount: num(raw.exactRiskCount ?? raw.exact_risk_count, 0),
    secretRisk: parseBool(raw.secretRisk ?? raw.secret_risk, false),
    routeVision: parseRouteVision(raw.routeVision ?? raw.route_vision),
    wantImage: parseBool(raw.wantImage ?? raw.want_image, false),
    sidecarPresent: parseBool(raw.sidecarPresent ?? raw.sidecar_present, false),
    sidecarVerified: parseBool(raw.sidecarVerified ?? raw.sidecar_verified, false),
    liveTrading: parseBool(raw.liveTrading ?? raw.live_trading, false),
    productionMutation: parseBool(raw.productionMutation ?? raw.production_mutation, false),
    projectHandoff: parseBool(raw.projectHandoff ?? raw.project_handoff, false),
    detailImportant: parseBool(raw.detailImportant ?? raw.detail_important, false),
  };
  const contextPct = effectiveContextPct(input);
  const targetPct = targetContextPct(input);
  const triggers = triggerSet(input);
  const pipeline = [];
  const actions = [];
  const notes = [];
  let stage = 'S0_none';
  let failClosed = false;
  let failClosedReason = null;
  let humanGate = false;
  let directSwitchAllowed = true;
  let imageAllowed = input.routeVision === true;
  let allowedLossy = false;

  const hasContract = input.contractId.length > 0;
  const exactRisk = input.exactRisk || input.exactRiskCount > 0;
  const detailHandoff = input.projectHandoff || input.detailImportant;

  if (input.secretRisk || input.productionMutation) {
    stage = 'S6_human_gate';
    addPipeline(pipeline, stage);
    humanGate = true;
    failClosed = true;
    failClosedReason = input.secretRisk
      ? 'secret_risk_hit_blocks_lossy_or_external_compression'
      : 'production_mutation_requires_new_human_contract';
  } else if (!hasContract) {
    failClosed = true;
    failClosedReason = 'missing_contract_id_in_memory_only_no_artifact_actions';
    if (input.idleHours >= DEFAULTS.idleHoursThreshold || contextPct >= DEFAULTS.softContextPct || input.modelSwitch) {
      stage = 'S1_text_compact';
      addPipeline(pipeline, stage);
      notes.push('Only in-memory planning is allowed without contractID. No files, no images, no handoff artifacts.');
    } else {
      stage = 'S0_none';
      addPipeline(pipeline, stage);
    }
  } else if (input.liveTrading && input.wantImage) {
    stage = 'S6_human_gate';
    addPipeline(pipeline, 'S2_exact_sidecar', stage);
    humanGate = true;
    failClosed = true;
    failClosedReason = 'live_trading_blocks_lossy_image_gist';
    actions.push('run_secret_scan', 'write_exact_sidecar_only', 'request_human_gate');
  } else if (detailHandoff) {
    // Project handoff with important research/detail should not use lossy summary first.
    // Preserve exact text sidecar, then optionally add a non-authoritative image map.
    if (input.wantImage && input.routeVision === true && input.sidecarPresent && input.sidecarVerified) {
      stage = 'S3_image_gist';
      addPipeline(pipeline, 'S3_image_gist');
      allowedLossy = true;
      actions.push('render_image_map_from_verified_sidecar', 'write_image_manifest', 'label_image_non_authoritative');
      notes.push('Detail-important project handoff skips lossy summary; exact sidecar remains source of truth.');
    } else {
      stage = 'S2_exact_sidecar';
      addPipeline(pipeline, 'S2_exact_sidecar');
      actions.push('run_secret_scan', 'write_exact_sidecar', 'write_artifact_map', 'verify_sidecar_hash');
      notes.push('Detail-important project handoff uses exact sidecar/artifact map instead of lossy summary.');
      if (input.wantImage) {
        failClosed = true;
        failClosedReason = input.routeVision !== true
          ? 'detail_handoff_image_requested_but_route_has_no_verified_vision_support'
          : 'detail_handoff_image_requested_without_verified_exact_sidecar';
      }
    }
  } else if (input.modelSwitch || (targetPct !== null && targetPct >= DEFAULTS.switchGuardPct)) {
    stage = 'S4_handoff_pack';
    directSwitchAllowed = false;
    addPipeline(pipeline, 'S1_text_compact');
    actions.push('write_text_compact_summary');
    if (exactRisk || contextPct >= DEFAULTS.hardContextPct || (targetPct !== null && targetPct >= DEFAULTS.switchGuardPct)) {
      addPipeline(pipeline, 'S2_exact_sidecar');
      actions.push('run_secret_scan', 'write_exact_sidecar', 'verify_sidecar_hash');
    }
    addPipeline(pipeline, 'S4_handoff_pack');
    actions.push('write_handoff_pack', 'block_direct_model_switch', 'require_same_thread_smoke');
  } else if (contextPct >= DEFAULTS.hardContextPct) {
    stage = 'S4_handoff_pack';
    addPipeline(pipeline, 'S1_text_compact', 'S2_exact_sidecar', 'S4_handoff_pack');
    directSwitchAllowed = false;
    actions.push('write_text_compact_summary', 'run_secret_scan', 'write_exact_sidecar', 'write_handoff_pack');
  } else if (input.wantImage) {
    if (input.routeVision !== true) {
      stage = exactRisk ? 'S2_exact_sidecar' : 'S1_text_compact';
      addPipeline(pipeline, stage);
      failClosed = true;
      failClosedReason = 'image_gist_requested_but_route_has_no_verified_vision_support';
      imageAllowed = false;
      actions.push(stage === 'S2_exact_sidecar' ? 'write_exact_sidecar' : 'write_text_compact_summary');
    } else if (!input.sidecarPresent || !input.sidecarVerified) {
      stage = 'S2_exact_sidecar';
      addPipeline(pipeline, stage);
      failClosed = true;
      failClosedReason = 'image_gist_requested_without_verified_exact_sidecar';
      actions.push('run_secret_scan', 'write_exact_sidecar', 'verify_sidecar_hash');
    } else {
      stage = 'S3_image_gist';
      addPipeline(pipeline, 'S3_image_gist');
      allowedLossy = true;
      actions.push('render_image_gist', 'write_image_manifest', 'label_image_non_authoritative');
    }
  } else if (exactRisk) {
    stage = 'S2_exact_sidecar';
    addPipeline(pipeline, stage);
    actions.push('run_secret_scan', 'write_exact_sidecar', 'verify_sidecar_hash');
  } else if (input.idleHours >= DEFAULTS.idleHoursThreshold || contextPct >= DEFAULTS.softContextPct) {
    stage = 'S1_text_compact';
    addPipeline(pipeline, stage);
    actions.push('write_text_compact_summary', 'preserve_recent_tail_text');
    if (input.idleHours >= DEFAULTS.idleHoursThreshold && contextPct < DEFAULTS.hardContextPct) {
      notes.push('Idle resume defaults to text compact only; no image and no sidecar unless another trigger requires it.');
    }
  } else {
    stage = 'S0_none';
    addPipeline(pipeline, stage);
    actions.push('continue_without_compression');
  }

  if (failClosed && failClosedReason?.startsWith('missing_contract_id')) actions.length = 0;

  return {
    schema: SCHEMA,
    decision_id: 'ccg_' + crypto.createHash('sha256').update(JSON.stringify({ input, stage, pipeline, failClosedReason })).digest('hex').slice(0, 12),
    input,
    metrics: {
      context_pct: Math.round(contextPct * 10) / 10,
      target_context_pct: targetPct === null ? null : Math.round(targetPct * 10) / 10,
      thresholds: DEFAULTS,
    },
    triggers,
    recommended_stage: stage,
    pipeline,
    actions,
    direct_model_switch_allowed: directSwitchAllowed,
    image_gist_allowed: imageAllowed && allowedLossy,
    lossy_allowed: allowedLossy,
    human_gate_required: humanGate,
    fail_closed: failClosed,
    fail_closed_reason: failClosedReason,
    receipts_required: receiptRequirements(stage, pipeline),
    authority: {
      plan_lead: 'Fable5 or current Work OS Plan Lead decides stage binding',
      host_executor: 'Codex writes artifacts only in staging unless separately authorized',
      exact_source_of_truth: 'text sidecar / receipt, never image-only',
    },
    notes,
  };
}

function usage() {
  console.log(`Usage:
  node tatwo-context-compression-governor.mjs --selftest
  node tatwo-context-compression-governor.mjs --contract-id C --idle-hours 48 --context-pct 40
  node tatwo-context-compression-governor.mjs --contract-id C --model-switch true --current-tokens 150000 --target-window 200000
  node tatwo-context-compression-governor.mjs --contract-id C --project-handoff true --detail-important true --want-image true

Flags use kebab-case. Output is JSON.`);
}

function selftest() {
  const cases = [
    ['idle 48h + context 40 => S1', { contractId: 'C', idleHours: 48, contextPct: 40 }, (p) => p.recommended_stage === 'S1_text_compact' && !p.pipeline.includes('S2_exact_sidecar')],
    ['idle-only context 80 => still S1 only', { contractId: 'C', idleHours: 48, contextPct: 80 }, (p) => p.recommended_stage === 'S1_text_compact' && !p.pipeline.includes('S2_exact_sidecar') && !p.pipeline.includes('S3_image_gist')],
    ['context 88 + exact => S4 with S2', { contractId: 'C', contextPct: 88, exactRisk: true }, (p) => p.recommended_stage === 'S4_handoff_pack' && p.pipeline.includes('S1_text_compact') && p.pipeline.includes('S2_exact_sidecar')],
    ['model switch small target => S1 then S4 direct denied', { contractId: 'C', modelSwitch: true, currentTokens: 150000, targetWindow: 200000 }, (p) => p.recommended_stage === 'S4_handoff_pack' && p.pipeline[0] === 'S1_text_compact' && p.direct_model_switch_allowed === false],
    ['secret risk => S6 no lossy', { contractId: 'C', secretRisk: true, wantImage: true, routeVision: true }, (p) => p.recommended_stage === 'S6_human_gate' && p.lossy_allowed === false],
    ['S3 request without sidecar => S2 fail closed', { contractId: 'C', wantImage: true, routeVision: true }, (p) => p.recommended_stage === 'S2_exact_sidecar' && p.fail_closed === true],
    ['route no vision => never S3', { contractId: 'C', wantImage: true, routeVision: false, sidecarPresent: true, sidecarVerified: true }, (p) => p.recommended_stage !== 'S3_image_gist' && p.image_gist_allowed === false],
    ['missing contract => in-memory only no actions', { idleHours: 48, contextPct: 80 }, (p) => p.fail_closed === true && p.actions.length === 0],
    ['verified sidecar + vision + want image => S3', { contractId: 'C', wantImage: true, routeVision: true, sidecarPresent: true, sidecarVerified: true }, (p) => p.recommended_stage === 'S3_image_gist' && p.lossy_allowed === true],
    ['detail handoff + image request without sidecar => S2 fail closed no S1', { contractId: 'C', projectHandoff: true, detailImportant: true, wantImage: true, routeVision: true }, (p) => p.recommended_stage === 'S2_exact_sidecar' && !p.pipeline.includes('S1_text_compact') && p.fail_closed === true],
    ['detail handoff + verified sidecar + image => S3 no S1', { contractId: 'C', projectHandoff: true, detailImportant: true, wantImage: true, routeVision: true, sidecarPresent: true, sidecarVerified: true }, (p) => p.recommended_stage === 'S3_image_gist' && !p.pipeline.includes('S1_text_compact') && p.lossy_allowed === true],
  ];
  const results = [];
  for (const [name, input, pred] of cases) {
    const plan = planContextCompression(input);
    const ok = pred(plan);
    results.push({ name, ok, recommended_stage: plan.recommended_stage, pipeline: plan.pipeline, fail_closed: plan.fail_closed });
    assert.equal(ok, true, name + ' failed: ' + JSON.stringify(plan));
  }
  return { schema: 'TatwoContextCompressionGovernorSelftestV1', ok: true, count: results.length, results };
}

const args = getArgv();
if (args.help) usage();
else if (args.selftest) console.log(JSON.stringify(selftest(), null, 2));
else console.log(JSON.stringify(planContextCompression(args), null, 2));
