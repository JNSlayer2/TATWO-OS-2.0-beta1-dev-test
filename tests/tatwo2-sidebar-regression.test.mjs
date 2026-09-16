import { testScratch } from './helpers/test-scratch.mjs';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import test from 'node:test';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = name => readFileSync(path.join(repo, name), 'utf8');
const modelPath = 'App/Sources/Tatwo2/Facade/ChatPageModel.swift';
const run = (command, args, options = {}) => {
  const result = spawnSync(command, args, {
    cwd: repo, encoding: 'utf8', timeout: 60_000, maxBuffer: 1024 * 1024, ...options,
  });
  assert.equal(result.status, 0, `${command}: ${result.error || ''}\n${result.stdout}\n${result.stderr}`);
  return result;
};

test('sidebar empty state and local project actions use existing controls', () => {
  const sidebar = read('App/Sources/Tatwo2/Chat/ChatPage+Sidebar.swift');
  assert.match(sidebar, /if model\.sidebarStandaloneThreads\.isEmpty && model\.pinnedThreadRefs\.isEmpty/);
  assert.match(sidebar, /ForEach\(model\.pinnedThreadRefs\)/);
  assert.match(sidebar, /model\.createThread\(inProject: project\.id\)/);
  assert.match(sidebar, /model\.setProjectExpanded\(project\.id,/);
  const section = sidebar.slice(sidebar.indexOf('func projectSection('), sidebar.indexOf('// Presentation-only:'));
  assert.doesNotMatch(section, /\.prefix\(8\)/);
  assert.match(section, /LazyVStack/);
  assert.match(section, /let visibleRows = ChatSidebarThreadTreeRow\.rows\(sortedThreads\)/);
  assert.match(section, /ForEach\(visibleRows\)/);
  assert.match(section, /threadRow\(project: project, thread: row\.thread,/);
  assert.match(sidebar, /ChatSidebarThreadTreeRow\.rows\(model\.sidebarStandaloneThreads\)/);
  const engine = read('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift');
  assert.match(engine, /var d = store\.load\(\)\s*d\.prepareChatHierarchy\(\)/);
  assert.match(engine, /generalProjectID: doc\.generalProjectID/);
});

test('native sidebar projection preserves hierarchy and routes local actions locally', {
  skip: process.platform !== 'darwin',
  timeout: 90_000,
}, () => {
  const pressure = run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']).stdout.trim();
  const vm = run('/usr/bin/vm_stat', []).stdout;
  const pageSize = Number(vm.match(/page size of (\d+) bytes/)?.[1]);
  const freePages = Number(vm.match(/Pages free:\s+(\d+)/)?.[1]);
  const freeMiB = pageSize * freePages / 1024 / 1024;
  // This single Foundation fixture has measured ~163 MiB max RSS / 1.7 s.
  // Keep it serial and time-bounded; warning alone need not block validation.
  // App builds are not admitted here. Unknown/critical pressure still refuses.
  assert.ok(pressure === '1' || pressure === '2',
    `defer small fixture: pressure=${pressure}, freeMiB=${freeMiB.toFixed(0)}`);
  const output = testScratch('tatwo2-sidebar-regression-');
  mkdirSync(output, { recursive: true });
  const scratch = mkdtempSync(path.join(output, 'sidebar-regression.'));
  // Use the existing token-owned lock, not a bare directory that another
  // build entrypoint may incorrectly reclaim as an incomplete lock.
  const lockScript = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquired = run('/bin/bash', [lockScript, 'acquire', '--timeout', '20', '--pid', String(process.pid)]);
  const token = acquired.stdout.match(/^token=([0-9a-f]+)$/m)?.[1];
  assert.ok(token, 'build lock ownership returned');
  try {
    const source = process.env.TATWO_SIDEBAR_BASELINE
      ? run('/usr/bin/git', ['show', `${process.env.TATWO_SIDEBAR_BASELINE}:${modelPath}`]).stdout
      : read(modelPath);
    function slice(start, end) {
      const a = source.indexOf(start), b = source.indexOf(end, a);
      assert.ok(a >= 0 && b > a, `production slice ${start}`);
      return source.slice(a, b);
    }
    // Execute exact production computed properties and action methods.
    // Only engine I/O and unrelated app state are replaced by recording fakes;
    // this is not an installed app / storage / remote transport acceptance test.
    const storeSource = read('App/Sources/Tatwo2/Facade/ChatLiveStore.swift');
    const engineSource = read('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift');
    const engineClass = engineSource.slice(engineSource.indexOf('final class ChatLiveEngine:'));
    const productionNewThread = engineClass.slice(engineClass.indexOf('func newThread(in'),
      engineClass.indexOf('func newProject('));
    const productionDocument = engineClass.slice(engineClass.indexOf('var document:'),
      engineClass.indexOf('func transcript(for'));
    const productionPin = engineClass.slice(engineClass.indexOf('func togglePinned('),
      engineClass.indexOf('func rename('));
    assert.ok(productionNewThread.includes('persist()') && productionDocument.includes('generalProjectID')
      && productionPin.includes('isPinned.toggle()'));
    const plumbing = read('App/Sources/Tatwo2/Facade/Tatwo2PlumbingStubs.swift');
    const documentType = plumbing.slice(plumbing.indexOf('struct TatwoNativeChatStoreDocument:'),
      plumbing.indexOf('typealias ChatEngine ='));
    const sidebarModels = read('App/Sources/Tatwo2/Chat/ChatPageModels.swift');
    const productionTree = sidebarModels.slice(sidebarModels.indexOf('struct ChatSidebarThreadTreeRow:'),
      sidebarModels.indexOf('struct ThreadSubagentPresentationRow:'));
    assert.ok(productionTree.includes('stack.popLast()'));
    const swift = `
import Foundation
enum ChatMessageRole: String { case user, assistant, system; var storageValue: String { rawValue } }
enum TatwoNativeChatEventKind: String { case message }
struct ChatMessage {
    var id: String
    var role: ChatMessageRole
    var text: String
    var status: String?
    var eventKind: TatwoNativeChatEventKind
    var turnID: String?
    var createdAt: Date
}
// Unchanged payload types are outside this test; real record decoding,
// projection, JSON I/O, pin and new-thread methods below are production code.
struct ChatNativeGoal: Codable, Equatable { var value: String }
struct TatwoIssueListEntryV1: Codable, Equatable { var body: String }
enum TatwoPermissionPreset: String, Codable { case fullAccess }
struct TatwoGitHubRepoBinding: Sendable, Equatable, Hashable { var url: String }
enum BotLibraryError: Error { case invalid(String) }
enum ThreadLiveness {
    static func from(status: String?, lastOutputAt: Date?) -> String? { status }
}
struct TatwoNativeChatThread: Sendable, Equatable, Hashable {
    var id = UUID()
    var title = "chat"
    var isPinned = false
    var lastPreview = ""
    var parentThreadID: UUID?
    var liveness: String?
    var lastOutputAt: Date?
    var engineLabel: String?
}
struct TatwoNativeChatProject: Sendable, Equatable, Hashable {
    var id = UUID()
    var name = "project"
    var workdir = ""
    var isExpanded = false
    var threads: [TatwoNativeChatThread] = []
    var githubRepos: [TatwoGitHubRepoBinding] = []
}
${documentType}
typealias Document = TatwoNativeChatStoreDocument
${productionTree}
${storeSource}
final class HierarchyEngine {
    var doc: LiveDocumentRecord
    let store: ChatLiveStore
    var messages: [UUID: [ChatMessage]] = [:]
    init(_ store: ChatLiveStore) {
        self.store = store
        var d = store.load()
        d.prepareChatHierarchy()
        doc = d
    }
    func persist() { store.save(doc) }
    ${productionDocument}
    ${productionNewThread}
    ${productionPin}
}
struct ChatSidebarThreadRef {
    let project: TatwoNativeChatProject?
    let thread: TatwoNativeChatThread
    var id: UUID { thread.id }
}
final class RecordingEngine {
    var dates: [UUID: Date] = [:]
    var expansions: [(UUID, Bool)] = []
    var creations: [UUID?] = []
    let newID = UUID()
    func activityDate(_ id: UUID) -> Date { dates[id] ?? .distantPast }
    func setExpanded(_ id: UUID, _ expanded: Bool) { expansions.append((id, expanded)) }
    func newThread(in id: UUID?) -> UUID { creations.append(id); return newID }
}
final class Model {
    var document = Document()
    var searchText = ""
    var isLive = true
    var localLive: RecordingEngine? = RecordingEngine()
    var activeConversationEngine: RecordingEngine? = RecordingEngine()
    var selectedRemote: (deviceID: String, threadID: UUID)? = ("remote", UUID())
    var selectedThreadID: UUID?
    var selectedThreadProject: TatwoNativeChatProject?
    var localSelections: [UUID] = []
    func selectLocalThread(_ id: UUID) {
        selectedRemote = nil
        selectedThreadID = id
        localSelections.append(id)
    }
    ${slice('var filteredProjects:', 'var bindingSummary:')}
    ${slice('var pinnedThreadRefs:', 'var activeMappings:')}
    ${slice('var sidebarStandaloneThreads:', 'var activeGoalNextActionLabel:')}
    ${slice('func newChat()', 'func selectDiscussion(')}
    ${slice('func select(projectID:', 'func toggleSelectedThreadPinned(')}
}
@main struct SidebarRegression {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { print("FAIL: " + label); exit(1) }
            checks += 1; print("PASS: " + label)
        }
        let model = Model()
        let root = TatwoNativeChatThread(title: "Parent")
        let child = TatwoNativeChatThread(title: "Needle child", isPinned: true, parentThreadID: root.id)
        let other = TatwoNativeChatThread(title: "Other", lastPreview: "preview-only")
        let recent = TatwoNativeChatThread(title: "Recent", isPinned: true)
        let a = TatwoNativeChatProject(name: "Alpha", threads: [root, child, other])
        let b = TatwoNativeChatProject(name: "Beta", threads: [recent])
        model.document.projects = [a, b]
        model.localLive!.dates[child.id] = Date(timeIntervalSince1970: 10)
        model.localLive!.dates[recent.id] = Date(timeIntervalSince1970: 20)
        // Deliberately reverse dates on the selected remote device.
        model.activeConversationEngine!.dates[child.id] = Date(timeIntervalSince1970: 40)
        check(model.filteredProjects.map(\\.id) == [a.id, b.id], "empty query keeps project order")
        check(model.pinnedThreadRefs.map(\\.id) == [recent.id, child.id], "local pins sorted by local activity while remote selected")
        check(model.pinnedThreadRefs.last?.project?.id == a.id, "pin retains original project for selection")
        model.searchText = "  NEEDLE\\n"
        check(model.filteredProjects.map(\\.id) == [a.id], "trimmed case-insensitive child search")
        check(model.filteredProjects[0].threads.map(\\.id) == [root.id, child.id], "child search retains parent")
        check(model.filteredProjects[0].isExpanded, "search opens matching project in projection")
        check(!model.document.projects[0].isExpanded, "search does not persist expansion")
        check(model.pinnedThreadRefs.map(\\.id) == [child.id], "pins honor search")
        model.searchText = "alpha"
        check(model.filteredProjects[0].threads.count == 3, "project match keeps all children")
        check(model.pinnedThreadRefs.map(\\.id) == [child.id], "project-name search includes its pins")
        model.searchText = "preview-only"
        check(model.filteredProjects[0].threads.map(\\.id) == [other.id], "preview text is searchable")
        model.searchText = "missing"
        check(model.filteredProjects.isEmpty && model.pinnedThreadRefs.isEmpty, "no results are empty")
        model.searchText = " "
        check(model.filteredProjects.count == 2 && !model.filteredProjects[0].isExpanded, "clearing query restores original expansion")
        model.document.projects[0].threads[1].isPinned = false
        check(model.pinnedThreadRefs.map(\\.id) == [recent.id], "unpin removes shortcut without deleting thread")
        check(model.document.projects[0].threads.count == 3, "unpin leaves project membership intact")
        model.setProjectExpanded(a.id, isExpanded: true)
        check(model.localLive!.expansions.count == 1 && model.activeConversationEngine!.expansions.isEmpty,
              "local project disclosure never writes remote document")
        model.createThread(inProject: a.id)
        check(model.localLive!.creations == [a.id] && model.activeConversationEngine!.creations.isEmpty,
              "local project create never calls remote engine")
        check(model.selectedRemote == nil && model.localSelections == [model.localLive!.newID],
              "local creation selects local conversation")
        model.createThread(inProject: UUID())
        check(model.localLive!.creations.count == 1, "stale unknown project does not create")
        model.isLive = false
        model.createThread(inProject: a.id)
        check(model.localLive!.creations.count == 1, "fixture mode does not create")
        model.localLive = nil
        check(model.threadActivityDate(root) == .distantPast, "missing local engine does not borrow remote dates")
        var cycleA = TatwoNativeChatThread(title: "Cycle match")
        var cycleB = TatwoNativeChatThread(title: "Cycle other")
        cycleA.parentThreadID = cycleB.id; cycleB.parentThreadID = cycleA.id
        model.document.projects = [TatwoNativeChatProject(threads: [cycleA, cycleB])]
        model.searchText = "Cycle match"
        check(model.filteredProjects[0].threads.count == 2, "malformed parent cycle terminates")
        let generalThread = TatwoNativeChatThread(title: "General")
        let generalPin = TatwoNativeChatThread(title: "Pinned general", isPinned: true)
        let general = TatwoNativeChatProject(name: "一般", threads: [generalThread, generalPin])
        model.document = Document(projects: [a, general], generalProjectID: general.id)
        model.searchText = ""
        check(model.filteredProjects.map(\\.id) == [a.id], "marked general container is not a project row")
        check(model.sidebarStandaloneThreads.map(\\.id) == [generalThread.id], "general pins are not duplicated in ordinary chats")
        check(model.pinnedThreadRefs.contains(where: { $0.id == generalPin.id })
            && model.pinnedThreadRefs.first(where: { $0.id == generalPin.id })?.project == nil,
              "general pin uses existing standalone selection")
        model.document.projects[1].threads[1].isPinned = false
        check(model.sidebarStandaloneThreads.count == 2, "unpin returns general chat to ordinary list")
        model.searchText = "pinned"
        check(model.sidebarStandaloneThreads.map(\\.id) == [generalPin.id], "ordinary chats honor search")
        model.isLive = true; model.localLive = RecordingEngine()
        model.selectedRemote = nil; model.selectedThreadProject = a
        model.newChat()
        check(model.localLive!.creations.count == 1 && model.localLive!.creations[0] == nil,
              "chat header creates general chat even when a project was selected")
        model.selectedRemote = ("remote", UUID())
        model.selectedThreadProject = b
        model.newChat()
        check(model.activeConversationEngine!.creations == [b.id] && model.selectedRemote?.threadID == model.activeConversationEngine!.newID,
              "remote new-chat route retains its selected project and device")

        let rootURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = ChatLiveStore(root: rootURL)
        let legacyProject = LiveProjectRecord(name: "一般", workdir: NSHomeDirectory())
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let message = LiveMessageRecord(ChatMessage(id: "fixture-message", role: .user,
            text: "retained text", status: nil, eventKind: .message, turnID: nil, createdAt: date))
        let existing = LiveThreadRecord(projectID: legacyProject.id, title: "existing project chat",
            createdAt: date, updatedAt: date)
        var orphan = LiveThreadRecord(title: "orphan", isPinned: true, sessionID: "fixture-session",
            messages: [message], createdAt: date, updatedAt: date)
        orphan.cwdOverride = "/synthetic/workdir"
        let dangling = LiveThreadRecord(projectID: UUID(), title: "dangling",
            createdAt: date, updatedAt: date)
        let legacy = LiveDocumentRecord(projects: [legacyProject], threads: [existing, orphan, dangling],
            selectedThreadID: orphan.id)
        store.save(legacy)
        let legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        check(legacyJSON["generalProjectID"] == nil, "legacy document really omits new marker")
        let engine = HierarchyEngine(store)
        check(engine.doc.projects.first == legacyProject && engine.doc.threads[0] == existing,
              "legacy home project named general and its chat are not reclassified")
        let generalID = engine.doc.generalProjectID!
        check(engine.doc.threads[1].projectID == generalID && engine.doc.threads[2].projectID == generalID,
              "nil and missing-project chats become reachable")
        var expectedOrphan = orphan; expectedOrphan.projectID = generalID
        check(engine.doc.threads[1] == expectedOrphan && engine.doc.selectedThreadID == orphan.id,
              "orphan recovery preserves text pin session cwd and selection")
        check(engine.document.generalProjectID == generalID
            && engine.document.projects.first(where: { $0.id == generalID })?.threads.count == 2,
              "actual engine document exposes recovered general chats")
        let newID = engine.newThread(in: nil, title: "new general")
        check(engine.doc.threads.first?.id == newID && engine.doc.threads.first?.projectID == generalID,
              "actual newThread nil uses marked general destination")
        let count = engine.doc.projects.count
        _ = engine.newThread(in: nil)
        check(engine.doc.projects.count == count, "repeated general creation does not add containers")
        engine.togglePinned(newID)
        let reopened = HierarchyEngine(ChatLiveStore(root: rootURL))
        check(reopened.doc.generalProjectID == generalID && reopened.doc.threads.first(where: { $0.id == newID })?.isPinned == true,
              "general membership and pin survive real JSON save and reopen")
        reopened.togglePinned(newID)
        check(ChatLiveStore(root: rootURL).load().threads.first(where: { $0.id == newID })?.isPinned == false,
              "unpin survives real JSON save and reload")
        var fresh = LiveDocumentRecord()
        fresh.prepareChatHierarchy()
        let freshID = fresh.generalProjectID
        fresh.prepareChatHierarchy()
        check(fresh.projects.count == 1 && freshID == fresh.generalProjectID, "fresh hierarchy is idempotent")
        var intact = legacy
        intact.threads = [existing]
        intact.prepareChatHierarchy()
        check(intact.projects == legacy.projects && intact.generalProjectID == nil,
              "valid legacy project-only document is not silently migrated")
        let deepRoot = TatwoNativeChatThread(title: "root")
        let deepChild = TatwoNativeChatThread(title: "child", parentThreadID: deepRoot.id)
        let deepMatch = TatwoNativeChatThread(title: "deepest match", parentThreadID: deepChild.id)
        let deepProject = TatwoNativeChatProject(threads: [deepMatch, deepChild, deepRoot])
        model.document = Document(projects: [deepProject])
        model.searchText = "deepest"
        let searchRows = ChatSidebarThreadTreeRow.rows(model.filteredProjects[0].threads)
        check(searchRows.map(\\.id) == [deepRoot.id, deepChild.id, deepMatch.id],
              "actual sidebar row projection includes a matching grandchild")
        check(searchRows.map(\\.depth) == [0, 1, 2], "deep result retains hierarchy without recursive views")
        model.selectedRemote = ("remote", UUID())
        model.select(projectID: deepProject.id, threadID: searchRows.last!.id)
        check(model.selectedRemote == nil && model.selectedThreadID == deepMatch.id,
              "deep result selects its local conversation while remote was selected")
        check(ChatSidebarThreadTreeRow.rows([deepMatch]).map(\\.id) == [deepMatch.id],
              "child remains a reachable root when parent is absent or archived")
        check(Set(ChatSidebarThreadTreeRow.rows([cycleA, cycleB, cycleA]).map(\\.id)).count == 2
            && ChatSidebarThreadTreeRow.rows([cycleA, cycleB, cycleA]).count == 2,
              "cycles and duplicate records neither loop nor duplicate rows")
        let many = (0..<16).map { TatwoNativeChatThread(title: "row-\\($0)") }
        check(ChatSidebarThreadTreeRow.rows(many).count == 16, "rows beyond eight remain reachable")
        var chain: [TatwoNativeChatThread] = []
        for i in 0..<5000 {
            chain.append(TatwoNativeChatThread(title: "depth-\\(i)", parentThreadID: chain.last?.id))
        }
        let chainRows = ChatSidebarThreadTreeRow.rows(Array(chain.reversed()))
        check(chainRows.count == 5000 && chainRows.last?.depth == 4999, "deep hierarchy uses an iterative bounded-memory traversal")
        print("SIDEBARREGRESSION: \\(checks) PASS")
    }
}
`;
    const input = path.join(scratch, 'Sidebar.swift');
    const binary = path.join(scratch, 'sidebar-regression');
    writeFileSync(input, swift);
    const sdk = run('/usr/bin/xcrun', ['--sdk', 'macosx', '--show-sdk-path']).stdout.trim();
    const arch = run('/usr/bin/uname', ['-m']).stdout.trim();
    const compilation = run('/usr/bin/time', ['-l', '/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
      '-sdk', sdk, '-target', `${arch}-apple-macosx14.0`, '-j', '2', input, '-o', binary]);
    writeFileSync(path.join(scratch, 'compile.log'), compilation.stdout + compilation.stderr);
    writeFileSync(path.join(scratch, 'preflight.json'), JSON.stringify({ pressure, freeMiB }, null, 2));
    const result = run(binary, [path.join(scratch, 'store')]);
    writeFileSync(path.join(scratch, 'result.log'), result.stdout + result.stderr);
    assert.match(result.stdout, /SIDEBARREGRESSION: 47 PASS/);
    console.log(result.stdout.trim());
  } finally {
    run('/bin/bash', [lockScript, 'release', '--token', token, '--pid', String(process.pid)]);
  }
});
