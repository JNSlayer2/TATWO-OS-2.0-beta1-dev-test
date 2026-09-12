import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
const artifact = read('Chat/TatwoPlanArtifact.swift');
const model = read('Facade/ChatPageModel.swift');
const engine = read('Facade/ChatLiveEngine+Plan.swift');
const canvas = read('Chat/ChatPage+Plan.swift');
const actions = read('Chat/FeedbackPlanActions.swift');
const coordinator = read('Facade/FeedbackCoordinator.swift');
const checks = read('SelfTest.swift');

test('optional artifact kind decodes old JSON and shares the labelled fence parser', () => {
  assert.match(artifact, /public var kind: String\?/);
  assert.match(artifact, /decodeIfPresent\(String\.self, forKey: \.kind\)/);
  assert.match(artifact, /fenceName: String = "tatwo-plan"/);
  assert.match(engine, /plan\.kind == "feedback"[\s\S]*parseSections\(fromReply: reply\.text, fenceName: "tatwo-issue"\)/);
});

test('nonempty feedback uses the canvas and ordinary send; bare feedback keeps the old panel', () => {
  const handler = model.slice(model.indexOf('func handleFeedbackCommand()'), model.indexOf('func send()'));
  assert.match(handler, /if !argument\.isEmpty \{[\s\S]*kind: "feedback"[\s\S]*persistPlanCanvas\(plan\)[\s\S]*planInspectorRequest = UUID\(\)[\s\S]*return false/);
  assert.match(handler, /FeedbackCoordinator\.shared\.present\(source: "Chat", initialText: argument\)/);
  assert.match(handler, /rejectRemoteWrite\("\/feedback"\)/);
  assert.match(handler, /!engine\.isRunning\(id\), !pendingPR\.contains\(id\)/);
  assert.match(model, /func send\(\) \{\s+if handleFeedbackCommand\(\) \{ return \}/);
  assert.match(model, /func confirmActivePlan\(\)[\s\S]*?plan\.kind != "feedback"/);
});

test('hidden discussion rules ask first, forbid submission and contain all six headings', () => {
  const rules = engine.slice(engine.indexOf('static let feedbackDiscussionRules'), engine.indexOf('static let planDiscussionRules'));
  for (const title of ['標題', '環境', '重現步驟', '預期', '實際', '附註']) assert.ok(rules.includes(`## ${title}`));
  assert.ok(rules.includes('2–3 個問題'));
  assert.ok(rules.includes('不要替使用者提交'));
  assert.match(engine, /return Self\.feedbackDiscussionRules \+[\s\S]*plan\.editableText\(\)/);
  assert.match(model, /FeedbackEnvironment\.current\(engine: routeChoice\.engine\.rawValue\)/);
  assert.match(engine, /sections\.insert\(environment, at:/);
});

test('human submit reuses coordinator review and submit with manual and stale-payload guards', () => {
  assert.match(canvas, /Text\(ChatPlanArtifactTranscriptProjection\.title\(for: artifact\)\)/);
  assert.match(canvas, /case "feedback": "回報問題"/);
  assert.match(canvas, /if artifact\.kind == "feedback" \{\s+FeedbackPlanActions/);
  assert.match(actions, /"提交 Issue", action: submitIssue/);
  assert.match(actions, /coordinator\.title = issueTitle[\s\S]*coordinator\.content = issueBody[\s\S]*coordinator\.review\(\)/);
  assert.match(actions, /phase == \.reviewed, requestedText == artifact\.editableText\(\), !isDisabled,[\s\S]*!coordinator\.requiresManualConfirmation \{ coordinator\.submit\(\) \}/);
  assert.match(actions, /coordinator\.manualConfirmation/);
  assert.match(actions, /coordinator\.checkSubmission/);
  assert.match(actions, /coordinator\.title == issueTitle, coordinator\.content == issueBody/);
  assert.match(actions, /filter \{ \$0\.title != "標題" \}/);
  assert.doesNotMatch(actions, /FeedbackService\(|URLSession|httpMethod|newDraft\(/);
});

test('canvas retains issue URL, isolates draft ownership and exposes in-place GH device login', () => {
  assert.match(actions, /https:\/\/github\.com\/\\\(coordinator\.destination\)\/issues\/\\\(number\)/);
  assert.match(actions, /FeedbackStatusMessage/);
  assert.ok(read('New/FeedbackPanel.swift').includes('請先登入github才能提交issue'));
  assert.ok(actions.includes('"登入 GitHub"'));
  assert.match(actions, /try await accounts\.loginViaGH\(\)/);
  assert.match(actions, /accounts\.deviceCode/);
  assert.match(actions, /accounts\.submitLoginInput\(""\)/);
  assert.match(coordinator, /planID\.map \{ \$0\.uuidString \+ "\.json" \} \?\? "draft\.json"/);
  assert.match(coordinator, /if let coordinator = canvases\[id\] \{ return coordinator \}/);
});

test('executable Swift checks cover feedback parse, migration, environment and command dispatch', () => {
  for (const name of ['issue fence has six sections', 'legacy JSON without kind',
    'issue fence cannot update plan', 'unfinished issue ignored', 'issue environment owned by app',
    'feedback start never executes', 'feedback cannot confirm plan', 'feedback edit keeps environment',
    'feedback command opens discussing canvas', 'feedback command retains rejected draft']) {
    assert.ok(checks.includes(`check("${name}"`));
  }
});

test('submitted callback is artifact-scoped and incomplete or busy canvases cannot submit', () => {
  assert.match(actions, /if case \.submitted = phase \{ onSubmitted\(artifact\.planID\) \}/);
  assert.match(model, /func finishFeedbackPlan\(_ id: UUID\)[\s\S]*?plan\.planID == id[\s\S]*?plan\.confirm\(\)/);
  assert.match(actions, /guard !isDisabled, complete else \{ return \}/);
  assert.match(actions, /matches\.count == 1 && !matches\[0\]\.body/);
  assert.match(actions, /\.onDisappear \{ requestedText = nil \}/);
  assert.match(actions, /requestedText = nil; coordinator\.repositoryChanged\(\)/);
});
