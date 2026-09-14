import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import readline from 'node:readline';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const app = 'App/Sources/Tatwo2/';
const section = (source, from, to) => {
  const start = source.indexOf(from), end = source.indexOf(to, start);
  assert.ok(start >= 0 && end > start, `missing production section ${from}`);
  return source.slice(start, end);
};

test('runtime replaces stub, shared MCP wiring and caller-owned policy remain fenced', () => {
  assert.doesNotMatch(read(app + 'Facade/BrowserEngineStubs.swift'), /TatwoWebMCPRuntime/);
  const bridge = read(app + 'Facade/BrowserAgentBridge.swift');
  for (const name of ['browser_tabs', 'page_tools_list', 'page_tool_call']) assert.ok(bridge.includes(`case "${name}":`));
  assert.match(bridge, /TatwoWebMCPRuntime.shared.invoke/);
  assert.match(bridge, /self\.pageToolCaller\(request\)\)\s*== caller/);
  assert.match(bridge, /current\.0\.owner == tab\.owner/);
  assert.match(bridge, /request\.finish\(\)\s*task\.cancel\(\)/);
  assert.match(bridge, /try Self.validatePageToolParameters/);
  assert.match(bridge, /grant = try ComputerUseController\.shared\.requireBrowserGrant/);
  assert.match(read(app + 'New/BrowserAgentRequest.swift'), /self\.deadline = now \+ \(pageTools \? 60 : 40\)/);
  assert.match(read('Engines/browser-mcp/server.mjs'), /method === 'page_tool_call' \? 65_000 : 45_000/);
  const model = read(app + 'Facade/ChatPageModel.swift');
  assert.match(section(model, 'func webMCPRequestScope(', 'func queueBrowserAgentNavigation('),
    /selectedThreadID == caller/);
  assert.match(section(model, 'private func computerUseScope(', 'func browserAgentRequestScope('),
    /record.roomReadOnly != true/);
  for (const engine of ['claude', 'codex', 'grok']) {
    const source = read(`Engines/${engine}-sidecar/sidecar.mjs`);
    assert.match(source, /browser-mcp\/server.mjs/);
    assert.match(source, /tatwo2_browser/);
    assert.match(source, /TATWO2_THREAD_ID/);
  }
  const html = read('tests/fixtures/webmcp-demo.html');
  assert.equal((html.match(/navigator.modelContext.registerTool\(/g) ?? []).length, 2);
  assert.match(html, /document.modelContext\?\.__tatwoWebMCP/);
});

