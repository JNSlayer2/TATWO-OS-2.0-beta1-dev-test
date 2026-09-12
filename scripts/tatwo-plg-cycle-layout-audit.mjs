#!/usr/bin/env node
import {
  extractSwiftTypeBody,
  readRequiredSources,
  requireSourceMarker,
} from './tatwo-static-audit-source-contract.mjs';

const root = process.cwd();
const requiredSourceManifest = [
  {
    id: 'models',
    relativePath: 'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageModels.swift',
  },
  {
    id: 'page',
    relativePath: 'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift',
  },
  {
    id: 'architecture',
    relativePath: 'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPageArchitectureData.swift',
  },
];
const { sources, sourceSnapshot } = readRequiredSources({
  root,
  manifest: requiredSourceManifest,
});
const metricsSource = extractSwiftTypeBody(sources.get('models').text, {
  kind: 'enum',
  name: 'WorkOSPlanLoopsGoalMetrics',
  stripComments: true,
});
const cycleMapSource = extractSwiftTypeBody(sources.get('page').text, {
  kind: 'struct',
  name: 'WorkOSPlanLoopsGoalCycleMap',
  stripComments: true,
});
const blueprintFactorySource = extractSwiftTypeBody(sources.get('architecture').text, {
  kind: 'enum',
  name: 'WorkOSPlanLoopsGoalBlueprintFactory',
  stripComments: true,
});
const findings = [];

function requireSource(scopedSource, needle, id, sourcePath, symbol) {
  try {
    requireSourceMarker(scopedSource, needle, { sourcePath, symbol });
  } catch {
    findings.push({ kind: 'missing_source_guard', id, needle });
  }
}
function metric(name) {
  const matches = [...metricsSource.matchAll(new RegExp(`static let ${name}: CGFloat = ([0-9.]+)`, 'g'))];
  if (matches.length !== 1) findings.push({ kind: 'missing_metric', name });
  return matches.length === 1 ? Number(matches[0][1]) : NaN;
}
function rect(id, x, y, w, h) { return { id, left: x, top: y, right: x + w, bottom: y + h, midX: x + w / 2, midY: y + h / 2, w, h }; }
function offsetRect(r, dy) { return { ...r, top: r.top + dy, bottom: r.bottom + dy, midY: r.midY + dy }; }
function overlaps(a, b, pad = 0) { return !(a.right + pad <= b.left || b.right + pad <= a.left || a.bottom + pad <= b.top || b.bottom + pad <= a.top); }
function p(x, y) { return { x, y }; }
function filterAdjacentDuplicates(points) {
  const out = [];
  for (const pt of points) {
    const last = out[out.length - 1];
    if (!last || Math.hypot(pt.x - last.x, pt.y - last.y) > 0.5) out.push(pt);
  }
  return out;
}
function orthogonalized(points) {
  if (!points.length) return [];
  const result = [points[0]];
  for (const next of points.slice(1)) {
    const current = result[result.length - 1];
    const dx = Math.abs(next.x - current.x);
    const dy = Math.abs(next.y - current.y);
    if (dx < 0.5 || dy < 0.5) result.push(next);
    else if (dx >= dy) result.push(p(next.x, current.y), next);
    else result.push(p(current.x, next.y), next);
  }
  return filterAdjacentDuplicates(result);
}
function assertOrthogonal(id, points) {
  const route = orthogonalized(points);
  for (let i = 1; i < route.length; i += 1) {
    const a = route[i - 1];
    const b = route[i];
    if (Math.abs(a.x - b.x) > 0.5 && Math.abs(a.y - b.y) > 0.5) findings.push({ kind: 'non_orthogonal', id, a, b });
  }
  return route;
}
function segmentIntersectsRect(a, b, r, pad = 2) {
  const rr = { left: r.left - pad, right: r.right + pad, top: r.top - pad, bottom: r.bottom + pad };
  if (Math.abs(a.x - b.x) < 0.5) {
    const x = a.x;
    if (x <= rr.left || x >= rr.right) return false;
    const minY = Math.min(a.y, b.y);
    const maxY = Math.max(a.y, b.y);
    return maxY > rr.top && minY < rr.bottom;
  }
  if (Math.abs(a.y - b.y) < 0.5) {
    const y = a.y;
    if (y <= rr.top || y >= rr.bottom) return false;
    const minX = Math.min(a.x, b.x);
    const maxX = Math.max(a.x, b.x);
    return maxX > rr.left && minX < rr.right;
  }
  return false;
}
function assertRouteAvoids(id, points, rects) {
  const route = assertOrthogonal(id, points);
  for (let i = 1; i < route.length; i += 1) {
    const a = route[i - 1];
    const b = route[i];
    for (const r of rects) {
      if (segmentIntersectsRect(a, b, r)) findings.push({ kind: 'route_hits_card', id, card: r.id, segment: [a, b] });
    }
  }
  return route;
}

const width = metric('width');
const height = metric('height');
const contentOffsetY = metric('contentOffsetY');
const receiptRailY = metric('receiptRailY');

if (width < 1120) findings.push({ kind: 'canvas_too_narrow_for_left_identity_column', width });
if (height < 810) findings.push({ kind: 'canvas_too_short', height });
if (contentOffsetY < 34) findings.push({ kind: 'content_offset_too_small', contentOffsetY });
if (receiptRailY < 780 || receiptRailY > height - 24) findings.push({ kind: 'receipt_rail_bad_y', receiptRailY, height });

