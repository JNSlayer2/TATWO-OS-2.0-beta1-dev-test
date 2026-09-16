import { testScratch } from './helpers/test-scratch.mjs';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repo = fileURLToPath(new URL('../', import.meta.url));
const source = readFileSync(path.join(repo, 'App/Sources/Tatwo2/New/FeedbackPanel.swift'), 'utf8');
const composer = readFileSync(path.join(repo, 'App/Sources/Tatwo2/Chat/ChatPage+Composer.swift'), 'utf8');
const hash = value => createHash('sha256').update(value).digest('hex');

test('feedback is presentation only and preserves caller-owned text', () => {
  assert.match(source, /@Binding var title: String/);
  assert.match(source, /@Binding var content: String/);
  assert.doesNotMatch(source, /URLSession|Process\(|FileManager|UserDefaults|\.task\s*[{(]|\.onAppear/);
  assert.doesNotMatch(source, /\b(?:title|content)\s*=(?!=)/);
  assert.match(source, /onExitCommand\(perform: close\)/);
  assert.match(source, /請先登入github才能提交issue/);
});

test('native feedback states and compact Chat/note presentation', {
  skip: process.platform !== 'darwin' ? 'Requires native macOS SwiftUI rendering' : false,
}, () => {
  const output = testScratch('tatwo2-feedback-presentation-');
  mkdirSync(output, { recursive: true });
  const root = mkdtempSync(path.join(output, 'feedback-presentation.'));
  const run = (command, args, options = {}) => spawnSync(command, args, {
    cwd: repo, encoding: 'utf8', timeout: 60_000, maxBuffer: 4 * 1024 * 1024, ...options,
  });
  const pressure = run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']);
  writeFileSync(path.join(root, 'preflight.json'), JSON.stringify({
    at: new Date().toISOString(), pressure: pressure.stdout.trim(), sourceSHA256: hash(source),
  }, null, 2));
  assert.equal(pressure.status, 0);
  assert.equal(pressure.stdout.trim(), '1', 'Do not start another compiler under resource pressure');
  const shapeStart = composer.indexOf('    private struct RoundedInvertedTrapezoid: Shape');
  const shapeEnd = composer.indexOf('    // 輸入框下方狀態欄', shapeStart);
  assert.ok(shapeStart >= 0 && shapeEnd > shapeStart);
  const drawerShape = composer.slice(shapeStart, shapeEnd)
    .replace('RoundedInvertedTrapezoid', 'FeedbackFixtureDrawerShape');
  // Compile the real split feedback types; only external app/account seams are inert.
  const dependencies = ['Facade/FeedbackCoordinator.swift', 'Facade/FeedbackService.swift',
    'Facade/FeedbackNativeReview.swift'].map(file =>
    readFileSync(path.join(repo, 'App/Sources/Tatwo2', file), 'utf8')).join('\n');
  const swift = dependencies + '\n' + source + '\nimport AppKit\n' + drawerShape + String.raw`
struct ClaudeSidecar { static func engineHomeRoot() -> URL { fatalError("no engine in presentation fixture") } }
struct GitHubAccountsStore {
    struct Account { var username: String }
    func loadAccounts() throws -> [Account] { [] }
    func mcpToken(username: String) throws -> String? { nil }
}
struct FeedbackFixtureModel {
    struct Login { var isLoggedIn: Bool }
    struct Route { var engine = Engine.none; enum Engine: String { case none } }
    var engineLogins: [Login] = []; var selectedThread: String?; var routeChoice = Route()
}
enum TatwoAppMCPRuntimeRegistry { static var state: Bool { false } }
enum TatwoChatProcessCompositionRegistry {
    static func chatPageModel(_ state: () -> Bool) -> FeedbackFixtureModel { FeedbackFixtureModel() }
}
extension FeedbackPanel {
    var fixtureCanReview: Bool { canReview }
}
@MainActor func runFeedbackFixture() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var checks = 0
    func check(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: \(name)") }
        checks += 1; print("PASS: \(name)")
    }
    let rawTitle = "  輸入框在縮小視窗後錯位  "
    let rawBody = "重現步驟：\n1. 輸入三行文字。\n2. 縮小視窗，再貼入圖片。\n\n預期：文字與按鈕不重疊。\n實際：控制列暫時擠在一起。\n\n  此處空白與原文都須保留。  "
    func panel(_ phase: FeedbackPanel.Phase, account: String? = "示意使用者",
               destination: String? = "示意帳號 / 公測回饋", source: String = "來自 Chat 選定內容",
               title: String = rawTitle, content: String = rawBody) -> FeedbackPanel {
        FeedbackPanel(title: .constant(title), content: .constant(content), source: source,
                      account: account, destination: destination, phase: phase,
                      close: {}, review: {}, edit: {}, submit: {}, checkSubmission: {}, openIssue: {}, manualConfirmation: .constant(false))
    }
    check(panel(.draft).title == rawTitle && panel(.draft).content == rawBody, "exact caller text retained")
    check(panel(.draft).fixtureCanReview, "complete draft enables review affordance")
    check(!panel(.draft, account: nil).fixtureCanReview, "unsigned draft disables review affordance")
    check(!panel(.draft, destination: nil).fixtureCanReview, "unset destination disables review affordance")
    check(!panel(.draft, account: " \n ").fixtureCanReview, "blank account is not authenticated")
    check(!panel(.draft, destination: " \n ").fixtureCanReview, "blank destination is not configured")
    check(!panel(.draft, title: " \n ").fixtureCanReview, "blank title does not enable review")
    check(!panel(.draft, content: "\n  ").fixtureCanReview, "blank body does not enable review")
    check(!FeedbackPanel.Phase.reviewed.allowsEditing, "reviewed text is read-only in this view")
    check(!FeedbackPanel.Phase.submitting.allowsEditing, "submitting text is read-only in this view")
    check(!FeedbackPanel.Phase.unconfirmed.allowsEditing, "unknown delivery is not treated as a draft retry")
    check(FeedbackPanel.Phase.blocked("fixture").allowsEditing, "blocked draft permits manual correction")
    check(FeedbackPanel.Phase.failed("fixture").allowsEditing, "definite failure permits correction")
    let missingLogin = FeedbackStatusMessage(account: nil, destination: nil, phase: .draft)
    check(missingLogin.message == "請先登入github才能提交issue" && missingLogin.isError, "exact red sign-in message")
    check(FeedbackStatusMessage(account: "示意", destination: nil, phase: .draft).message.contains("不會送出"),
          "missing destination is visible")
    let completed = FeedbackStatusMessage(account: nil, destination: nil, phase: .submitted(42))
    check(completed.message == "已建立 Issue #42" && !completed.isError,
          "sign-out never disguises a completed submission as a new login failure")
    let uncertain = FeedbackStatusMessage(account: nil, destination: nil, phase: .unconfirmed)
    check(uncertain.message.contains("不重複送出") && uncertain.isError,
          "unknown submission keeps its actual delivery state")
    let busy = FeedbackStatusMessage(account: nil, destination: nil, phase: .submitting)
    check(busy.message.contains("正在提交"), "pending submission is not hidden by account refresh")
    check(panel(.draft, source: "來自 note 選定內容").content == rawBody, "note uses the same unmodified content presentation")
    for phase in [FeedbackPanel.Phase.blocked("風險原因"), .failed("服務不可用")] {
        let signedOut = FeedbackStatusMessage(account: nil, destination: "示意", phase: phase)
        check(signedOut.message.contains("未送出：") && signedOut.message.contains("請先登入github才能提交issue"),
              "editable failure preserves its reason and explains missing login")
        let unconfigured = FeedbackStatusMessage(account: "示意", destination: nil, phase: phase)
        check(unconfigured.message.contains("未送出：") && unconfigured.message.contains("倉庫尚未開放"),
              "editable failure preserves its reason and explains missing destination")
    }

    func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
        let content = VStack(spacing: 0) {
            Text("介面預覽・未連線、不會提交").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 8)
            view
        }.frame(width: width, height: height).background(Color(NSColor.windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap: \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
        window.close()
        check(host.bounds.width == width && host.bounds.height == height, "render \(name) \(Int(width))x\(Int(height))")
    }
    try render(panel(.draft), name: "chat-draft", width: 560, height: 570)
    try render(panel(.draft, destination: nil, source: "來自 note 選定內容"),
               name: "note-unconfigured", width: 380, height: 600)
    try render(panel(.checking), name: "checking", width: 380, height: 570)
    try render(panel(.blocked("疑似包含密鑰。請自行移除敏感內容，再重新檢查。")),
               name: "blocked", width: 380, height: 600)
    try render(panel(.blocked("疑似包含密鑰。請自行移除敏感內容，再重新檢查。"), account: nil),
               name: "blocked-signed-out", width: 380, height: 600)
    try render(panel(.reviewed), name: "reviewed", width: 380, height: 570)
    try render(panel(.submitting), name: "submitting", width: 380, height: 570)
    try render(panel(.failed("檢查服務暫時不可用")), name: "failed", width: 380, height: 600)
    try render(panel(.unconfirmed), name: "unconfirmed", width: 380, height: 570)
    try render(panel(.submitted(42)), name: "submitted", width: 560, height: 570)
    try render(VStack(spacing: 0) {
        Text("/feedback").frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
        missingLogin.padding(.horizontal, 12).padding(.vertical, 10)
            .background(.quaternary, in: FeedbackFixtureDrawerShape(sideSlope: 5, cornerRadius: 16))
            .padding(.horizontal, 10)
    }.padding(12), name: "chat-signin-drawer", width: 380, height: 160)
    print("FEEDBACKPRESENTATION RESULT checks=\(checks) failures=0")
}
try MainActor.assumeIsolated { try runFeedbackFixture() }
`;
  writeFileSync(path.join(root, 'fixture.swift'), swift);
  const lock = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquisition = run('/bin/bash', [lock, 'acquire', '--timeout', '120', '--pid', String(process.pid)], { timeout: 130_000 });
  assert.equal(acquisition.status, 0, acquisition.stderr);
  const token = acquisition.stdout.match(/^token=(.+)$/m)?.[1];
  assert.ok(token, 'owned build lock token required');
  let compiled;
  try {
    compiled = run('/usr/bin/time', ['-l', '/usr/bin/nice', '-n', '10', '/usr/bin/xcrun', 'swiftc',
      '-swift-version', '5', path.join(root, 'fixture.swift'), '-o', path.join(root, 'fixture')], {
      env: { ...process.env, TMPDIR: root },
    });
    writeFileSync(path.join(root, 'compiler.log'), compiled.stdout + compiled.stderr);
  } finally {
    const released = run('/bin/bash', [lock, 'release', '--token', token, '--pid', String(process.pid)]);
    assert.equal(released.status, 0, released.stderr);
  }
  assert.equal(compiled.status, 0, compiled.stderr);
  const result = run(path.join(root, 'fixture'), [root], {
    env: { HOME: root, TMPDIR: root, PATH: '/usr/bin:/bin' },
    timeout: 30_000,
  });
  writeFileSync(path.join(root, 'runtime.log'), result.stdout + result.stderr);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /FEEDBACKPRESENTATION RESULT checks=34 failures=0/);
  const names = ['chat-draft', 'note-unconfigured', 'checking', 'blocked', 'reviewed',
    'submitting', 'failed', 'unconfirmed', 'submitted', 'chat-signin-drawer', 'blocked-signed-out'];
  writeFileSync(path.join(root, 'receipt.json'), JSON.stringify({
    at: new Date().toISOString(), sourceSHA256: hash(source), fixtureSHA256: hash(swift),
    pngSHA256: Object.fromEntries(names.map(name => [name, hash(readFileSync(path.join(root, name + '.png')))])),
    scope: 'Production presentation and state labels; synthetic bindings/actions and isolated hosting windows. Drawer geometry extracted from existing composer; backdrop is a fixture. No live command, authentication, security review, GitHub call or formal UI acceptance.',
  }, null, 2));
  console.log(result.stdout);
  console.log('Evidence:', root);
});
