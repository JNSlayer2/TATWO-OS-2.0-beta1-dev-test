import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
const model = read('Facade/ChatPageModel.swift');
const artifact = read('Chat/TatwoPlanArtifact.swift');
const review = read('Chat/PRPlanReview.swift');
const actions = read('Chat/PRPlanActions.swift');
const service = read('Facade/PullRequestService.swift');
const engine = read('Facade/ChatLiveEngine+Plan.swift');
const checks = read('SelfTest.swift');

test('PR text creates discussing canvas without invoking contribution; bare command retains sheet', () => {
  const send = model.slice(model.indexOf('func send()'), model.indexOf('private func startPRContribution'));
  assert.match(send, /if !title\.isEmpty \{[\s\S]*kind: "pr"[\s\S]*persistPlanCanvas\(plan\)[\s\S]*planInspectorRequest = UUID\(\)/);
  assert.doesNotMatch(send, /startPRContribution\(/);
  assert.match(send, /PullRequestCoordinator\.shared\.present\(directory:/);
  assert.match(engine, /plan\.kind == "pr"[\s\S]*planDiscussionRules[\s\S]*這是要送回公開倉庫的貢獻/);
  assert.match(model, /planCommand == "開始"[^\n]*activePlanArtifact\?\.kind != "pr"/);
});
test('only confirmation starts implementation with editable plan; completion cannot submit', () => {
  const confirm = model.slice(model.indexOf('func confirmActivePlan()'), model.indexOf('func editablePlanTextForCanvas'));
  assert.match(confirm, /plan\.confirm\(\)[\s\S]*persistPlanCanvas\(plan\)[\s\S]*plan\.kind == "pr"[\s\S]*startPRContribution\(description: plan\.editableText\(\), threadID: plan\.threadID\)/);
  const contribution = model.slice(model.indexOf('private func startPRContribution'), model.indexOf('func submitActivePRPlan'));
  assert.match(contribution, /contributionCheckout\(/);
  assert.match(contribution, /PRPlanReview\.sections\(reply\)/);
  assert.match(contribution, /PullRequestService\.snapshot\(at: checkout\.directory\)/);
  assert.match(contribution, /plan\.state = \.ready/);
  assert.doesNotMatch(contribution, /submitContribution\(|\.submit\(|replyDraft\(|NSWorkspace\.shared\.open/);
  assert.match(contribution, /plan\.planID == sourcePlan\.planID/);
  assert.match(contribution, /threadID: id[\s\S]*state: \.confirmed, kind: "pr"/);
});
test('five headings and optional Codable review preserve legacy artifacts', () => {
  for (const title of ['標題', '改了什麼', '動到的檔', '怎麼驗的', '風險與回滾']) assert.ok(service.includes(`## ${title}`));
  assert.ok(service.includes('```tatwo-pr'));
  assert.match(artifact, /case ready/);
  assert.match(artifact, /decodeIfPresent\(PRPlanReview\.self, forKey: \.prReview\)/);
  assert.match(review, /fenceName: "tatwo-pr"/);
  assert.match(review, /sections\.map\(\\.title\) == titles/);
});
test('explicit send reuses existing submit with card title and remaining Markdown; attempts cannot replay', () => {
  const submit = model.slice(model.indexOf('func submitActivePRPlan'), model.indexOf('func createProjectFromExistingFolder'));
  assert.match(actions, /Button\("送 PR", action: onSubmit\)/);
  assert.match(submit, /plan\.state == \.ready[\s\S]*!review\.attempted/);
  assert.match(submit, /identity\.username == review\.account, PullRequestService\.repository == review\.repository/);
  assert.match(submit, /first \{ \$0\.title == "標題" \}/);
  assert.match(submit, /filter \{ \$0\.title != "標題" \}/);
  assert.match(submit, /review\.attempted = true[\s\S]*persistPlanCanvas\(plan\)[\s\S]*PullRequestCoordinator\.shared\.submitPlan\(directory: review\.directory, repository: review\.repository,[\s\S]*identity: identity, snapshot: review\.snapshot, title: title, description: description\)/);
  const coordinator = read('Facade/PullRequestCoordinator.swift');
  assert.match(coordinator, /func submitPlan[\s\S]*guard !busy, window\?\.isVisible != true[\s\S]*busy = true[\s\S]*defer \{ busy = false \}/);
  assert.match(coordinator, /service\.submit\(directory: directory, repository: repository, identity: current,[\s\S]*snapshot: snapshot, title: title, description: description\)/);
  assert.match(actions, /Link\("已送 PR/);
  assert.match(submit, /error\.localizedDescription/);
});
test('per-file collapsed diff shows counts and caps only preview at 400 lines; GitHub login is in canvas', () => {
  assert.match(actions, /ForEach\(PRPlanReview\.files\(review\.snapshot\.diff\)\)[\s\S]*DisclosureGroup/);
  assert.ok(actions.includes('file.added') && actions.includes('file.removed'));
  assert.match(review, /lines\.prefix\(400\)/);
  assert.match(service, /dropLast\(text\.isEmpty \|\| text\.hasSuffix/);
  assert.ok(review.includes('lines.count > 400 ? "\\n…"'));
  assert.ok(actions.includes('"登入 GitHub"'));
  assert.match(actions, /try await accounts\.loginViaGH\(\)/);
  assert.match(actions, /accounts\.deviceCode[\s\S]*accounts\.submitLoginInput\(""\)/);
  assert.match(read('Chat/ChatPage+Plan.swift'), /artifact\.kind == "pr"[\s\S]*PRPlanActions/);
});
test('executable checks cover fences, fake multi-file diff, persistence and command dispatch', () => {
  for (const name of ['pr fence has five sections', 'unfinished pr ignored', 'incomplete pr ignored',
    'pr diff splits by file', 'pr diff limits 400 lines', 'pr repeated file grouped', 'pr ready survives reload',
    'pr ready edit rejected', 'pr start still discusses', 'pr command discusses without executing', 'pr rejected send retains draft']) {
    assert.ok(checks.includes(`check("${name}"`));
  }
});
