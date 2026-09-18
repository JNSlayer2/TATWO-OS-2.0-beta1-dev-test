import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

const app = resolve('App/Sources/Tatwo2');
const source = name => readFileSync(join(app, name), 'utf8');

const driverPrelude = String.raw`
import Darwin
import Foundation

func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { throw NSError(domain: "FAIL " + label, code: 1) }
    print("PASS " + label)
}

func rejects(_ label: String, _ action: () throws -> Void) throws {
    do { try action() } catch { print("PASS " + label); return }
    throw NSError(domain: "accepted " + label, code: 1)
}
`;

test('W91b compiled registry: legacy split by direction, pins stay separate, fills never relax', { timeout: 180_000 }, () => {
  const root = testScratch('w91b-registry-');
  // Same-file extension only exposes the private pin step; no alternate implementation.
  writeFileSync(join(root, 'Remote.swift'), source('Facade/RemoteHostLink.swift') + String.raw`
extension RemoteHostLink {
    func fixturePin(_ device: DeviceRecord) throws { try prepareHostPin(device) }
}
`);
  writeFileSync(join(root, 'Checks.swift'), driverPrelude + String.raw`
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
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let authorized = root.appendingPathComponent("authorized_keys")
        let known = root.appendingPathComponent("known_hosts")
        // 全部是合成公鑰位元組，沒有私鑰、也沒有任何真實設備的指紋。
        func key(_ seed: UInt8) -> String {
            "ssh-ed25519 " + Data(repeating: seed, count: 32).base64EncodedString()
        }
        let clientKey = key(7), hostKey = key(9), strayKey = key(11)
        let clientFP = try DeviceRegistry.fingerprint(publicKey: clientKey)
        let hostFP = try DeviceRegistry.fingerprint(publicKey: hostKey)
        let strayFP = try DeviceRegistry.fingerprint(publicKey: strayKey)
        let generated = "11111111-1111-4111-8111-111111111111"
        let joined = "22222222-2222-4222-8222-222222222222"
        let unknown = "33333333-3333-4333-8333-333333333333"
        try Data((clientKey + " tatwo2-device:" + generated + "\n").utf8).write(to: authorized)
        try Data(("[192.0.2.10]:22 " + hostKey + "\n").utf8).write(to: known)
        func row(_ id: String, _ fingerprint: String) -> String {
            return "{\"id\":\"" + id + "\",\"name\":\"Fixture\",\"host\":\"192.0.2.10\","
                + "\"sshPort\":22,\"user\":\"fixture\",\"publicKeyFingerprint\":\"" + fingerprint + "\","
                + "\"addedAt\":\"2026-01-01T00:00:00Z\",\"lastSeenAt\":\"2026-01-01T00:00:00Z\","
                + "\"workdirMap\":{}}"
        }
        let legacy = "[" + [row(generated, clientFP), row(joined, hostFP), row(unknown, strayFP)]
            .joined(separator: ",") + "]"
        let registry = DeviceRegistry(root: root, authorizedKeysURL: authorized,
                                      knownHostsURL: known, environment: [:])
        try Data(legacy.utf8).write(to: registry.url)
        func find(_ id: String) throws -> DeviceRecord {
            guard let value = registry.list().first(where: { $0.id == id }) else {
                throw NSError(domain: "missing " + id, code: 1)
            }
            return value
        }
        // 方向一：自己是產生配對碼端 —— authorized_keys 掛著這台 ID，舊值是對方的客戶端金鑰。
        var host = try find(generated)
        try check(host.clientKeyFingerprint == clientFP && host.hostKeyFingerprint == nil
            && host.clientKeyFingerprintSource?.source == "legacy_authorized_keys"
            && !host.needsFingerprintRepair, "generator-side-legacy-becomes-client-key")
        try check(host.pinnedHostKeyFingerprint == nil && host.pinnedClientKeyFingerprint == clientFP,
                  "generator-side-has-no-host-pin")
        // 方向二：自己是加入端 —— known_hosts 有這把，舊值是對方的主機金鑰。
        var join = try find(joined)
        try check(join.hostKeyFingerprint == hostFP && join.clientKeyFingerprint == nil
            && join.hostKeyFingerprintSource?.source == "legacy_known_hosts"
            && !join.needsFingerprintRepair, "joiner-side-legacy-becomes-host-key")
        try check(join.pinnedClientKeyFingerprint == nil && join.pinnedHostKeyFingerprint == hostFP,
                  "joiner-side-has-no-client-pin")
        // 推定不了：兩把皆空、標記待修；尚未分流的紀錄沿用舊欄，行為跟分流前一模一樣。
        let stray = try find(unknown)
        try check(stray.needsFingerprintRepair && stray.hostKeyFingerprint == nil
            && stray.clientKeyFingerprint == nil && stray.pinnedHostKeyFingerprint == strayFP
            && stray.pinnedClientKeyFingerprint == strayFP, "undecidable-marks-repair-and-keeps-legacy")
        try check(try String(contentsOf: registry.url, encoding: .utf8) == legacy,
                  "classification-does-not-write-on-read")

        let link = RemoteHostLink(environment: ["TATWO2_SSH_KNOWN_HOSTS": known.path,
                                                "TATWO2_LIVE_ROOT": root.path])
        try link.fixturePin(join)
        print("PASS joiner-side-host-key-pins-tunnel")
        try rejects("generator-side-refuses-tunnel") { try link.fixturePin(host) }
        // 就算那把客戶端金鑰後來也躺在 known_hosts 裡，分流過的紀錄照樣不准拿它 pin 隧道。
        _ = try registry.touch(id: generated)
        try Data(("[192.0.2.10]:22 " + hostKey + "\n[192.0.2.11]:22 " + clientKey + "\n").utf8)
            .write(to: known)
        host = try find(generated)
        try check(host.clientKeyFingerprint == clientFP && host.hostKeyFingerprint == nil,
                  "persisted-classification-not-reinterpreted")
        try rejects("client-key-in-known-hosts-still-refuses-tunnel") { try link.fixturePin(host) }

        // 補齊：只補空的那把，補完另一條路徑反而更嚴，不會因為補齊而放行。
        _ = try registry.recordFingerprint(id: unknown, role: .host, fingerprint: strayFP,
                                           source: "known_hosts", now: Date(timeIntervalSince1970: 1_800_000_000))
        let repaired = try find(unknown)
        try check(repaired.hostKeyFingerprint == strayFP && !repaired.needsFingerprintRepair
            && repaired.hostKeyFingerprintSource?.source == "known_hosts"
            && repaired.hostKeyFingerprintSource?.recordedAt == Date(timeIntervalSince1970: 1_800_000_000),
            "fill-records-source-and-time")
        try check(repaired.clientKeyFingerprint == nil && repaired.pinnedClientKeyFingerprint == nil,
                  "fill-host-does-not-grant-client")
        try rejects("fill-never-overwrites-a-pin") {
            _ = try registry.recordFingerprint(id: unknown, role: .host, fingerprint: clientFP,
                                               source: "known_hosts")
        }
        try rejects("fill-rejects-non-sha256") {
            _ = try registry.recordFingerprint(id: joined, role: .client, fingerprint: "trustme",
                                               source: "rpc_proof")
        }
        try rejects("fill-rejects-unknown-device") {
            _ = try registry.recordFingerprint(id: "44444444-4444-4444-8444-444444444444",
                                               role: .client, fingerprint: clientFP, source: "rpc_proof")
        }
        let before = try Data(contentsOf: registry.url)
        _ = try registry.recordFingerprint(id: unknown, role: .host, fingerprint: strayFP, source: "known_hosts")
        try check(try Data(contentsOf: registry.url) == before, "repeat-fill-is-a-no-op")
        _ = try registry.recordFingerprint(id: joined, role: .client, fingerprint: clientFP, source: "rpc_proof")
        join = try find(joined)
        try check(join.hostKeyFingerprint == hostFP && join.clientKeyFingerprint == clientFP
            && join.clientKeyFingerprintSource?.source == "rpc_proof", "fill-client-keeps-host-pin")

        // 自己的兩把公鑰指紋只讀 .pub。
        let ownHost = root.appendingPathComponent("own_host.pub")
        try Data((hostKey + " fixture\n").utf8).write(to: ownHost)
        try check(DeviceRegistry.localHostKeyFingerprint(
            environment: ["TATWO2_SSH_HOST_KEY_PUB": ownHost.path]) == hostFP, "local-host-key-fingerprint")
        try check(DeviceRegistry.localHostKeyFingerprint(
            environment: ["TATWO2_SSH_HOST_KEY_PUB": root.appendingPathComponent("absent").path]) == nil,
            "missing-host-key-file-reports-nothing")
        print("W91B PASS registry")
    }
}
`);
  const binary = join(root, 'checks');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    join(app, 'Facade/DeviceRegistry.swift'), join(root, 'Remote.swift'), join(root, 'Checks.swift'),
    '-o', binary], { encoding: 'utf8', timeout: 180_000 });
  const output = execFileSync(binary, [root], { encoding: 'utf8', timeout: 60_000 });
  assert.match(output, /W91B PASS registry/);
  console.log(output.trim());
});

