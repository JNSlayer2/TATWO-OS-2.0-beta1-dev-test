import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
const plan = read('Chat/ChatPage+Plan.swift');
const transcript = read('Chat/ChatPage+Transcript.swift');
const timeline = read('Chat/ChatPageLeafViews+WorkTimeline.swift');
const checks = read('SelfTest.swift');

test('attached card follows the display item containing its source, including folded timelines', () => {
  assert.match(plan, /placement\.completedArtifact == \.attachedToSourceAssistant/);
  assert.match(plan, /case \.message\(let message\):\s*message\.id == sourceAssistantMessageID/);
  assert.match(plan, /case \.workTimeline\(let timeline\):\s*timeline\.messages\.contains \{ \$0\.id == sourceAssistantMessageID \}/);
  assert.match(plan, /result\.insert\(\.planSummary\(sourceMessageID: sourceAssistantMessageID\), at: index \+ 1\)/);
  assert.match(transcript, /return ChatPlanArtifactTranscriptProjection\.displayItems\(/);
  assert.match(transcript, /case \.planSummary:\s*PlanTranscriptSummaryView\(\s*artifact: planArtifact,\s*isWriting: false,\s*isSidePanelPresented: \$planInspectorPresented\)/);
  assert.match(transcript, /planArtifact: nil,/); // Bubble remains intact; display items own the card.
});

test('missing or nil source appends standalone; absent artifact does not create a card', () => {
  assert.match(plan, /guard placement\.completedArtifact != \.none else \{ return items \}/);
  assert.match(plan, /else \{\s*result\.append\(\.planSummary\(sourceMessageID: nil\)\)/);
  assert.match(timeline, /case planSummary\(sourceMessageID: String\?\)/);
  assert.match(timeline, /"tatwo-plan-standalone-summary"/);
  assert.doesNotMatch(transcript, /if let standalonePlanArtifact/);
});

test('both headers use one kind title function, including feedback and PR', () => {
  assert.match(plan, /static func title\(for artifact: TatwoPlanArtifactV1\?\) -> String/);
  assert.match(plan, /case "feedback": "回報問題"/);
  assert.match(plan, /case "pr": "PR 計畫"/);
  assert.equal((plan.match(/Text\(ChatPlanArtifactTranscriptProjection\.title\(for: artifact\)\)/g) ?? []).length, 2);
});

test('closing the inspector retains the card and the existing open actions', () => {
  const display = transcript.slice(transcript.indexOf('private var displayItems:'), transcript.indexOf('private var latestAssistantMessageID:'));
  assert.doesNotMatch(display, /planInspectorPresented/);
  assert.match(plan, /if let artifact, !isSidePanelPresented \{\s*planBody\(artifact\)/);
  assert.match(plan, /private func openPlanSidePanel\(\) \{\s*if !isSidePanelPresented \{\s*isSidePanelPresented = true/);
  assert.match(plan, /Button \{\s*openPlanSidePanel\(\)/);
  assert.match(read('Facade/ChatPageModel.swift'), /if objective\.isEmpty \{\s*if activePlanArtifact != nil \{ planInspectorRequest = UUID\(\); prompt = "" \}/);
  assert.match(read('Chat/ChatPage.swift'), /if request != nil \{ planInspectorPresented = true \}/);
});

test('source prose uses the existing timeline expansion, never raw thinking', () => {
  assert.match(transcript, /timeline\.messages\.contains \{ \$0\.id == planArtifactMessageID \}/);
  assert.match(transcript, /messages\.first \{ \$0\.id == planArtifactMessageID && \$0\.role == \.assistant && \$0\.eventKind == \.message \}\?\.text/);
  assert.match(timeline, /isExpanded\.toggle\(\)/);
  assert.match(timeline, /if isExpanded \{[\s\S]*?if let planSourceText \{\s*ChatAssistantTranscriptBlockView/);
  assert.match(timeline, /Text\(planSourceText != nil \? "計畫已整理"/);
});

test('Swift self-test exercises real display building and fallback scenarios', () => {
  for (const label of [
    'attached summary immediately follows source timeline',
    'attached summary is unique and precedes next message',
    'missing source falls back to standalone summary',
    'nil source ends with standalone summary',
    'empty transcript retains standalone summary',
    'no artifact produces no summary',
    'folding preserves source and keeps projection empty',
  ]) assert.ok(checks.includes(`check("${label}"`), label);
  assert.match(checks, /ChatTranscriptDisplayBuilder\.build\(ChatPlanThoughtPresentation\.projectedMessages/);
});
