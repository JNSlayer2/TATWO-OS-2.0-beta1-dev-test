import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

const app = resolve('App/Sources/Tatwo2');
const source = name => readFileSync(join(app, name), 'utf8');

test('W91 compiled production registry: upgrade, order, retirement, old-reader compatibility, strict alias pin', { timeout: 180_000 }, () => {
  const root = testScratch('w91-endpoints-');
  // Same-file extension exposes private argument construction, not an alternate implementation.
  writeFileSync(join(root, 'Remote.swift'), source('Facade/RemoteHostLink.swift') + String.raw`
extension RemoteHostLink {
    var fixtureEnvironment: [String: String] { sshEnvironment }
    func fixtureArguments(_ device: DeviceRecord, _ endpoint: DeviceEndpoint) throws -> [String] {
        activeEndpoint = endpoint
        try prepareHostPin(device)
        return try sshBaseArguments(device) + [sshDestination(device)]
    }
}
`);
  writeFileSync(join(root, 'Checks.swift'), String.raw`
import Foundation

enum DeviceRole: String, Codable, Sendable { case primary, secondary }
enum DeviceStatusReader {
    static func registry(environment: [String: String]) -> [DeviceRecord] { [] }
}
struct DeviceStatusSnapshot: Sendable {
    static func decode(_ value: [String: Any]) throws -> Self { Self() }
}
struct DeviceStatusProbe {
    enum Connection { case reachable, appUnavailable, sshUnavailable }
    var connection: Connection
    var snapshot: DeviceStatusSnapshot?
    var acquiredAt: Date
    var reason: String?
}
@main struct Checks {
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NSError(domain: label, code: 1) }
        print("PASS " + label)
    }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { print("PASS " + label); return }
        throw NSError(domain: "accepted " + label, code: 1)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let registry = DeviceRegistry(root: root, authorizedKeysURL: root.appendingPathComponent("authorized"), environment: [:])
        let legacy = #"[{"id":"fixture-peer","name":"Fixture","host":"192.0.2.10","sshPort":22,"user":"fixture","publicKeyFingerprint":"SHA256:synthetic","addedAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z","workdirMap":{}}]"#
        try Data(legacy.utf8).write(to: registry.url)
        var record = registry.list()[0]
        let lan = DeviceEndpoint(kind: .lan, host: "192.0.2.10")
        let alias = try DeviceEndpoint.parse("alias:fixture-peer")
        let tunnel = try DeviceEndpoint.parse("tunnel.example.invalid:2222", kind: .tunnel)
        try check(record.endpoints == [lan], "legacy-upgrade")
        try check(try String(contentsOf: registry.url) == legacy, "readonly-load-does-not-write")
        _ = try registry.updateEndpoint(id: record.id, endpoint: alias)
        record = try registry.updateEndpoint(id: record.id, endpoint: tunnel)
        try check(record.orderedEndpoints == [lan, tunnel, alias], "lan-tunnel-alias-order")
        let now = Date(timeIntervalSince1970: 1800000000)
        record = try registry.touch(id: record.id, at: now, endpoint: alias)
        try check(record.lastSeenAt == now && record.lastEndpoint == alias, "success-stamp")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: registry.url)) as! [[String: Any]]
        try check(raw[0]["host"] as? String == lan.host && raw[0]["sshPort"] as? Int == 22, "legacy-address-retained")
        // Compile the exact pre-W91 record declaration alongside the new implementation.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode([LegacyDeviceRecord].self, from: Data(contentsOf: registry.url))
        try check(old[0].host == lan.host && old[0].id == record.id, "v208-reader-compatible")
        record = try registry.updateEndpoint(id: record.id, endpoint: alias, retire: true)
        try check(record.retiredEndpoints == [alias] && record.lastEndpoint == nil, "retired-not-deleted")
        _ = try registry.updateEndpoint(id: record.id, endpoint: lan, retire: true)
        record = try registry.updateEndpoint(id: record.id, endpoint: tunnel, retire: true)
        try check(registry.list()[0].orderedEndpoints.isEmpty && record.retiredEndpoints.count == 3, "empty-active-does-not-resurrect-legacy")
        try rejects("retired-not-silently-reenabled") { _ = try registry.updateEndpoint(id: record.id, endpoint: alias) }
        for invalid in ["alias:-oops", "alias:x y", "host:0", "host:65536", "-oProxyCommand=x", "host:bad"] {
            try rejects("invalid-" + invalid) { _ = try DeviceEndpoint.parse(invalid) }
        }
        try check(try DeviceEndpoint.parse("[2001:db8::1]:2222").port == 2222, "ipv6-input")
        let minimal = try JSONDecoder().decode(DeviceEndpoint.self, from: Data(#"{"kind":"alias","alias":"fixture-peer"}"#.utf8))
        try check(minimal == alias, "alias-optional-host-port")
        let known = root.appendingPathComponent("known_hosts")
        let key = "ssh-ed25519 " + Data(repeating: 1, count: 32).base64EncodedString()
        try Data(("old.example.invalid " + key + "\n").utf8).write(to: known)
        let environment = ["TATWO2_SSH_KNOWN_HOSTS": known.path, "TATWO2_LIVE_ROOT": root.path]
        let link = RemoteHostLink(environment: environment)
        try check(link.fixtureEnvironment["PATH"]?.contains("/opt/homebrew/bin") == true, "gui-proxy-helper-path")
        let custom = RemoteHostLink(environment: ["PATH": "/fixture/bin:/usr/bin"])
        try check(custom.fixtureEnvironment["PATH"]?.hasPrefix("/fixture/bin:/usr/bin:") == true, "caller-path-precedence")
        try rejects("alias-rejects-unpaired-host-key") { _ = try link.fixtureArguments(record, alias) }
        try rejects("lan-rejects-unpaired-host-key") { _ = try link.fixtureArguments(record, lan) }
        try rejects("tunnel-rejects-unpaired-host-key") { _ = try link.fixtureArguments(record, tunnel) }
        record.publicKeyFingerprint = try DeviceRegistry.fingerprint(publicKey: key)
        let args = try link.fixtureArguments(record, alias)
        try check(args.last == "fixture-peer" && !args.contains("-p"), "alias-config-destination-and-port")
        for option in ["StrictHostKeyChecking=yes", "HostKeyAlias=tatwo-paired-host", "GlobalKnownHostsFile=/dev/null",
                       "ControlPath=none", "KnownHostsCommand=none", "UpdateHostKeys=no", "ConnectTimeout=8"] {
            try check(args.contains(option), "pin-" + option)
        }
        // Let OpenSSH itself verify effective config precedence, including ProxyCommand.
        let config = root.appendingPathComponent("config")
        try Data("Host fixture-peer\n HostName tunnel.example.invalid\n Port 2222\n ProxyCommand /usr/bin/false\n StrictHostKeyChecking ask\n ControlPath /tmp/fixture-mux\n".utf8).write(to: config)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", config.path] + args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let effective = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try check(process.terminationStatus == 0 && effective.contains("hostname tunnel.example.invalid")
            && effective.contains("port 2222") && effective.contains("proxycommand /usr/bin/false")
            && effective.contains("hostkeyalias tatwo-paired-host") && effective.contains("stricthostkeychecking true")
            && !effective.contains("controlpath /tmp/fixture-mux"), "openssh-config-preserves-route-not-trust")
        let pinArgument = args.first { $0.hasPrefix("UserKnownHostsFile=") }!
        let pinPath = String(pinArgument.dropFirst("UserKnownHostsFile=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        try check(try String(contentsOfFile: pinPath) == "tatwo-paired-host " + key + "\n", "only-paired-key-in-pin-file")
    }
}
`);
  const oldRecord = execFileSync('git', ['show', 'e634005f:App/Sources/Tatwo2/Facade/DeviceRegistry.swift'], { encoding: 'utf8' });
  const declaration = oldRecord.slice(oldRecord.indexOf('struct DeviceRecord:'), oldRecord.indexOf('/// `live/devices.json`'));
  writeFileSync(join(root, 'Legacy.swift'), 'import Foundation\n' + declaration.replace('struct DeviceRecord:', 'struct LegacyDeviceRecord:'));
  const binary = join(root, 'checks');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    join(app, 'Facade/DeviceRegistry.swift'), join(root, 'Remote.swift'), join(root, 'Legacy.swift'),
    join(root, 'Checks.swift'), '-o', binary], { encoding: 'utf8', timeout: 120_000 });
  const output = execFileSync(binary, [root], { encoding: 'utf8', timeout: 30_000 });
  assert.match(output, /PASS openssh-config-preserves-route-not-trust/);
  console.log(output.trim());
});

test('W91 endpoint budget and UI use shared production paths; live script stays read-only', () => {
  const remote = source('Facade/RemoteHostLink.swift');
  assert.match(remote, /for endpoint in routes.orderedEndpoints/);
  assert.match(remote, /endpointDeadline = Date\(\).addingTimeInterval\(8\)/);
  assert.match(remote, /while process.isRunning && Date\(\) < deadline/);
  assert.match(remote, /try prepareHostPin\(device\)/);
  assert.match(remote, /touch\(id: device.id, endpoint: endpoint\)/);
  assert.doesNotMatch(remote, /StrictHostKeyChecking=(?:no|accept-new)/);
  for (const file of ['New/DevicesCard.swift', 'Pages/DeviceSyncLeafViews.swift']) {
    assert.match(source(file), /DeviceEndpointsRow\(device: device/);
  }
  const script = readFileSync('scripts/w91-live-check.sh', 'utf8');
  assert.deepEqual([...script.matchAll(/rpc\('([^']+)'\)/g)].map(m => m[1]), ['device_status', 'list_devices']);
  assert.doesNotMatch(script, /write_text|write_bytes|dispatch_wake|rpc\('dispatch_fetch'/);
});
