import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
// Decisions and Codable implementations below are extracted verbatim. Only the
// surrounding engine/model/remote/git I/O is stubbed; this is not App acceptance.
function declaration(source, anchor) {
  const start = source.indexOf(anchor);
  assert.notEqual(start, -1, `missing production anchor: ${anchor}`);
  const opening = source.indexOf('{', start);
  let depth = 1;
  let end = opening + 1;
  for (; end < source.length && depth; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0, `unbalanced production declaration: ${anchor}`);
  return source.slice(start, end);
}

function fixtureSource() {
  const read = name => fs.readFileSync(path.join(root, 'App/Sources/Tatwo2/Facade', name), 'utf8');
  const dispatch = read('DispatchEngine.swift');
  // Ignore protocol declarations: their next brace belongs to a different
  // declaration and would turn a "native test" into an invalid fixture.
  const engineFile = read('ChatLiveEngine.swift');
  const implementationStart = engineFile.indexOf('final class ChatLiveEngine:');
  assert.ok(implementationStart >= 0);
  const engine = engineFile.slice(implementationStart);
  const get = (s, a) => declaration(s, a);
  return String.raw`
import Foundation
// Unrelated UI payloads and recording-only engine transport dependencies.
struct ChatNativeGoal: Codable, Equatable {}
struct TatwoIssueListEntryV1: Codable, Equatable {}
enum TatwoPermissionPreset: String, Codable { case standard }
enum ChatMessageRole: String { case user, assistant, system; var storageValue: String { rawValue } }
enum TatwoNativeChatEventKind: String { case message }
struct ChatMessage {
    var id: String = UUID().uuidString
    var role: ChatMessageRole
    var text: String
    var status: String? = nil
    var modelID: String? = nil
    var eventKind: TatwoNativeChatEventKind = .message
    var runtimeAdapterID: String? = nil
    var runtimeFallbackReason: String? = nil
    var turnID: String? = nil
    var planQuestions: [String]? = nil
    var createdAt: Date = Date()
}
${read('ChatLiveStore.swift')}
${get(dispatch, 'struct RoomSpec {')}
${get(dispatch, 'struct DispatchedRoom {')}
${get(dispatch, 'struct ReclaimedRoom {')}
struct DispatchGitFailure: Error { var message: String }
enum RoomReclaimError: Error {
    case roomNotFound, roomRunning, pathOutsideRoomRoot, gitFailed(String), archiveFailed(String)
}
enum ClaudeSidecar { enum Kind: String { case claude, codex, grok } }
enum Calls {
    static var prepare: [String] = []
    static var remote = 0
    static var git = 0
    static var branch = 0
    static func reset() { prepare = []; remote = 0; git = 0; branch = 0 }
}
enum OSAgentBridge {
    static func worktreeBranch(_ path: String) -> String { Calls.branch += 1; return "construction-branch" }
}
struct RemoteDeviceRef { let id: String; let workdirMap: [String: String] }
struct RemoteEngineHandle { let isCaptureOnly: Bool }
struct RemoteDeviceLookup {
    init(root: URL) {}
    func device(id: String) throws -> RemoteDeviceRef {
        Calls.remote += 1
        throw DispatchGitFailure(message: "remote I/O forbidden in fixture")
    }
}
enum RemoteEngineSync {
    static func ensureEnginesOnDevice(_ ref: RemoteDeviceRef, kind: ClaudeSidecar.Kind) throws -> RemoteEngineHandle {
        Calls.remote += 1
        throw DispatchGitFailure(message: "remote start forbidden in fixture")
    }
}
struct RemoteHandles { func set(_ id: UUID, _ handle: RemoteEngineHandle) { Calls.remote += 1 } }
class RecordingEngine {
    var doc: LiveDocumentRecord
    let store: ChatLiveStore
    var messages: [UUID: [ChatMessage]] = [:]
    var newThreads = 0
    var sends: [(UUID, String, String?, ClaudeSidecar.Kind)] = []
    var sendSucceeds = true
    var running = false
    init(root: URL, doc: LiveDocumentRecord) { store = ChatLiveStore(root: root); self.doc = doc }
    func persist() { store.save(doc) }
    func threadRecord(_ id: UUID) -> LiveThreadRecord? { doc.threads.first { $0.id == id } }
    func projectRecord(_ id: UUID?) -> LiveProjectRecord? { doc.projects.first { $0.id == id } }
    func newThread(in projectID: UUID, title: String) -> UUID {
        newThreads += 1
        let row = LiveThreadRecord(projectID: projectID, title: title)
        doc.threads.append(row)
        return row.id
    }
    @discardableResult
    func send(threadID: UUID, text: String, model: String?, engine: ClaudeSidecar.Kind) -> Bool {
        sends.append((threadID, text, model, engine)); return sendSucceeds
    }
    func appendSystemMessage(threadID: UUID, text: String, status: String) {}
    func isRunning(_ id: UUID) -> Bool { running }
    ${get(engine, 'func configureRoom(threadID:')}
}
final class ChatLiveEngine: RecordingEngine {
    var remoteHandles = RemoteHandles()
    ${get(engine, 'func configureReadOnlyRoom(threadID:')}
    ${get(engine, 'func setRequestedModel(')}
    ${get(engine, 'func duplicate(')}
    ${get(engine, 'func createDiscussion(')}
}
final class ChatPageModel {
    var isLive = true
    var live: RecordingEngine?
    init(_ live: RecordingEngine) { self.live = live }
    ${get(dispatch, 'enum DispatchError:')}
    ${get(dispatch, 'func dispatchChecked(rooms:')}
    ${get(dispatch, 'func reclaimRoom(')}
    static func prepareRoomWorktree(workdir: String, roomID: String) throws -> String {
        Calls.prepare.append(workdir)
        return workdir + "/.tatwo2/wt/" + roomID
    }
    static func captureRemoteRoomWorktree(handle: RemoteEngineHandle, roomID: String) throws -> String {
        Calls.remote += 1; throw DispatchGitFailure(message: "remote forbidden")
    }
    static func prepareRemoteRoomWorktree(ref: RemoteDeviceRef, workdir: String, roomID: String) throws -> String {
        Calls.remote += 1; throw DispatchGitFailure(message: "remote forbidden")
    }
    static func runGit(_ args: [String], cwd: String) -> (status: Int32, output: String) {
        Calls.git += 1; return (1, "git forbidden in fixture")
    }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
let source = root.appendingPathComponent("source", isDirectory: true)
let parentCwdURL = root.appendingPathComponent("parent-cwd", isDirectory: true)
try fm.createDirectory(at: source, withIntermediateDirectories: true)
try fm.createDirectory(at: parentCwdURL, withIntermediateDirectories: true)
let sourceMarker = source.appendingPathComponent("keep.txt")
let overrideMarker = parentCwdURL.appendingPathComponent("keep.txt")
try Data("source unchanged".utf8).write(to: sourceMarker)
try Data("parent unchanged".utf8).write(to: overrideMarker)
func unchanged() throws {
    let sourceBytes = try Data(contentsOf: sourceMarker)
    let overrideBytes = try Data(contentsOf: overrideMarker)
    let sourceEntries = try fm.contentsOfDirectory(atPath: source.path).sorted()
    let overrideEntries = try fm.contentsOfDirectory(atPath: parentCwdURL.path).sorted()
    check(sourceBytes == Data("source unchanged".utf8), "source bytes mutated")
    check(overrideBytes == Data("parent unchanged".utf8), "parent bytes mutated")
    check(sourceEntries == ["keep.txt"], "source directory mutated / .tatwo2 created")
    check(overrideEntries == ["keep.txt"], "parent directory mutated / .tatwo2 created")
}
func setup(cwd: String? = nil, remoteParent: Bool = false) -> (ChatLiveEngine, ChatPageModel, UUID) {
    Calls.reset()
    let project = LiveProjectRecord(name: "synthetic", workdir: source.path)
    var parent = LiveThreadRecord(projectID: project.id, title: "parent")
    parent.cwdOverride = cwd
    parent.deviceID = remoteParent ? "unreachable-fixture-device" : nil
    var doc = LiveDocumentRecord(); doc.projects = [project]; doc.threads = [parent]
    let engine = ChatLiveEngine(root: root.appendingPathComponent(UUID().uuidString), doc: doc)
    return (engine, ChatPageModel(engine), parent.id)
}
func spec(_ engine: String = "claude", readonly: Bool = true, device: String? = nil) -> RoomSpec {
    RoomSpec(title: "room", engine: engine, model: "fixture-model", brief: "read fixture", device: device, readOnly: readonly)
}
func rejected(_ model: ChatPageModel, _ engine: RecordingEngine, _ parent: UUID, _ batch: [RoomSpec]) throws {
    let count = engine.doc.threads.count
    do { _ = try model.dispatchChecked(rooms: batch, parent: parent); fatalError("invalid readonly accepted") }
    catch ChatPageModel.DispatchError.readOnlyUnavailable {}
    check(engine.newThreads == 0 && engine.sends.isEmpty && engine.doc.threads.count == count, "invalid batch partially dispatched")
    check(Calls.prepare.isEmpty && Calls.remote == 0 && Calls.git == 0, "invalid batch caused I/O")
}
// Exact default constructors retain old construction behavior.
let defaultSpec = RoomSpec(title: "normal", engine: "codex", model: nil, brief: "build")
check(!defaultSpec.readOnly, "RoomSpec default changed")
let defaultResult = DispatchedRoom(roomID: "a", threadID: "b", worktree: "fixture")
check(!defaultResult.readOnly && defaultResult.workingDirectory == nil, "DispatchedRoom default changed")
check(defaultResult.branch == "construction-branch", "normal branch lookup lost")
// Actual decoder: absent/false/true accepted, malformed capability rejected.
let decoder = JSONDecoder()
let legacy = try decoder.decode(LiveThreadRecord.self, from: Data("{}".utf8))
check(legacy.roomReadOnly == nil, "legacy decode")
for flag in [false, true] {
    var record = LiveThreadRecord(); record.roomReadOnly = flag
    let encoder = JSONEncoder()
    let encoded = try encoder.encode(record)
    let decoded = try decoder.decode(LiveThreadRecord.self, from: encoded)
    check(decoded.roomReadOnly == flag, "capability Codable roundtrip")
}
do { _ = try decoder.decode(LiveThreadRecord.self, from: Data(#"{"roomReadOnly":"true"}"#.utf8)); fatalError("malformed capability accepted") }
catch DecodingError.typeMismatch(_, _) {}
// Both cwd selection branches; real configure, persistence, duplication and reclaim.
for cwd in [nil, parentCwdURL.path] as [String?] {
    let (engine, model, parent) = setup(cwd: cwd)
    let expected = cwd ?? source.path
    let result = try model.dispatchChecked(rooms: [spec()], parent: parent)
    check(result.count == 1, "readonly dispatch missing")
    let room = result[0]; let id = UUID(uuidString: room.threadID)!
    check(room.readOnly && room.worktree.isEmpty && room.workingDirectory == expected, "readonly result/path")
    check(room.branch.isEmpty && Calls.branch == 0, "readonly queried branch")
    check(Calls.prepare.isEmpty && Calls.remote == 0 && Calls.git == 0, "readonly invoked construction I/O")
    check(engine.newThreads == 1 && engine.sends.count == 1 && engine.sends[0].3 == .claude, "readonly send route")
    let configured = engine.threadRecord(id)!
    check(configured.roomReadOnly == true && configured.cwdOverride == expected && configured.parentThreadID == parent, "configure readonly")
    check(configured.engine == "claude" && configured.deviceID == nil && configured.requestedModel == "fixture-model", "readonly configuration")
    let reopened = ChatLiveStore(root: engine.store.url.deletingLastPathComponent()).load()
    let saved = reopened.threads.first { $0.id == id }!
    check(saved.roomReadOnly == true && saved.cwdOverride == expected, "reopen lost capability/cwd")
    // Reclaim uses actual production body with both keepBranch options, including
    // a reopened engine. Any regression to source path handling fails this test.
    let reopenedEngine = ChatLiveEngine(root: engine.store.url.deletingLastPathComponent(), doc: reopened)
    for keep in [false, true] {
        let reclaimed = try ChatPageModel(reopenedEngine).reclaimRoom(id, keepBranch: keep)
        check(reclaimed.originalPath.isEmpty && reclaimed.archivedPath == nil && reclaimed.stash == nil && reclaimed.branch == nil && !reclaimed.branchDeleted, "readonly reclaim not a no-op")
    }
    for branch in [false, true] {
        let duplicate = engine.duplicate(id, asBranch: branch)!
        let copied = engine.threadRecord(duplicate)!
        check(copied.roomReadOnly == true && copied.cwdOverride == expected, "duplicate widened capability")
        check(copied.parentThreadID == (branch ? id : parent), "duplicate ancestry")
    }
    let discussion = engine.createDiscussion(parentThreadID: id)!
    check(engine.threadRecord(discussion)!.roomReadOnly == true && engine.threadRecord(discussion)!.cwdOverride == expected, "discussion widened capability")
    check(Calls.prepare.isEmpty && Calls.remote == 0 && Calls.git == 0, "readonly clone/reclaim I/O")
    try unchanged()
}
// Unsupported engines/devices and mixed batches reject BEFORE construction-first work.
for bad in [spec("codex"), spec("grok"), spec("unknown"), spec(device: "remote")] {
    let (engine, model, parent) = setup()
    try rejected(model, engine, parent, [spec("codex", readonly: false), bad])
}
do {
    let (engine, model, parent) = setup(remoteParent: true)
    try rejected(model, engine, parent, [spec()])
}
do {
    let (local, _, parent) = setup()
    let nonlocal = RecordingEngine(root: root.appendingPathComponent(UUID().uuidString), doc: local.doc)
    try rejected(ChatPageModel(nonlocal), nonlocal, parent, [spec()])
}
// An unsuccessful readonly send must throw without retrying as construction.
do {
    let (engine, model, parent) = setup(); engine.sendSucceeds = false
    do { _ = try model.dispatchChecked(rooms: [spec()], parent: parent); fatalError("send failure hidden") }
    catch is DispatchGitFailure {}
    check(engine.newThreads == 1 && engine.sends.count == 1 && Calls.prepare.isEmpty && Calls.remote == 0, "failed readonly silently fell back")
    check(engine.doc.threads.last!.roomReadOnly == true, "failed readonly widened")
}
// Supported mixed batch remains valid; construction uses project cwd, not parent override.
do {
    let (engine, model, parent) = setup(cwd: parentCwdURL.path)
    let rooms = try model.dispatchChecked(rooms: [defaultSpec, spec()], parent: parent)
    check(rooms.count == 2 && !rooms[0].readOnly && rooms[1].readOnly, "valid mixed batch rejected")
    check(Calls.prepare == [source.path] && Calls.remote == 0 && engine.sends.count == 2, "construction path changed")
    let normalID = UUID(uuidString: rooms[0].threadID)!
    let normal = engine.threadRecord(normalID)!
    check(normal.roomReadOnly != true && normal.cwdOverride == rooms[0].worktree && rooms[0].worktree.hasPrefix(source.path + "/.tatwo2/wt/"), "construction configured incorrectly")
    let copy = engine.duplicate(normalID, asBranch: false)!
    let child = engine.createDiscussion(parentThreadID: normalID)!
    check(engine.threadRecord(copy)!.roomReadOnly != true && engine.threadRecord(child)!.roomReadOnly != true, "normal clone became readonly")
}
try unchanged()
print("PASS production readonly dispatch/configure/Codable/reopen/clone/reclaim; transport is recording-only")
`;
}

