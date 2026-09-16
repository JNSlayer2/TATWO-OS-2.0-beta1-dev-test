import { testScratch } from './helpers/test-scratch.mjs';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import test from 'node:test';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = name => readFileSync(path.join(repo, name), 'utf8');
const minimap = read('App/Sources/Tatwo2/Chat/ChatHistoryMinimap.swift');
const transcript = read('App/Sources/Tatwo2/Chat/ChatPage+Transcript.swift');

test('minimap and transcript use the same rendered row identities', () => {
  assert.match(transcript, /ForEach\(displayItems\)/);
  assert.match(transcript, /ChatHistoryMinimap\(\s*items: displayItems\s*\)/);
  assert.match(minimap, /let items: \[ChatTranscriptDisplayItem\]/);
  assert.match(minimap, /ForEach\(items\)/);
  assert.match(minimap, /\.onTapGesture \{ onJump\(m\.id\) \}/);
  assert.match(transcript, /followState\.detachFromLatest\(\)[\s\S]*?proxy\.scrollTo\(id, anchor: \.top\)/);
  // Do not give each tick a 2pt minimum: dense histories would exceed the
  // measured viewport and make tooltip and click positions disagree.
  assert.match(minimap, /height: slot, alignment: \.leading/);
  assert.doesNotMatch(minimap, /height: max\(slot, 2\)/);
});

