import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const model = read('App/Sources/Tatwo2/Facade/ChatPageModel.swift');
const engine = read('App/Sources/Tatwo2/Facade/ChatLiveEngine.swift');
const planEngine = read('App/Sources/Tatwo2/Facade/ChatLiveEngine+Plan.swift');
const artifact = read('App/Sources/Tatwo2/Chat/TatwoPlanArtifact.swift');
const page = read('App/Sources/Tatwo2/Chat/ChatPage.swift');
const canvas = read('App/Sources/Tatwo2/Chat/ChatPage+Plan.swift');
const checks = read('App/Sources/Tatwo2/SelfTest.swift');

test('plan is real state, with exact slash token and reopen request', () => {
  assert.match(model, /var isPlanModeEnabled: Bool \{ activePlanArtifact\?\.state == \.discussing \}/);
  assert.doesNotMatch(model, /var isPlanModeEnabled: Bool \{ false \}/);
  assert.match(model, /planCommand\.split\(whereSeparator: \\\.isWhitespace\)\.first == "\/plan"/);
  assert.match(model, /objective: String\(objective\.prefix\(60\)\)/);
  assert.match(model, /@Published var planInspectorRequest: UUID\?/);
  assert.match(page, /\.onChange\(of: model\.planInspectorRequest\)/);
  assert.match(page, /if request != nil \{ planInspectorPresented = true \}/);
});

test('per-turn rule uses existing outgoing vs displayed text split, not session prompt', () => {
  for (const heading of ['做什麼', '動哪些檔', '怎麼驗', '風險與問題']) {
    assert.ok(planEngine.includes(`## ${heading}`));
  }
  assert.match(planEngine, /只討論不動手、不改檔、不跑會改狀態的指令/);
  assert.match(planEngine, /使用者說「開始」之前都維持此模式/);
  const shown = engine.indexOf('let shown = ChatAttachmentTranscript.displayTurn(text: t');
  const hidden = engine.indexOf('if let planBriefing { outgoing += "\\n\\n" + planBriefing }');
  const sent = engine.indexOf('sidecar.send(text: outgoing');
  assert.ok(shown >= 0 && hidden > shown && sent > hidden);
  assert.doesNotMatch(engine, /OSUpstream\.compose\([^)]*planDiscussionRules/);
});

test('only successful terminal reply updates its owning plan, keeping transcript fence', () => {
  assert.match(engine, /if succeeded, runningThreads\.contains\(threadID\)/);
  assert.match(engine, /\$0\.turnID == turnID\[threadID\] && \$0\.role == \.assistant/);
  assert.match(engine, /updatePlanFromReply\(threadID, reply: reply\)/);
  assert.match(planEngine, /plan\.state == \.discussing/);
  assert.match(planEngine, /parseSections\(fromReply: reply\.text\)/);
  assert.match(planEngine, /plan\.sourceAssistantMessageID = reply\.id/);
  assert.doesNotMatch(planEngine, /reply\.text\s*=/);
});

test('confirm is explicit, waits for start, and persists one-shot consumption', () => {
  assert.match(model, /func confirmActivePlan\(\)[\s\S]*?plan\.confirm\(\)/);
  assert.ok(model.includes('計畫已確認；按「開始實作」或說「開始」即執行'));
  assert.match(planEngine, /plan.acceptsStart\(userText\)[\s\S]*?使用者已確認以下計畫/);
  assert.match(planEngine, /guard plan\.executionTurnID == nil else \{ return nil \}/);
  assert.match(engine, /confirmed\.executionTurnID = turn[\s\S]*?savePlanArtifact\(confirmed\)/);
  assert.match(artifact, /decodeIfPresent\(String\.self, forKey: \.executionTurnID\)/);
  assert.match(canvas, /else if selection == nil/);
  assert.match(canvas, /Button\("開始實作", action: onStart\)/);
  assert.match(canvas, /artifact.state == \.confirmed[\s\S]*artifact.executionTurnID == nil/);
  assert.match(canvas, /plan-canvas-start/);
  assert.match(page, /onStart: model.startActivePlan/);
  assert.match(engine, /if var confirmed = plan, confirmed.acceptsStart\(t\)/);
  assert.match(canvas, /Button\("實作中…"\)[\s\S]*?disabled\(true\)/);
  assert.doesNotMatch(model, /if planCommand == "開始", isPlanModeEnabled/);
  assert.match(model, /func startActivePlan\(\)[\s\S]*?plan.acceptsStart\("開始"\)/);
});

