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
  assert.ok(model.includes('計畫已確認；說「開始」即執行'));
  assert.match(planEngine, /== "開始"[\s\S]*?使用者已確認以下計畫/);
  assert.match(planEngine, /guard plan\.executionTurnID == nil else \{ return nil \}/);
  assert.match(engine, /confirmed\.executionTurnID = turn[\s\S]*?savePlanArtifact\(confirmed\)/);
  assert.match(artifact, /decodeIfPresent\(String\.self, forKey: \.executionTurnID\)/);
  assert.match(canvas, /else if selection == nil/);
  assert.match(canvas, /Button\(artifact\.state == \.confirmed \? "計畫已確認" : "確認計畫", action: onExecute\)/);
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
