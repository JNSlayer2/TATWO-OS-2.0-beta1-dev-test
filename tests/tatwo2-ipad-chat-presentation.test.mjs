import { testScratch } from './helpers/test-scratch.mjs';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repo = fileURLToPath(new URL('../', import.meta.url));
const source = readFileSync(path.join(repo, 'App/Sources/Tatwo2/New/IPadChatConnectionPanel.swift'), 'utf8');
const hash = value => createHash('sha256').update(value).digest('hex');

test('iPad chat panel is presentation only, without discovery or authorization side effects', () => {
  assert.doesNotMatch(source, /IPadUseController|URLSession|Process\(|FileManager|UserDefaults|\.task\s*[{(]|\.onAppear/);
  assert.match(source, /@Binding var selectedDeviceID/);
  assert.match(source, /onExitCommand\(perform: close\)/);
  assert.doesNotMatch(source, /Procreate|Timer|Task\s*[{(]/);
});

test('native iPad chat presentation and thread-bound consent callbacks', {
  skip: process.platform !== 'darwin' ? 'Requires native macOS SwiftUI' : false,
}, () => {
  const output = testScratch('tatwo2-ipad-chat-presentation-');
  mkdirSync(output, { recursive: true });
  const root = mkdtempSync(path.join(output, 'ipad-chat-presentation.'));
  const run = (cmd, args, options = {}) => spawnSync(cmd, args, {
    cwd: repo, encoding: 'utf8', timeout: 60_000, maxBuffer: 1024 * 1024, ...options,
  });
  const pressure = run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']);
  assert.equal(pressure.status, 0);
  assert.equal(pressure.stdout.trim(), '1', 'No compiler under resource pressure');
  const swift = source + '\nimport AppKit\n' + String.raw`
@MainActor func fixture() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    typealias Panel = IPadChatConnectionPanel
    let device = Panel.Device(id: "synthetic-ipad", name: "工作 iPad")
    let owner = UUID()
    let other = UUID()
    var checks = 0
    var requests: [(String, UUID)] = []
    var confirms: [(String, UUID)] = []
    func check(_ value: Bool, _ name: String) {
        guard value else { fatalError("FAIL: \(name)") }
        checks += 1; print("PASS: \(name)")
    }
    func panel(_ phase: Panel.Phase, devices: [Panel.Device]? = nil,
               selected: String? = "synthetic-ipad", thread: UUID? = nil,
               noThread: Bool = false) -> Panel {
        Panel(devices: devices ?? [device], selectedDeviceID: .constant(selected),
              threadID: noThread ? nil : (thread ?? owner), activeDeviceName: device.name,
              phase: phase, close: {}, refresh: {}, openSettings: {},
              requestConsent: { requests.append(($0, $1)) },
              confirmConsent: { confirms.append(($0, $1)) }, cancelConsent: {}, stop: {})
    }
    check(panel(.choose).fixtureCanRequest, "prepared device and current thread can request consent")
    check(!panel(.choose, devices: []).fixtureCanRequest, "missing device cannot request")
    check(!panel(.choose, selected: "stale").fixtureCanRequest, "stale selection cannot request")
    check(!panel(.choose, noThread: true).fixtureCanRequest, "missing thread cannot request")
    for phase in [Panel.Phase.connecting, .authorizedHere, .ownedElsewhere, .stopping, .stopUnconfirmed] {
        check(!panel(phase).fixtureCanRequest, "active or uncertain state cannot reconnect")
    }
    panel(.choose).fixtureRequest()
    check(requests.count == 1 && requests[0].0 == device.id && requests[0].1 == owner,
          "request callback carries selected device and owner")
    panel(.choose, noThread: true).fixtureRequest()
    check(requests.count == 1, "invalid request callback guarded")
    let consent = Panel.Phase.consent(device: device, threadID: owner)
    check(panel(consent).fixtureCanConfirm, "unchanged consent can be confirmed")
    check(!panel(consent, thread: other).fixtureCanConfirm, "switching thread invalidates consent")
    check(!panel(consent, devices: []).fixtureCanConfirm, "removed device invalidates consent")
    check(!panel(consent, noThread: true).fixtureCanConfirm, "lost thread invalidates consent")
    panel(consent).fixtureConfirm()
    panel(consent, thread: other).fixtureConfirm()
    check(confirms.count == 1 && confirms[0].0 == device.id && confirms[0].1 == owner,
          "only matching immutable consent reaches callback")
    check(panel(.ownedElsewhere).fixtureStatus.contains("未獲授權"), "other thread is not shown as authorized here")
    check(panel(.ownedElsewhere).fixtureStopTitle == "停止其他討論串的連線", "stop button makes other-thread scope explicit")
    check(panel(.stopUnconfirmed).fixtureStatus.contains("尚未確認"), "unknown stop is not displayed as success")
    check(Panel.Phase.connecting.isBusy && Panel.Phase.stopping.isBusy, "work phases expose progress")
    check(!Panel.Phase.stopUnconfirmed.isBusy, "unknown stop permits explicit retry rather than fake progress")

    let previews: [(String, Panel)] = [
        ("選設備", panel(.choose)),
        ("首次設定", panel(.choose, devices: [])),
        ("一次授權", panel(consent)),
        ("連線中", panel(.connecting)),
        ("可使用", panel(.authorizedHere)),
        ("其他討論串", panel(.ownedElsewhere)),
        ("停止中", panel(.stopping)),
        ("停止未確認", panel(.stopUnconfirmed)),
        ("連線失敗", panel(.failed("無法連線，請確認 USB 連接與 iPad 已解鎖。")))
    ]
    let sheet = VStack(spacing: 10) {
        Text("iPad 聊天連線・介面預覽，未接真機").font(.headline)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(340)), count: 3), spacing: 10) {
            ForEach(previews.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 0) {
                    Text(previews[index].0).font(.caption).foregroundStyle(.secondary).padding(8)
                    previews[index].1
                    Spacer(minLength: 0)
                }.frame(width: 340, height: 310)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }.padding(16).frame(width: 1072, height: 1020).background(Color(NSColor.windowBackgroundColor))
    let host = NSHostingView(rootView: sheet)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1072, height: 1020),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host; window.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("states.png"))
    check(host.bounds.size == NSSize(width: 1072, height: 1020), "nine-state native render dimensions")
    window.close()
    print("IPADCHAT RESULT checks=\(checks) failures=0")
}
extension IPadChatConnectionPanel {
    var fixtureCanRequest: Bool { canRequestConsent }
    var fixtureCanConfirm: Bool { canConfirmConsent }
    var fixtureStatus: String { statusText }
    var fixtureStopTitle: String { stopButtonTitle }
    func fixtureRequest() { beginConsent() }
    func fixtureConfirm() { confirm() }
}
try MainActor.assumeIsolated { try fixture() }
`;
  writeFileSync(path.join(root, 'fixture.swift'), swift);
  const lock = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquisition = run('/bin/bash', [lock, 'acquire', '--timeout', '1', '--pid', String(process.pid)]);
  assert.equal(acquisition.status, 0, acquisition.stderr);
  const token = acquisition.stdout.match(/^token=(.+)$/m)?.[1];
  assert.ok(token);
  let compiled;
  try {
    compiled = run('/usr/bin/time', ['-l', '/usr/bin/nice', '-n', '10', '/usr/bin/xcrun', 'swiftc',
      '-swift-version', '5', path.join(root, 'fixture.swift'), '-o', path.join(root, 'fixture')], {
      env: { ...process.env, TMPDIR: root },
    });
    writeFileSync(path.join(root, 'compiler.log'), compiled.stdout + compiled.stderr);
  } finally {
    const release = run('/bin/bash', [lock, 'release', '--token', token, '--pid', String(process.pid)]);
    assert.equal(release.status, 0, release.stderr);
  }
  assert.equal(compiled.status, 0, compiled.stderr);
  const result = run(path.join(root, 'fixture'), [root], {
    env: { HOME: root, TMPDIR: root, PATH: '/usr/bin:/bin' }, timeout: 30_000,
  });
  writeFileSync(path.join(root, 'runtime.log'), result.stdout + result.stderr);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /IPADCHAT RESULT checks=22 failures=0/);
  writeFileSync(path.join(root, 'receipt.json'), JSON.stringify({
    at: new Date().toISOString(), runID: path.basename(root), surface: 'iPad chat connection presentation',
    viewport: [1072, 1020], sourceSHA256: hash(source), fixtureSHA256: hash(swift),
    pngSHA256: hash(readFileSync(path.join(root, 'states.png'))),
    scope: 'Synthetic devices, thread IDs and callbacks. No live composer/controller, discovery, USB, authorization or installation. Not formal UI acceptance.',
  }, null, 2));
  console.log(result.stdout);
  console.log('Evidence:', root);
});
