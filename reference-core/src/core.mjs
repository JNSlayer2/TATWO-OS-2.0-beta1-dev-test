import path from 'node:path';

const ENGINES = new Set(['claude', 'codex', 'grok', 'other']);
const MAX_TEXT = 32_000;
const ID = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;

function exactKeys(value, allowed, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new TypeError(`${label}_must_be_object`);
  for (const key of Object.keys(value)) if (!allowed.includes(key)) throw new TypeError(`${label}_unknown_field:${key}`);
}

function text(value, label, max = MAX_TEXT) {
  if (typeof value !== 'string' || value.length === 0 || value.length > max || value.includes('\0')) {
    throw new TypeError(`${label}_invalid`);
  }
  return value;
}

export function validateRoom(room) {
  exactKeys(room, ['id', 'title', 'engine', 'model', 'brief', 'workingRoot', 'acceptance'], 'room');
  const id = text(room.id, 'room_id', 64);
  if (!ID.test(id)) throw new TypeError('room_id_invalid');
  const engine = text(room.engine, 'room_engine', 32);
  if (!ENGINES.has(engine)) throw new TypeError('room_engine_unsupported');
  const acceptance = room.acceptance;
  if (!Array.isArray(acceptance) || acceptance.length === 0 || acceptance.length > 20) throw new TypeError('room_acceptance_invalid');
  return Object.freeze({
    id,
    title: text(room.title, 'room_title', 160),
    engine,
    model: room.model == null ? null : text(room.model, 'room_model', 120),
    brief: text(room.brief, 'room_brief'),
    workingRoot: text(room.workingRoot, 'room_working_root', 4096),
    acceptance: acceptance.map((item, index) => text(item, `room_acceptance_${index}`, 500)),
  });
}

export function resolveInside(allowedRoot, candidate) {
  const rawRoot = text(allowedRoot, 'allowed_root', 4096);
  if (!path.isAbsolute(rawRoot)) throw new Error('allowed_root_must_be_absolute');
  const root = path.resolve(rawRoot);
  const resolved = path.resolve(root, text(candidate, 'candidate_path', 4096));
  const relative = path.relative(root, resolved);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error('path_outside_allowed_root');
  return resolved;
}

export function previewRooms(input) {
  exactKeys(input, ['version', 'dryRun', 'allowedRoot', 'rooms'], 'manifest');
  if (input.version !== 1) throw new TypeError('manifest_version_unsupported');
  if (input.dryRun !== true) throw new Error('public_core_requires_dry_run');
  if (!Array.isArray(input.rooms) || input.rooms.length === 0 || input.rooms.length > 8) throw new TypeError('manifest_rooms_invalid');
  const ids = new Set();
  const rooms = input.rooms.map(validateRoom).map(room => {
    if (ids.has(room.id)) throw new TypeError('room_id_duplicate');
    ids.add(room.id);
    return { ...room, lexicalWorkingRoot: resolveInside(input.allowedRoot, room.workingRoot), action: 'preview_only' };
  });
  return { version: 1, dryRun: true, authority: 'none', rooms };
}

export function mergeReports(reports) {
  if (!Array.isArray(reports) || reports.length > 32) throw new TypeError('reports_invalid');
  const normalized = reports.map((report, index) => {
    exactKeys(report, ['roomID', 'status', 'summary', 'evidence'], `report_${index}`);
    const status = text(report.status, `report_${index}_status`, 32);
    if (!['completed', 'blocked', 'failed'].includes(status)) throw new TypeError(`report_${index}_status_invalid`);
    if (!Array.isArray(report.evidence) || report.evidence.length > 30) throw new TypeError(`report_${index}_evidence_invalid`);
    return {
      roomID: text(report.roomID, `report_${index}_room_id`, 64),
      status,
      summary: text(report.summary, `report_${index}_summary`),
      evidence: report.evidence.map((item, evidenceIndex) => text(item, `report_${index}_evidence_${evidenceIndex}`, 1000)),
    };
  });
  return {
    verified: false,
    warning: 'Merged reports are text aggregation, not code integration or acceptance.',
    reports: normalized,
  };
}
