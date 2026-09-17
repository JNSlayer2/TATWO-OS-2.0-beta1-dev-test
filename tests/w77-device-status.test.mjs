import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const app = fileURLToPath(new URL('../App/Sources/Tatwo2/', import.meta.url));
const source = name => readFileSync(join(app, name), 'utf8');
let binary;
function probe() {
  if (binary) return binary;
  const root = testScratch('w77-compiled-');
  const presentation = source('Pages/DevicesComposition.swift').split('// MARK: - W77 read-only consistency panel')[1];
  assert.ok(presentation);
  writeFileSync(join(root, 'Presentation.swift'), 'import Foundation\nimport Combine\n' + presentation);
  // Only resource locations are fixture adapters; reader, policy, diff and transport are production Swift.
  writeFileSync(join(root, 'Resources.swift'), `import Foundation
    enum OSUpstream { static let overridePath = "/fixture-missing" }
    enum OSUpstreamRefresh { static let bundledURL: URL? = nil }
  `);
  writeFileSync(join(root, 'Checks.swift'), String.raw`
import Foundation

@main struct Checks {
    static func check(_ ok: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !ok() { throw NSError(domain: label, code: 1) }
        print("PASS \(label)")
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let fm = FileManager.default
        let entry = TatwoEntry(environment: ["TATWO_OS_ROOT": root.path], preference: nil)
        let runtime = root.appendingPathComponent("runtime.md"), bundle = root.appendingPathComponent("bundled.md")
        let primaryID = "11111111-1111-4111-8111-111111111111"
        let secondaryID = "22222222-2222-4222-8222-222222222222"
        let now = Date()
        func read(_ commit: String? = nil) -> DeviceStatusSnapshot {
            DeviceStatusReader.read(entry: entry, runtimeURL: runtime, bundledURL: bundle,
                appInfo: ["CFBundleShortVersionString": "2.0.8", "CFBundleVersion": "3"], primaryCommit: commit)
        }
        func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
        let hardware = try DeviceIdentityStore.hardwareModel()
        let identity = DeviceIdentity(deviceID: primaryID, name: "Fixture real identity", hardwareModel: hardware,
            role: .primary, epoch: 1, primaryDeviceID: primaryID, updatedAt: Date(timeIntervalSince1970: 1_789_603_200))
        try identity.encoded().write(to: entry.deviceJSON)
        try write("constitution\n", entry.constitution)
        try write("skillet\n", entry.skillet)
        try write("runtime\n", runtime); try write("runtime\n", bundle)
        if mode == "reader" {
            let document = root.appendingPathComponent("document.json")
            try write("synthetic live document", document)
            let before = DeviceStatusReader.digest(try Data(contentsOf: document))
            let status = read()
            try check(status.identity.value == identity, "real name model role epoch")
            try check(status.appVersion.value == "2.0.8 (3)", "Info.plist version and build")
            try check(status.rules.value?.state == "aligned", "W68 aligned")
            try check(status.rules.value?.generatedFromConstitutionHash == nil, "no invented provenance")
            try check(status.gbrain.reason == "not_configured", "GBrain is not simulated healthy")
            try check(status.constitution.value?.sha256 == DeviceStatusReader.digest(Data("constitution\n".utf8)), "exact SHA256")
            try check(before == DeviceStatusReader.digest(try Data(contentsOf: document)), "read does not save document")
            try write("custom runtime\n", runtime)
            var changed = read()
            try check(changed.rules.value?.state == "pending", "W68 pending")
            let decision = changed.rules.value!.runtime.value!.sha256 + "\n" + changed.rules.value!.bundledHash! + "\n"
            try write(decision, root.appendingPathComponent("os-upstream.kept-custom.sha256"))
            changed = read()
            try check(changed.rules.value?.state == "user_kept", "W68 exact pair retained")
            try write("new bundle\n", bundle)
            try check(read().rules.value?.state == "pending", "old choice does not cover new bundle")
            let missing = DeviceStatusReader.file(root.appendingPathComponent("absent"))
            try check(missing.reason == "missing" && missing.value == nil, "missing is not fallback")
            let broken = root.appendingPathComponent("broken")
            try fm.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("absent"))
            try check(DeviceStatusReader.file(broken).reason == "broken_link", "broken symlink")
            try check(try DeviceStatusSnapshot.decode(status.jsonObject()).identity.value == identity, "RPC round trip")
        } else if mode == "policy" {
            for column in DeviceStatusColumn.allCases {
                for (expected, known, online, age, match, reason) in [
                    (DeviceStatusLight.green, true, true, 0.0, Optional(true), Optional<String>.none),
                    (.yellow, true, true, 0, nil, nil),
                    (.gray, false, true, 0, nil, nil),
                    (.gray, true, true, -61, true, nil),
                    (.gray, true, true, 10, true, nil),
                    (.yellow, true, true, 0, true, "unknown_source"),
                    (.red, true, true, 0, true, "missing"),
                    (.red, false, true, 0, nil, "broken_link")
                ] {
                    try check(DeviceStatusPolicy.light(column: column, known: known, online: online,
                        acquiredAt: now.addingTimeInterval(age), now: now, matches: match, reason: reason) == expected,
                        "\(column.rawValue) \(expected.rawValue) \(reason ?? "freshness/equality")")
                }
                try check(DeviceStatusPolicy.light(column: column, known: true, online: false,
                    acquiredAt: now, now: now, matches: true) != .green, "offline \(column.rawValue) not green")
            }
            try check(DeviceStatusPolicy.light(column: .rules, known: true, online: true,
                acquiredAt: now, now: now, matches: true, userKept: true) == .yellow, "user kept must be yellow")
            var status = read()
            var row = DeviceConsistencyRow(id: "local", addressLabel: "local", local: true,
                probe: .init(connection: .local, snapshot: status, acquiredAt: now, reason: nil))
            func cell(_ column: DeviceStatusColumn, _ reference: DeviceStatusSnapshot? = nil) -> DeviceConsistencyCell {
                DeviceConsistencyPresentation.cell(column: column, row: row, primary: reference ?? status,
                    now: now, targetAppVersion: "2.0.8 (3)")
            }
            try check(cell(.app).light == .green, "approved app exact version green")
            try check(cell(.constitution).light == .green, "both constitution hashes equal green")
            try check(cell(.rules).light != .green, "W68 missing provenance not green")
            let currentConstitutionHash = status.constitution.value?.sha256
            status.rules.value?.generatedFromConstitutionHash = currentConstitutionHash
            status.rules.reason = nil
            row.probe.snapshot = status
            try check(cell(.rules).light == .green, "rules green only with current provenance")
            status.rules.value?.state = "user_kept"; row.probe.snapshot = status
            try check(cell(.rules).light == .yellow, "presentation user-kept yellow")
            status.constitution.value = nil; status.constitution.reason = "missing"; row.probe.snapshot = status
            try check(cell(.constitution).light == .red, "presentation missing constitution red")
            row.probe.connection = .appUnavailable
            for column in DeviceStatusColumn.allCases {
                try check(cell(column).light != .green, "presentation offline blocks \(column.rawValue)")
            }
            row.probe.connection = .reachable
            row.probe.acquiredAt = now.addingTimeInterval(-61)
            try check(cell(.connection).light == .gray, "stale connection is unknown, not proven offline")
            let primary = read()
            var secondary = primary
            secondary.identity.value = DeviceIdentity(deviceID: secondaryID, name: "Secondary Fixture", hardwareModel: "FixtureModel1,1",
                role: .secondary, epoch: 1, primaryDeviceID: primaryID, updatedAt: now)
            let probes = [primary, secondary].map { DeviceStatusProbe(connection: .reachable, snapshot: $0, acquiredAt: now, reason: nil) }
            try check(DeviceStatusPolicy.primary(local: secondary, probes: probes, now: now)?.identity.value?.deviceID == primaryID,
                "RPC identity selects primary without registry IDs")
            try check(DeviceStatusPolicy.primary(local: secondary, probes: probes + [probes[0]], now: now) == nil,
                "ambiguous primary fails closed")
            try check(DeviceStatusPolicy.primary(local: secondary, probes: probes, now: now.addingTimeInterval(61)) == nil,
                "stale primary fails closed")
            secondary.identity.acquiredAt = now.addingTimeInterval(-61)
            try check(DeviceStatusPolicy.primary(local: secondary, probes: probes, now: now) == nil,
                "stale local authority anchor fails closed")
        } else if mode == "code" {
            try fm.createDirectory(at: entry.repoRoot, withIntermediateDirectories: true)
            func git(_ args: [String]) throws -> String {
                guard let result = DeviceStatusReader.git(entry.repoRoot,
                    ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + args)
                else { throw NSError(domain: "git fixture", code: 1) }
                return result
            }
            _ = try git(["init", "-b", "beta1/integration"])
            _ = try git(["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "base"])
            let base = read().code.value!.integrationCommit
            _ = try git(["checkout", "-b", "work"])
            _ = try git(["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "work"])
            let work = read().code.value!
            try check(work.integrationCommit == base && work.branchAhead == 1 && work.clean == true, "work branch ahead not integration drift")
            var status = read()
            func codeCell(_ snapshot: DeviceStatusSnapshot) -> DeviceConsistencyCell {
                let row = DeviceConsistencyRow(id: "local", addressLabel: "local", local: true,
                    probe: .init(connection: .local, snapshot: snapshot, acquiredAt: Date(), reason: nil))
                return DeviceConsistencyPresentation.cell(column: .code, row: row, primary: snapshot, now: Date())
            }
            try check(codeCell(status).light == .green, "clean working branch ahead allowed")
            status.code.value?.branchBehind = 1
            try check(codeCell(status).light == .yellow, "working branch behind not green")
            status.code.value?.branchBehind = nil
            try check(codeCell(status).light != .green, "unknown working branch distance not green")
            _ = try git(["branch", "-f", "beta1/integration", "HEAD"])
            let next = read(base).code.value!
            try check(next.ahead == 1 && next.behind == 0, "integration primary distance")
            try write("dirty", entry.repoRoot.appendingPathComponent("dirty"))
            try check(read().code.value?.clean == false, "dirty worktree reported")
            try check(read(String(repeating: "a", count: 40)).code.value?.behind == nil, "missing object distance unknown not zero")
            try check(!DeviceStatusReader.validCommit("--upload-pack=evil"), "reject git option injection")
        } else if mode == "diff" {
            let diff = DeviceStatusDiff.text(local: "same\nlocal\n", primary: "same\nprimary\n")
            try check(diff.contains("- 2: primary") && diff.contains("+ 2: local"), "line diff direction")
            try check(DeviceStatusDiff.text(local: "same", primary: "same") == "內容相同", "equal text")
            try check(DeviceStatusDiff.text(local: nil, primary: "text").contains("缺失"), "missing text not empty diff")
        } else if mode == "offline" {
            let record = DeviceRecord(id: secondaryID, name: "synthetic", host: "127.0.0.1", user: "fixture", sshPort: 1,
                publicKeyFingerprint: "", addedAt: now, lastSeenAt: now, workdirMap: [:])
            let result = RemoteHostLink(environment: [:]).queryDeviceStatus(device: record)
            try check(result.connection == .sshUnavailable && result.snapshot == nil, "real SSH unavailable classification")
        }
        print("W77 PASS \(mode)")
    }
}
`);
  binary = join(root, 'checks');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    ...['TatwoEntry', 'DeviceIdentity', 'DeviceRegistry', 'DeviceStatus', 'RemoteHostLink'].map(n => join(app, 'Facade', n + '.swift')),
    join(root, 'Resources.swift'), join(root, 'Presentation.swift'), join(root, 'Checks.swift'), '-o', binary],
    { encoding: 'utf8', timeout: 180_000 });
  return binary;
}