test('swiftc production runtime: snapshots, limits, effect/policy matrices, consent, stale, audit, cancellation', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const dir = path.join(root, '.build/w48/runtime-fixture');
  fs.mkdirSync(dir, { recursive: true });
  const security = read(app + 'Browser/EmbeddedBrowserSecurity.swift');
  const sources = ['Chat/TatwoCodexSandboxMode.swift', 'Chat/TatwoPermissionPreset.swift',
    'New/ComputerUseConsentPolicy.swift', 'Browser/BrowserActor.swift',
    'Browser/TatwoWebMCPRuntime.swift', 'Browser/TatwoBrowserLaneCore.swift',
    'Browser/Diagnostics/BrowserDiagnosticsPrivacy.swift', 'Browser/Diagnostics/BrowserPolicyLog.swift',
    'Browser/BrowserTabRegistry.swift'].map(p => read(app + p)).join('\n');
  const code = sources + `
enum NativeStagingIsolation { static func isEnabled(_ environment: [String:String]) -> Bool { false } }
@MainActor final class IslandNotice {
    static let shared = IslandNotice()
    func confirm(title: String, detail: String, confirmLabel: String, timeout: TimeInterval) async -> Bool { false }
}
${section(security, 'enum EmbeddedBrowserNavigationBlockReason', 'enum EmbeddedBrowserVisibleError')}
${section(security, 'enum EmbeddedBrowserSiteToolEffect', 'enum EmbeddedBrowserAutomationExposurePolicy')}
` + `
enum ComputerUseSession { struct Grant {} }
${section(read(app + 'New/BrowserAgentRequest.swift'), 'struct BrowserAgentRequestError:', '/// Internal state digest')}
struct FixtureThread { var botPermissionPreset: TatwoPermissionPreset?; var roomReadOnly: Bool? }
@MainActor final class FixtureLive {
    var thread = FixtureThread()
    func threadRecord(_ id: UUID) -> FixtureThread? { thread }
}
@MainActor final class FixtureModel {
    let browserTabRegistry = BrowserTabRegistry()
    var permissionPreset: TatwoPermissionPreset? = .askFirst
    let live: FixtureLive? = FixtureLive()
}
@MainActor final class FixtureBridge {
    var model: FixtureModel? = FixtureModel()
${section(read(app + 'Facade/BrowserAgentBridge.swift'), '    private static func validatePageToolParameters(', '    private func callPageTool(')}
    func checkTargets() throws {
        let registry = model!.browserTabRegistry
        let caller = UUID(), other = UUID()
        let request = BrowserAgentRequest(caller: caller, scope: "fixture", epoch: 1, pageTools: true, now: 100)
        precondition(request.deadline == 160)
        let nativeRequest = BrowserAgentRequest(caller: caller, scope: "fixture", epoch: 1, now: 100)
        precondition(nativeRequest.deadline == 140 && !nativeRequest.pageTools)
        try request.validate(currentScope: "fixture", currentEpoch: 1, connected: true, now: 110)
        for (scope, epoch, connected, now) in [("other", UInt64(1), true, 110.0),
            ("fixture", UInt64(2), true, 110.0), ("fixture", UInt64(1), false, 110.0),
            ("fixture", UInt64(1), true, 160.0)] {
            do { try request.validate(currentScope: scope, currentEpoch: epoch, connected: connected, now: now); fatalError("stale caller") } catch {}
        }
        let workspace = registry.spaces.first { !$0.isSessionSpace }!
        let tab = registry.openTab(owner: .workSpace(spaceID: workspace.id), url: URL(string: "https://example.com"))
        let own = registry.openTab(owner: .chatSession(sessionID: caller.uuidString), url: tab.url)
        let foreign = registry.openTab(owner: .chatSession(sessionID: other.uuidString), url: tab.url)
        registry.openTab(owner: .bot(botID: "fixture"), url: tab.url)
        precondition(Set(pageToolTabs(request).map(\\.id)) == [tab.id, own.id])
        // W60b: new tabs start asleep (no live renderer) until a surface mounts them.
        // Page tools only exist on a mounted page, so simulate the mount here.
        registry.markSleeping(tab.id, false)
        let params: [String: Any] = ["tabID": tab.id.uuidString]
        let workspaceTarget = try pageToolTarget(params, request: request)
        precondition(workspaceTarget.1 == tab.id.uuidString)
        do { _ = try pageToolTarget(["tabID": foreign.id.uuidString], request: request); fatalError("foreign tab") } catch {}
        registry.markSleeping(tab.id, true)
        do { _ = try pageToolTarget(params, request: request); fatalError("sleeping tab") } catch {}
        registry.markSleeping(tab.id, false)
        TatwoWebMCPRuntime.shared.update(tabID: tab.id.uuidString, snapshotJSONString: WebMCPChecks.snapshot(origin: "https://other.example"))
        do { _ = try pageToolTarget(params, request: request); fatalError("changed origin") } catch {}
        TatwoWebMCPRuntime.shared.detach(tabID: tab.id.uuidString)
        let lane = TatwoBrowserLane(id: .init(rawValue: "legacy-w48"), binding: .unboundReadOnly, title: "Legacy",
            createdAt: Date(), lastActiveAt: Date())
        let state = TatwoBrowserLaneState(lanes: [lane])
        // Legacy IDs are not the registry UUID. Use the real adapter to build them.
        let legacyID = state.lanes[0].id.rawValue
        registry.storeLanes(BrowserLaneSnapshot(laneState: state,
            laneURLs: [legacyID: URL(string: "https://example.com")!], updatedAt: Date()), for: caller.uuidString)
        let legacy = registry.tabs(ownedBy: .chatSession(sessionID: caller.uuidString)).first {
            registry.runtimeTabID(for: $0.id) == legacyID
        }!
        precondition(legacy.id.uuidString != legacyID)
        let legacyTarget = try pageToolTarget(["tabID": legacy.id.uuidString], request: request)
        precondition(legacyTarget.1 == legacyID)
        registry.storeLanes(BrowserLaneSnapshot(laneState: state,
            laneURLs: [legacyID: URL(string: "https://example.com")!], updatedAt: Date()), for: other.uuidString)
        precondition(registry.runtimeTabID(for: legacy.id) == nil, "ambiguous legacy IDs must fail closed")
        registry.move(legacy.id, to: .workSpace(spaceID: workspace.id))
        precondition(registry.runtimeTabID(for: legacy.id) == legacy.id.uuidString)
        try Self.validatePageToolParameters("page_tool_call", params: [
            "callerThreadID": caller.uuidString, "tabID": tab.id.uuidString, "tool": "get_note", "arguments": [:]])
        do {
            try Self.validatePageToolParameters("page_tool_call", params: [
                "callerThreadID": caller.uuidString, "tabID": tab.id.uuidString, "tool": "get_note", "arguments": [:], "preset": "fullAccess"])
            fatalError("policy override")
        } catch {}
        model!.permissionPreset = .fullAccess
        model!.live!.thread.botPermissionPreset = .configFile
        let fullCaller = try pageToolCaller(request)
        precondition(fullCaller.preset == .fullAccess)
        model!.live!.thread.botPermissionPreset = .askFirst
        model!.live!.thread.roomReadOnly = true
        let context = try pageToolCaller(request)
        precondition(context.preset == .askFirst && context.readOnly)
        print("W48 real registry/bridge helpers PASS: target ownership, sleeping, origin, legacy IDs, caller preset")
    }
}
` + read('tests/fixtures/webmcp-runtime-checks.swift');
  const file = path.join(dir, 'main.swift'), binary = path.join(dir, 'fixture');
  fs.writeFileSync(file, code);
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2', file, '-o', binary],
    { cwd: root, encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const run = spawnSync(binary, [dir], { encoding: 'utf8', timeout: 20000 });
  fs.writeFileSync(path.join(dir, 'result.log'), run.stdout + run.stderr);
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W48 runtime fixture PASS/);
  process.stdout.write(run.stdout);
});