test('W91b compiled pairing: both sides exchange both fingerprints over the existing channel', { timeout: 300_000 }, () => {
  const root = testScratch('w91b-pairing-');
  writeFileSync(join(root, 'Driver.swift'), driverPrelude + String.raw`
enum ChatCollaborationLevel { case off, s, m, l, xl, xxl }

func reply(_ payload: [String: Any], port: Int) throws -> String {
    let handle = socket(AF_INET, SOCK_STREAM, 0)
    guard handle >= 0 else { throw NSError(domain: "socket", code: 1) }
    defer { close(handle) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw NSError(domain: "connect", code: 1) }
    var line = try JSONSerialization.data(withJSONObject: payload)
    line.append(0x0A)
    _ = line.withUnsafeBytes { Darwin.send(handle, $0.baseAddress, line.count, 0) }
    var buffer = [UInt8](repeating: 0, count: 8192)
    let read = Darwin.recv(handle, &buffer, buffer.count, 0)
    return read > 0 ? String(decoding: buffer[0..<read], as: UTF8.self) : ""
}

@main struct Driver {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // 全部是這次測試現生的合成金鑰，放在 TMPDIR 下，不碰使用者的 ~/.ssh。
        func keygen(_ name: String) throws -> String {
            let path = try directory("keys").appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", path.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "keygen", code: 1) }
            return path.path
        }
        func fingerprint(_ path: String) throws -> String {
            try DeviceRegistry.fingerprint(
                publicKey: String(contentsOfFile: path + ".pub", encoding: .utf8))
        }
        let hostHostKey = try keygen("host-host"), hostClientKey = try keygen("host-client")
        let joinHostKey = try keygen("join-host"), joinClientKey = try keygen("join-client")
        let hostRoot = try directory("host-os"), joinRoot = try directory("join-os")
        let hostEntry = TatwoEntry(environment: ["TATWO_OS_ROOT": hostRoot.path], preference: nil)
        let hostID = "55555555-5555-4555-8555-555555555555"
        _ = try DeviceIdentityStore.forLocalDevice(entry: hostEntry, pairedDeviceID: hostID, name: "Fixture")
        let hostRegistry = DeviceRegistry(root: try directory("host-live"),
            authorizedKeysURL: root.appendingPathComponent("host-authorized"),
            knownHostsURL: root.appendingPathComponent("host-known"), environment: [:])
        let joinRegistry = DeviceRegistry(root: try directory("join-live"),
            authorizedKeysURL: root.appendingPathComponent("join-authorized"),
            knownHostsURL: root.appendingPathComponent("join-known"), environment: [:])
        let hostEnvironment = ["TATWO_OS_ROOT": hostRoot.path, "TATWO2_PAIRING_HOST": "127.0.0.1",
                               "TATWO2_SSH_HOST_KEY_PUB": hostHostKey + ".pub",
                               "TATWO2_SSH_KEY_PATH": hostClientKey]
        let joinEnvironment = ["TATWO_OS_ROOT": joinRoot.path,
                               "TATWO2_SSH_HOST_KEY_PUB": joinHostKey + ".pub"]
        let host = DevicePairingHost(registry: hostRegistry, environment: hostEnvironment)
        defer { host.cancelPairingWindow() }
        let scanned = try fingerprint(hostHostKey)
        let client = DevicePairingClient(registry: joinRegistry,
            privateKeyURL: URL(fileURLWithPath: joinClientKey), environment: joinEnvironment,
            sshVerifier: { _ in true }, hostFingerprintResolver: { _ in scanned })
        var window = try host.startPairingWindow()
        var port = Int(window.listenAddress.split(separator: ":").last!)!
        let peer = try client.pair(host: "127.0.0.1", port: port, code: window.code, name: "Sample")

        // 加入端：主機金鑰是自己掃到的那把（值不變），客戶端金鑰由配對通道拿到。
        try check(peer.hostKeyFingerprint == scanned && peer.publicKeyFingerprint == scanned
            && peer.hostKeyFingerprintSource?.source == "pairing", "joiner-pins-scanned-host-key")
        try check(peer.clientKeyFingerprint == (try fingerprint(hostClientKey))
            && peer.clientKeyFingerprintSource?.source == "pairing", "joiner-learns-peer-client-key")
        try check(peer.pinnedHostKeyFingerprint != nil && peer.pinnedClientKeyFingerprint != nil,
                  "joiner-row-complete")
        // 產生配對碼端：客戶端金鑰仍是它自己授權的那把，主機金鑰由配對通道拿到。
        let recorded = hostRegistry.list().first!
        try check(recorded.clientKeyFingerprint == (try fingerprint(joinClientKey))
            && recorded.publicKeyFingerprint == recorded.clientKeyFingerprint
            && recorded.clientKeyFingerprintSource?.source == "pairing", "generator-keeps-authorized-client-key")
        try check(recorded.hostKeyFingerprint == (try fingerprint(joinHostKey))
            && recorded.hostKeyFingerprintSource?.source == "pairing", "generator-learns-peer-host-key")
        try check(recorded.pinnedHostKeyFingerprint != nil && recorded.pinnedClientKeyFingerprint != nil,
                  "generator-row-complete")

        // 自報的客戶端指紋跟送來的公鑰對不起來就不配對、也不授權。
        window = try host.startPairingWindow()
        port = Int(window.listenAddress.split(separator: ":").last!)!
        let publicKey = try String(contentsOfFile: joinClientKey + ".pub", encoding: .utf8)
        let response = try reply(["code": window.code, "publicKey": publicKey, "name": "Demo",
            "user": "fixture", "clientKeyFingerprint": "SHA256:" + String(repeating: "A", count: 43)],
            port: port)
        try check(response.contains("device_fingerprint_conflict"), "declared-client-fingerprint-must-match")
        try check(hostRegistry.list().count == 1, "rejected-pairing-adds-no-row")
        let authorized = try String(contentsOf: hostRegistry.authorizedKeysURL, encoding: .utf8)
        try check(authorized.split(whereSeparator: \.isNewline).count == 1, "rejected-pairing-authorizes-nothing")
        print("W91B PASS pairing")
    }
}
`);
  const binary = join(root, 'driver');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    ...['TatwoEntry', 'DeviceIdentity', 'DeviceRegistry', 'DevicePairingCode', 'DevicePairingStubs',
      'DevicePairingHost', 'DevicePairingClient'].map(name => join(app, 'Facade', name + '.swift')),
    join(app, 'Chat/UltraworkRoleConfiguration.swift'), join(root, 'Driver.swift'),
    '-o', binary], { encoding: 'utf8', timeout: 240_000 });
  const env = Object.fromEntries(Object.entries(process.env)
    .filter(([key]) => !key.startsWith('TATWO') && !key.startsWith('GIT_')));
  const output = execFileSync(binary, [root], { encoding: 'utf8', env, timeout: 120_000 });
  assert.match(output, /W91B PASS pairing/);
  console.log(output.trim());
});