test('native display builder, preview projection and SwiftUI surface', {
  skip: process.platform !== 'darwin',
  timeout: 90_000,
}, async () => {
  const run = (command, args, options = {}) => {
    const result = spawnSync(command, args, {
      cwd: repo, encoding: 'utf8', timeout: 60_000, maxBuffer: 1024 * 1024,
      ...options,
    });
    assert.equal(result.status, 0, `${command}: ${result.error || ''}\n${result.stdout}\n${result.stderr}`);
    return result;
  };
  const pressure = run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']).stdout.trim();
  // Previously measured ~372 MiB for this isolated fixture; remain serial.
  // This does not admit full App builds under warning/unknown pressure.
  assert.ok(pressure === '1' || pressure === '2', `defer fixture at pressure=${pressure}`);
  const output = testScratch('tatwo2-history-minimap-');
  mkdirSync(output, { recursive: true });
  const scratch = mkdtempSync(path.join(output, 'minimap-regression.'));
  const lockScript = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquired = run('/bin/bash', [lockScript, 'acquire', '--timeout', '20', '--pid', String(process.pid)]);
  const token = acquired.stdout.match(/^token=([0-9a-f]+)$/m)?.[1];
  assert.ok(token, 'build lock ownership returned');
  try {
    const timeline = read('App/Sources/Tatwo2/Chat/ChatPageLeafViews+WorkTimeline.swift');
    const start = timeline.indexOf('enum ChatInlineWorkState:');
    const end = timeline.indexOf('struct ChatInlineWorkTimelineSummary:');
    assert.ok(start >= 0 && end > start);
    // Compile the actual production grouping and entire minimap View.
    // Doubles below only supply surrounding message/theme/remote types, not
    // the identity, grouping, preview or layout logic being repaired.
    const source = `
import Foundation
import SwiftUI
import AppKit
enum ChatMessageRole { case user, assistant, system }
enum TatwoNativeChatEventKind { case message, thinking, toolUse, failure }
struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: ChatMessageRole
    var text: String = ""
    var status: String? = nil
    var modelID: String? = nil
    var eventKind: TatwoNativeChatEventKind = .message
    var turnID: String? = nil
    var planQuestions: [String] = []
}
enum ChatRemoteJobInlinePresentation {
    static func payload(from status: String?) -> Bool? { nil }
}
@MainActor final class TatwoThemeStore: ObservableObject {
    static let shared = TatwoThemeStore()
}
enum LiquidGlassTokens { static let brandAccent = Color.orange }
extension View {
    func liquidGlassSurface(cornerRadius: CGFloat) -> some View { self }
}
${timeline.slice(start, end)}
${minimap}
@main struct MinimapRegression {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: " + name) }
            checks += 1
            print("PASS: " + name)
        }
        let user = ChatMessage(id: "u1", role: .user, text: "  畫一張圖  ")
        let running = ChatMessage(id: "r1", role: .assistant, status: "thinking",
            modelID: "gpt-6-astra", eventKind: .thinking, turnID: "turn1")
        let tool = ChatMessage(id: "tool1", role: .assistant, status: "calling-tool",
            modelID: "gpt-6-astra", eventKind: .toolUse, turnID: "turn1")
        let done = ChatMessage(id: "done1", role: .assistant, status: "completed",
            modelID: "gpt-6-astra", eventKind: .thinking, turnID: "turn1")
        let answer = ChatMessage(id: "a1", role: .assistant, text: "完成的圖片",
            status: "completed", modelID: "gpt-6-astra", turnID: "turn1")
        let messages = [user, running, tool, done, answer]
        let items = ChatTranscriptDisplayBuilder.build(messages)
        check(items.count == 3, "three work events collapse to one tick")
        check(items.map(\\.id) == ["message:u1", "chat-inline-work-timeline:turn1:gpt-6-astra", "message:a1"],
            "actual message and model-scoped timeline targets")
        let targets = Set(items.map(\\.id))
        check(messages.allSatisfy { !targets.contains($0.id) },
            "fixture reproduces old raw-message target mismatch")
        check(items[0].historyIsUser && !items[1].historyIsUser, "user emphasis preserved")
        check(items[0].historyTitle == "你的指令" && items[1].historyTitle == "工作"
            && items[2].historyTitle == "回覆", "tooltip labels match rendered row")
        check(items[0].historyPreviewText == "畫一張圖", "trim ordinary preview")
        check(items[1].historyPreviewText.contains("已完成"), "timeline shows terminal summary")
        check(items[2].historyPreviewText == "完成的圖片", "final prose remains independently reachable")
        let blank = ChatTranscriptDisplayItem.message(ChatMessage(id: "empty", role: .system, text: " \\n "))
        check(blank.historyPreviewText == "（無文字）" && blank.historyTitle == "系統", "empty and system preview")
        let long = ChatTranscriptDisplayItem.message(ChatMessage(id: "long", role: .user, text: String(repeating: "圖", count: 500)))
        check(long.historyPreviewText.count == 140, "bounded unicode preview")
        var duplicateTool = tool
        duplicateTool.status = "completed"
        let duplicates = ChatTranscriptDisplayBuilder.build([user, running, tool, duplicateTool, answer])
        check(duplicates.count == 3 && Set(duplicates.map(\\.id)).count == 3, "repeated work update is not a new target")
        var otherModel = running
        otherModel.modelID = "fable-5"
        let multi = ChatTranscriptDisplayBuilder.build([user, running, otherModel, answer])
        check(multi.count == 4 && Set(multi.map(\\.id)).count == 4, "same turn distinct models remain separate")
        let many = (0..<600).map { ChatMessage(id: "history-\\($0)", role: $0 % 2 == 0 ? .user : .assistant, text: "訊息 \\($0)") }
        let manyItems = ChatTranscriptDisplayBuilder.build(many)
        check(manyItems.count == 600 && Set(manyItems.map(\\.id)).count == 600, "large history preserves all targets")
        for (name, input) in [("normal", Array(manyItems.prefix(8))), ("dense", manyItems)] {
            let content = ChatHistoryMinimap(items: input, onJump: { _ in })
                .frame(width: 22, height: 320).padding(12)
                .frame(width: 320, height: 360, alignment: .leading)
                .background(Color.white)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { fatalError("render failed: " + name) }
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
            check(image.width == 640 && image.height == 720, name + " real SwiftUI render")
        }
        print("RESULT checks=\\(checks) failures=0")
    }
}
`;
    writeFileSync(path.join(scratch, 'MinimapRegression.swift'), source);
    const compiler = run('/usr/bin/xcrun', ['--find', 'swiftc']).stdout.trim();
    const sdk = run('/usr/bin/xcrun', ['--sdk', 'macosx', '--show-sdk-path']).stdout.trim();
    const binary = path.join(scratch, 'minimap-regression');
    const env = { ...process.env, TMPDIR: scratch };
    const compiled = run('/usr/bin/time', ['-l', compiler, '-j', '2', '-swift-version', '5', '-parse-as-library',
      '-sdk', sdk, '-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx14.0`,
      '-module-cache-path', path.join(output, 'minimap-swift-cache'),
      path.join(scratch, 'MinimapRegression.swift'), '-o', binary], { env });
    writeFileSync(path.join(scratch, 'compile.log'), compiled.stdout + compiled.stderr);
    writeFileSync(path.join(scratch, 'preflight.json'), JSON.stringify({ pressure }, null, 2));
    const result = run(binary, [scratch], { env });
    writeFileSync(path.join(scratch, 'result.log'), result.stdout + result.stderr);
    assert.match(result.stdout, /RESULT checks=15 failures=0/);
    console.log(result.stdout.trim());
    console.log(`Evidence: ${scratch}`);
  } finally {
    run('/bin/bash', [lockScript, 'release', '--token', token, '--pid', String(process.pid)]);
  }
});