test('real stdio catalog + UNIX socket forwards exact WebMCP methods and rejects authority overrides', { timeout: 15000 }, async t => {
  const dir = path.join(root, '.build/w48');
  fs.mkdirSync(dir, { recursive: true });
  // Keep sun_path short even when the fixture runs in a long worktree path.
  const socketPath = path.join(dir, `m${process.pid}.sock`);
  const caller = '10000000-0000-4000-8000-000000000048';
  const tabID = '20000000-0000-4000-8000-000000000048';
  const requests = [];
  const server = net.createServer(socket => {
    let input = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => { input += chunk; });
    socket.on('end', () => {
      const request = JSON.parse(input);
      requests.push(request);
      socket.end(JSON.stringify({ id: request.id, ok: true, result: { result: '{"fixture":true}' } }) + '\n');
    });
  });
  server.listen(socketPath);
  await once(server, 'listening');
  const child = spawn(process.execPath, ['Engines/browser-mcp/server.mjs'], {
    cwd: root, env: { ...process.env, TATWO2_THREAD_ID: caller, TATWO2_BROWSER_SOCKET: socketPath },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const lines = readline.createInterface({ input: child.stdout });
  const pending = new Map();
  let id = 0, stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  lines.on('line', line => {
    const reply = JSON.parse(line); pending.get(reply.id)?.(reply); pending.delete(reply.id);
  });
  t.after(async () => {
    child.stdin.end();
    if (child.exitCode === null) await once(child, 'exit');
    lines.close();
    await new Promise(resolve => server.close(resolve));
    assert.equal(stderr, '');
  });
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const requestID = ++id;
    const timer = setTimeout(() => reject(new Error('stdio timeout')), 5000);
    pending.set(requestID, reply => { clearTimeout(timer); resolve(reply); });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: requestID, method, params }) + '\n');
  });
  const catalog = (await rpc('tools/list')).result.tools;
  for (const name of ['browser_tabs', 'page_tools_list', 'page_tool_call']) {
    const tool = catalog.find(t => t.name === name);
    assert.ok(tool);
    assert.equal(tool.inputSchema.additionalProperties, false);
    assert.ok(!tool.inputSchema.required.includes('sessionID'));
    assert.ok(!Object.hasOwn(tool.inputSchema.properties, 'preset'));
  }
  assert.equal(catalog.find(t => t.name === 'page_tool_call').inputSchema.properties.arguments.type, 'object');
  assert.equal(catalog.find(t => t.name === 'page_tool_call').inputSchema.properties.arguments.additionalProperties, true);
  assert.deepEqual(catalog.find(t => t.name === 'page_tool_call').inputSchema.required, ['tabID', 'tool', 'arguments']);
  const calls = [
    ['browser_tabs', {}],
    ['page_tools_list', { tabID }],
    ['page_tool_call', { tabID, tool: 'set_note', arguments: { note: '繁體中文', x: 1, nested: { value: [null, true, 3] } } }],
  ];
  for (const [name, args] of calls) {
    const reply = await rpc('tools/call', { name, arguments: args });
    assert.notEqual(reply.result.isError, true);
    assert.equal(requests.at(-1).method, name);
    assert.deepEqual(requests.at(-1).params, { ...args, callerThreadID: caller });
  }
  const count = requests.length;
  for (const args of [
    { tabID, tool: 'set_note', arguments: {}, preset: 'fullAccess' },
    { tabID, tool: 'set_note', arguments: {}, readOnlyCaller: false },
    { tabID, tool: 'set_note', arguments: {}, callerThreadID: tabID },
    { tabID, tool: 'set_note', arguments: [] },
    { tabID, tool: '', arguments: {} },
    { tabID, tool: '界'.repeat(43), arguments: {} },
    { tabID, tool: 'set_note', arguments: { note: 'x'.repeat(1_048_576) } },
    { tabID: 'other-tab', tool: 'get_note', arguments: {} },
  ]) {
    assert.equal((await rpc('tools/call', { name: 'page_tool_call', arguments: args })).result.isError, true);
  }
  assert.equal(requests.length, count);
  assert.ok(catalog.find(t => t.name === 'browser_read').inputSchema.required.includes('sessionID'));
});

test('W48-fix: bridge installs navigator.modelContext (W3C) plus document alias; Island title within 14 characters', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  assert.match(bridge, /global \? global->GetValue\("navigator"\) : nullptr/);
  assert.match(bridge, /navigator->SetValue\(\s*"modelContext"/);
  assert.match(bridge, /Object\.defineProperty\(navigator,'modelContext'/);
  const runtime = read('App/Sources/Tatwo2/Browser/TatwoWebMCPRuntime.swift');
  for (const title of ['網頁想讀取資料', '網頁想執行工具']) {
    assert.ok(runtime.includes(`"${title}"`));
    assert.ok([...title].length <= 14);
  }
  assert.doesNotMatch(runtime, /想執行 \\\(Self\.singleLine\(name\)\)"/);
});