test('editor shares heading parser; persistence uses live store root and atomic JSON', () => {
  assert.match(model, /editablePlanTextForCanvas\(\) -> String\? \{ activePlanArtifact\?\.editableText\(\) \}/);
  assert.match(model, /plan\.applyEditedText\(text\)/);
  assert.match(artifact, /Self\.markdownSections\(remainder\)/);
  assert.match(artifact, /let sections = markdownSections/);
  assert.match(planEngine, /store\.url\.deletingLastPathComponent\(\)\.appendingPathComponent\("plans"/);
  assert.match(planEngine, /plan\.canonicalJSONData\(\)\.write\(to: url, options: \.atomic\)/);
  assert.match(model, /composerRevision &\+= 1\s+loadActivePlanCanvas\(\)/);
  assert.match(canvas, /if onSaveEditedText\(editedText\) \{ isEditing = false \}/);
});

test('legacy flow seams remain unchanged; executable Swift checks cover three reply cases', () => {
  assert.match(model, /var planFlowSelectionProjection: PlanFlowSelectionProjectionV1\? \{ nil \}/);
  assert.match(model, /var planWorkOSLocalActionPresentation: ChatPlanWorkOSLocalActionPresentation \{ \.idle \}/);
  assert.match(model, /func updatePlanFlowSelection\(_ selection: TatwoPlanArtifactV1\.PlanFlowSelectionV1\) \{\}/);
  for (const label of ['fenced reply', 'no fence', 'missing heading keeps only three sections',
    'one-shot survives reload', 'switch back restores canvas', 'confirmation still waits for start']) {
    assert.ok(checks.includes(`check("${label}"`));
  }
  assert.match(checks, /TATWO2_PLANCANVASTEST/);
});

test('production Swift start predicate and planContext enforce two-stage and PR isolation', async () => {
  const { mkdtempSync, writeFileSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { spawnSync } = await import('node:child_process');
  const root = mkdtempSync(join(tmpdir(), 'w32-plan-'));
  const predicate = artifact.slice(artifact.indexOf('  func acceptsStart'), artifact.indexOf('  public struct Section:'));
  const startAction = model.slice(model.indexOf('    func startActivePlan()'), model.indexOf('    func returnActivePRToDiscussion()'));
  const rules = planEngine.slice(planEngine.indexOf('    static let feedbackDiscussionRules'), planEngine.indexOf('    private func planURL'));
  const context = planEngine.slice(planEngine.indexOf('    func planContext'), planEngine.indexOf('    func updatePlanFromReply'));
  writeFileSync(join(root, 'main.swift'), `import Foundation
struct TatwoPlanArtifactV1 {
 enum State { case discussing, confirmed, ready }
 var kind: String? = nil, state: State = .discussing, executionTurnID: String? = nil
 let threadID = UUID()
 func editableText() -> String { "fixture plan" }
 ${predicate}
}
struct ChatLiveEngine {
 var onTurnComplete: [UUID: Bool] = [:]
 ${rules}
 ${context}
}
let engine = ChatLiveEngine()
var plan = TatwoPlanArtifactV1()
let starts = ["開始", "開始吧", "開始！", " 開始 ", "start", "START", "go", " Go\\n"]
for text in starts {
 precondition(!plan.acceptsStart(text))
 precondition(engine.planContext(plan, userText: text)!.contains("只討論不動手"))
}
plan.state = .confirmed
for text in starts {
 precondition(plan.acceptsStart(text))
 precondition(engine.planContext(plan, userText: text)!.contains("現在可以動手"))
}
for text in ["等一下", "", "restart", "start now", "go!"] {
 precondition(!plan.acceptsStart(text))
 precondition(engine.planContext(plan, userText: text)!.contains("不可執行"))
}
plan.executionTurnID = "consumed"
for text in starts { precondition(!plan.acceptsStart(text)) }
plan.executionTurnID = nil
for kind in ["pr", "feedback"] {
 plan.kind = kind
 for state in [TatwoPlanArtifactV1.State.discussing, .confirmed, .ready] {
  plan.state = state
  for text in starts {
   precondition(!plan.acceptsStart(text))
   precondition(!engine.planContext(plan, userText: text)!.contains("現在可以動手"))
  }
 }
}
final class LocalLive {
 var running = false
 func isRunning(_ id: UUID) -> Bool { running }
}
final class Model {
 var selectedRemote: String? = nil, selectedThreadID: UUID? = nil
 var activePlanArtifact: TatwoPlanArtifactV1?
 var localLive: LocalLive? = LocalLive()
 var preparingPR = false, pendingPR = Set<UUID>()
 var prompt = "existing draft", droppedPaths = ["draft.png"], droppedPathDisplayNames = ["draft.png": "Image"]
 var calls = 0, accept = true
 func send() {
  calls += 1
  precondition(prompt == "開始" && droppedPaths.isEmpty && droppedPathDisplayNames.isEmpty)
  if accept { activePlanArtifact?.executionTurnID = "turn"; prompt = "" }
 }
 ${startAction}
}
for accept in [false, true] {
 let m = Model()
 m.accept = accept
 m.activePlanArtifact = TatwoPlanArtifactV1()
 m.selectedThreadID = m.activePlanArtifact!.threadID
 m.startActivePlan(); precondition(m.calls == 0)
 m.activePlanArtifact!.state = .confirmed
 m.localLive!.running = true
 m.startActivePlan(); precondition(m.calls == 0)
 m.localLive!.running = false
 m.startActivePlan(); precondition(m.calls == 1)
 precondition(m.prompt == "existing draft" && m.droppedPaths == ["draft.png"] && m.droppedPathDisplayNames == ["draft.png": "Image"])
 if accept { m.startActivePlan(); precondition(m.calls == 1) }
 else { precondition(m.activePlanArtifact!.executionTurnID == nil) }
}
print("W32 production plan fixture passed")
`);
  const build = spawnSync('swiftc', [join(root, 'main.swift'), '-o', join(root, 'fixture')], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(root, 'fixture'), [], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
});