requireSource(
  cycleMapSource,
  'WorkOSPlanLoopsGoalIdentityColumn(contract: contract)',
  'identity_column_plain_left',
  requiredSourceManifest[1].relativePath,
  'struct WorkOSPlanLoopsGoalCycleMap',
);
requireSource(
  cycleMapSource,
  '.position(x: 604, y: 27)',
  'legend_moved_to_header_zone',
  requiredSourceManifest[1].relativePath,
  'struct WorkOSPlanLoopsGoalCycleMap',
);
requireSource(
  cycleMapSource,
  '.offset(y: WorkOSPlanLoopsGoalMetrics.contentOffsetY)',
  'content_offset_applied',
  requiredSourceManifest[1].relativePath,
  'struct WorkOSPlanLoopsGoalCycleMap',
);
requireSource(
  blueprintFactorySource,
  'CGPoint(x: 1084, y: r("lead-pass").midY)',
  'lead_pass_uses_right_outer_corridor',
  requiredSourceManifest[2].relativePath,
  'enum WorkOSPlanLoopsGoalBlueprintFactory',
);
requireSource(
  blueprintFactorySource,
  'top(r("receipt-bank"))',
  'receipt_route_enters_receipt_from_top',
  requiredSourceManifest[2].relativePath,
  'enum WorkOSPlanLoopsGoalBlueprintFactory',
);

const O = contentOffsetY;
const cards = Object.fromEntries([
  ['task', rect('task', 238, 178, 120, 72)],
  ['plan', rect('plan', 392, 178, 130, 72)],
  ['loops', rect('loops', 558, 178, 196, 72)],
  ['goal', rect('goal', 808, 178, 132, 72)],
  ['done', rect('done', 970, 178, 124, 72)],
  ['branch-read', rect('branch-read', 300, 356, 176, 62)],
  ['branch-patch', rect('branch-patch', 518, 356, 176, 62)],
  ['branch-test', rect('branch-test', 736, 356, 176, 62)],
  ['supervisor-fail', rect('supervisor-fail', 315, 494, 175, 60)],
  ['supervisor-pass', rect('supervisor-pass', 595, 494, 175, 60)],
  ['lead-fail', rect('lead-fail', 315, 618, 175, 60)],
  ['lead-pass', rect('lead-pass', 595, 618, 175, 60)],
  ['receipt-bank', rect('receipt-bank', 876, 504, 180, 78)],
].map(([id, r]) => [id, offsetRect(r, O)]));

const legend = rect('legend', 254, 9, 700, 36);
const identityColumn = offsetRect(rect('identity-column', 25, 49, 174, 340), O);
for (const card of Object.values(cards)) {
  if (overlaps(identityColumn, card, 10)) findings.push({ kind: 'identity_column_overlaps_workflow_card', card: card.id });
}

const branchLaneLabel = offsetRect(rect('branch-lane-label', 271, 294, 420, 25), O);
for (const id of ['branch-read', 'branch-patch', 'branch-test']) {
  if (overlaps(branchLaneLabel, cards[id], 8)) findings.push({ kind: 'branch_label_overlaps_branch_card', card: id });
}

// Mainline routes should stay horizontal and outside unrelated cards.
assertRouteAvoids('main-task-plan', [p(cards.task.right, cards.task.midY), p(cards.plan.left, cards.plan.midY)], []);
assertRouteAvoids('main-plan-loops', [p(cards.plan.right, cards.plan.midY), p(cards.loops.left, cards.loops.midY)], []);
assertRouteAvoids('main-loops-goal', [p(cards.loops.right, cards.loops.midY), p(cards.goal.left, cards.goal.midY)], []);
assertRouteAvoids('main-goal-done', [p(cards.goal.right, cards.goal.midY), p(cards.done.left, cards.done.midY)], []);

// Receipt route is the one most likely to be drawn through DONE; keep it on the outside corridor.
assertRouteAvoids(
  'goal-to-receipts',
  [p(cards.goal.midX, cards.goal.bottom), p(cards.goal.midX, 292 + O), p(cards['receipt-bank'].midX, 292 + O), p(cards['receipt-bank'].midX, cards['receipt-bank'].top)],
  [cards.done, cards['branch-test'], cards['supervisor-pass'], cards['lead-pass']]
);
assertRouteAvoids(
  'lead-pass-to-goal',
  [p(cards['lead-pass'].right, cards['lead-pass'].midY), p(1084, cards['lead-pass'].midY), p(1084, 290 + O), p(cards.goal.midX, 290 + O), p(cards.goal.midX, cards.goal.bottom)],
  [cards['branch-test'], cards['receipt-bank'], cards.done]
);

const result = {
  schema: 'TatwoPLGCycleLayoutAuditV1',
  ok: findings.length === 0,
  checkedAt: new Date().toISOString(),
  sourceSnapshot,
  metrics: { width, height, contentOffsetY, receiptRailY },
  summary: { findings: findings.length, checkedRoutes: 6 },
  findings,
};
console.log(JSON.stringify(result, null, 2));
if (!result.ok) process.exit(1);