test('native production readonly room decisions fail closed without construction or remote I/O', {
  skip: process.platform !== 'darwin', timeout: 180_000,
}, () => {
  const artifacts = path.join(root, 'output/lightweight-repair');
  fs.mkdirSync(artifacts, { recursive: true });
  const dir = fs.mkdtempSync(path.join(artifacts, 'readonly-dispatch-'));
  const source = path.join(dir, 'main.swift');
  fs.writeFileSync(source, fixtureSource());
  const lock = path.join(root, 'scripts/tatwo-build-lock.sh');
  const run = (cmd, args, options = {}) => spawnSync(cmd, args, {
    cwd: root, encoding: 'utf8', timeout: 120_000, maxBuffer: 8 * 1024 * 1024,
    env: { ...process.env, TMPDIR: `${dir}/` }, ...options,
  });
  const acquired = run('bash', [lock, 'acquire', '--timeout', '0', '--pid', String(process.pid)]);
  assert.equal(acquired.status, 0, `build lock unavailable: ${acquired.stderr}`);
  const token = acquired.stdout.match(/^token=([a-f0-9]+)$/m)?.[1];
  assert.ok(token, 'missing ownership token');
  try {
    const build = run('/usr/bin/nice', ['-n', '10', '/usr/bin/swiftc', '-num-threads', '2', source, '-o', path.join(dir, 'fixture')]);
    fs.writeFileSync(path.join(dir, 'compile.log'), `${build.stdout ?? ''}${build.stderr ?? ''}`);
    assert.equal(build.status, 0, `Swift fixture compile failed: ${build.error ?? ''}\n${build.stderr}`);
    const result = run(path.join(dir, 'fixture'), [path.join(dir, 'data')]);
    fs.writeFileSync(path.join(dir, 'result.log'), `${result.stdout ?? ''}${result.stderr ?? ''}`);
    assert.equal(result.status, 0, `native fixture failed: ${result.error ?? ''}\n${result.stderr}`);
    assert.match(result.stdout, /PASS production readonly dispatch/);
  } finally {
    const released = run('bash', [lock, 'release', '--token', token, '--pid', String(process.pid)]);
    assert.equal(released.status, 0, `owned lock release failed: ${released.stderr}`);
  }
});