for (const mode of ['reader', 'policy', 'code', 'diff', 'offline']) {
  test(`W77 production Swift: ${mode}`, () => {
    const root = testScratch(`w77-${mode}-`);
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('TATWO') && !key.startsWith('GIT_')));
    const output = execFileSync(probe(), [root, mode], { encoding: 'utf8', env, timeout: 90_000 });
    assert.match(output, new RegExp(`W77 PASS ${mode}`));
  });
}

test('W77 bridge and UI wiring never mount the writing/placeholder path', () => {
  const bridge = source('Facade/OSAgentBridge.swift').split('case "device_status":')[1].split('case "bot_list"')[0];
  assert.match(bridge, /DeviceStatusReader.read/);
  assert.doesNotMatch(bridge.replace(/\/\/[^\n]*/g, ''), /save\(|get_document|\.live/);
  const remote = source('Facade/RemoteHostLink.swift');
  const query = remote.split('func queryDeviceStatus')[1].split('func connect')[0];
  assert.match(query, /callLocked\(method: "device_status"/);
  assert.doesNotMatch(query, /"get_document"|scheduleReconnectLocked\(/);
  assert.match(remote, /guard !statusProbeOnly else \{ return \}/);
  assert.match(remote, /"StrictHostKeyChecking=yes"/);
  assert.match(source('Pages/DevicesPage.swift'), /DeviceConsistencyPanel\(\)/);
  assert.doesNotMatch(source('Pages/DevicesPage.swift'), /DevicePressureMonitorCard\(|IPadUseSettingsView\(|DeviceSyncOutboxStore\(/);
  const view = source('Pages/DeviceSyncLeafViews.swift').split('struct DeviceConsistencyPanel:')[1];
  assert.doesNotMatch(view, /enqueue\(|Toggle\(|轉移主權|Button\("更新"/);
  assert.match(source('SelfTest.swift'), /bridge.callForSelfTest\(method: "device_status"/);
});