test('W91b wiring: each path reads only its own key, nothing loosens, no new pairing socket', () => {
  const registry = source('Facade/DeviceRegistry.swift');
  const remote = source('Facade/RemoteHostLink.swift');
  const dispatch = source('Facade/DeviceDispatch.swift');
  const pairingHost = source('Facade/DevicePairingHost.swift');
  const pairingClient = source('Facade/DevicePairingClient.swift');
  // 隧道只讀 host 那把，RPC 只讀 client 那把。
  assert.match(remote, /guard let pinned = device\.pinnedHostKeyFingerprint/);
  assert.doesNotMatch(remote, /device\.publicKeyFingerprint\.hasPrefix/);
  assert.match(dispatch, /let pinnedClientKey = peer\.pinnedClientKeyFingerprint/);
  assert.match(dispatch, /fingerprint\(publicKey: publicKey\) == pinnedClientKey/);
  // 補齊只在成功之後，而且不放寬既有把關。
  assert.match(remote, /recordFingerprint\(\s*\n?\s*id: device\.id, role: \.host, fingerprint: pinned, source: "known_hosts"\)/);
  assert.match(dispatch, /id: sender, role: \.client, fingerprint: verified, source: "rpc_proof"\)/);
  assert.match(registry, /guard existing == nil \|\| existing == fingerprint else \{ throw RegistryError\.fingerprintConflict \}/);
  // 沒有放寬信任的旋鈕，也沒讀私鑰。
  for (const file of [registry, remote, dispatch, pairingHost]) {
    assert.doesNotMatch(file, /StrictHostKeyChecking=(?:no|accept-new)/);
  }
  assert.match(registry, /TATWO2_SSH_HOST_KEY_PUB/);
  assert.doesNotMatch(registry, /ssh_host_ed25519_key(?!\.pub)/);
  // 配對沿用現有通道：沒有新的 listener。
  assert.equal(pairingHost.match(/NWListener\(/g).length, 1);
  assert.doesNotMatch(pairingClient, /NWListener/);
  assert.match(registry, /private func classifiedLegacyFingerprints/);
  // 設備頁兩處都看得到兩把指紋。
  for (const file of ['New/DevicesCard.swift', 'Pages/DeviceSyncLeafViews.swift']) {
    assert.match(source(file), /device\.fingerprintSummary/);
  }
  // 測試與程式碼只出現合成指紋。
  const own = readFileSync('tests/w91b-fingerprints.test.mjs', 'utf8');
  for (const file of [registry, remote, dispatch, pairingHost, pairingClient, own]) {
    assert.doesNotMatch(file, /SHA256:[A-Za-z0-9+/]{40,}/);
  }
});
