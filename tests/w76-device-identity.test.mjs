import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const app = fileURLToPath(new URL('../App/Sources/Tatwo2/', import.meta.url));
const source = file => readFileSync(join(app, file), 'utf8');
let binary;

// Compile production Swift (including the real NWConnection pairing path), not a JS model.
// The UI-independent reader declarations are extracted unchanged from their existing UI stubs.
function probe() {
  if (binary) return binary;
  const root = testScratch('w76-compiled-');
  const outputBinary = join(root, 'checks');
  const stubs = source('Facade/DevicesStubs.swift');
  const reader = stubs.slice(stubs.indexOf('struct TatwoFlexPrimaryState:'),
    stubs.indexOf('enum TatwoHostMemoryPressureLevelV1:'));
  assert.ok(reader.includes('enum TatwoFlexPrimaryReader'));
  writeFileSync(join(root, 'Reader.swift'), 'import Foundation\n' + reader);
  const driver = join(root, 'Checks.swift');
  writeFileSync(driver, String.raw`
import Darwin
import Foundation

enum ChatCollaborationLevel { case off, s, m, l, xl, xxl }

@main struct Checks {
    static let a = "11111111-1111-4111-8111-111111111111"
    static let b = "22222222-2222-4222-8222-222222222222"
    static let c = "33333333-3333-4333-8333-333333333333"
    static let date = Date(timeIntervalSince1970: 1_789_603_200)
    static let key = "ssh-ed25519 " + Data(repeating: 1, count: 32).base64EncodedString()
    static let otherKey = "ssh-ed25519 " + Data(repeating: 2, count: 32).base64EncodedString()
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NSError(domain: label, code: 1) }
        print("PASS \(label)")
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { print("PASS \(label)"); return }
        throw NSError(domain: "unexpected acceptance: " + label, code: 1)
    }
    static func entry(_ root: URL, _ name: String) -> TatwoEntry {
        TatwoEntry(environment: ["TATWO_OS_ROOT": root.appendingPathComponent(name).path], preference: nil)
    }
    static func registry(_ root: URL, _ name: String) -> DeviceRegistry {
        DeviceRegistry(root: root.appendingPathComponent(name),
                       authorizedKeysURL: root.appendingPathComponent(name + "-keys"), environment: [:])
    }
    static func migration(_ epoch: Int = 1) throws -> [String: DeviceIdentity] {
        try DeviceIdentityMigration.preview(
            primaryJSON: Data("{\"name\":\"legacy-primary\",\"epoch\":\(epoch)}".utf8),
            deviceIDsByLegacyName: ["legacy-primary": a, "legacy-secondary": b],
            detailsByLegacyName: [
                "legacy-primary": .init(name: "Mini fixture", hardwareModel: "fixture-mini-hardware"),
                "legacy-secondary": .init(name: "Book fixture", hardwareModel: "fixture-book-hardware")],
            updatedAt: date)
    }
    static func main() {
        do {
            try run()
            print("W76 PASS \(CommandLine.arguments[1])")
        } catch {
            print("W76 FAIL \(error)")
            exit(1)
        }
    }
    static func run() throws {
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        // All mutable state is caller-provided synthetic TMPDIR data.
        let scratchComponents = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            .resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard rootComponents.starts(with: scratchComponents), rootComponents.count > scratchComponents.count
        else { throw NSError(domain: "unsafe fixture root", code: 1) }
        let ea = entry(root, "A"), eb = entry(root, "B")
        switch mode {
        case "format":
            let store = try DeviceIdentityStore.forLocalDevice(entry: ea, pairedDeviceID: a, name: "A", now: date)
            let identity = try store.read()
            try check(identity.deviceID == a, "adopts paired UUID")
            try check(identity.role == .secondary && identity.epoch == nil && identity.primaryDeviceID == nil,
                      "bootstrap never grants primary or invents epoch")
            try check(try DeviceIdentity.decode(identity.encoded()) == identity, "JSON roundtrip")
            let json = try JSONSerialization.jsonObject(with: identity.encoded()) as! [String: Any]
            try check(Set(json.keys) == Set(["schema", "deviceID", "name", "hardwareModel", "role",
                                            "epoch", "primaryDeviceID", "legacyIdentity", "updatedAt"]),
                      "all public fields present")
            try check(json["epoch"] is NSNull && json["legacyIdentity"] is NSNull, "unknown explicit null")
            try check(try DeviceIdentityStore.forLocalDevice(entry: ea).localDeviceID == a, "restart keeps UUID")
            let generated = try DeviceIdentityStore.forLocalDevice(entry: eb, name: "B")
            try check(UUID(uuidString: generated.localDeviceID) != nil && generated.localDeviceID != a,
                      "unpaired device persists generated UUID")
            try rejects("conflicting paired UUID rejected") {
                _ = try DeviceIdentityStore.forLocalDevice(entry: ea, pairedDeviceID: b)
            }
            var bad = identity
            bad.schema = "unknown"
            try rejects("unknown schema rejected") { _ = try bad.encoded() }
            bad = identity
            bad.role = .primary
            try rejects("primary without epoch/primary ID rejected") { _ = try bad.encoded() }
            try check(identity.hardwareModel == CommandLine.arguments[3], "real hw.model")
        case "registry":
            let reg = registry(root, "registry")
            let oldJSON = """
            [{"id":"\(a)","name":"legacy","host":"fixture","user":"fixture","sshPort":22,
              "publicKeyFingerprint":"fixture","addedAt":"2026-09-17T00:00:00Z",
              "lastSeenAt":"2026-09-17T00:00:00Z","workdirMap":{}}]
            """
            try Data(oldJSON.utf8).write(to: reg.url)
            let before = try Data(contentsOf: reg.url)
            try check(reg.list().first?.role == nil && reg.list().first?.epoch == nil,
                      "old registry role and epoch unknown")
            try check(try Data(contentsOf: reg.url) == before, "legacy read is read-only")
            _ = try reg.add(id: a, name: "primary", host: "fixture", user: "fixture",
                            publicKeyFingerprint: "fixture", role: .primary, epoch: 1)
            _ = try reg.add(id: b, name: "secondary", host: "fixture-b", user: "fixture",
                            publicKeyFingerprint: "fixture-b", role: .secondary, epoch: 1)
            try check(reg.list().first { $0.id == a }?.role == .primary, "registry primary roundtrip")
            try check(reg.list().first { $0.id == b }?.epoch == 1, "registry epoch roundtrip")
        case "migration":
            let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let values = try migration()
            let mini = values["legacy-primary"]!, book = values["legacy-secondary"]!
            try check(mini.deviceID == a && mini.role == .primary && mini.epoch == 1,
                      "1.0 mini primary epoch 1 retained")
            try check(book.deviceID == b && book.role == .secondary && book.epoch == 1
                      && book.primaryDeviceID == a && book.legacyIdentity == "legacy-secondary",
                      "secondary mapping points to same primary")
            try check(mini.hardwareModel == "fixture-mini-hardware"
                      && book.hardwareModel == "fixture-book-hardware", "per-device metadata retained")
            try check(try migration(42)["legacy-secondary"]?.epoch == 42, "channel epoch not hardcoded")
            try check(try FileManager.default.contentsOfDirectory(atPath: root.path) == before,
                      "migration writes nothing")
            try rejects("negative epoch rejected") { _ = try migration(-1) }
            for ids in [["legacy-secondary": b], ["legacy-primary": a, "legacy-secondary": a],
                        ["legacy-primary": "invalid", "legacy-secondary": b]] {
                try rejects("invalid mapping rejected") {
                    _ = try DeviceIdentityMigration.preview(
                        primaryJSON: Data("{\"name\":\"legacy-primary\",\"epoch\":1}".utf8),
                        deviceIDsByLegacyName: ids, detailsByLegacyName: [
                            "legacy-primary": .init(name: "A", hardwareModel: "A"),
                            "legacy-secondary": .init(name: "B", hardwareModel: "B")])
                }
            }
        case "guards":
            let sa = try DeviceIdentityStore.forLocalDevice(entry: ea, pairedDeviceID: a, name: "A")
            let sb = try DeviceIdentityStore.forLocalDevice(entry: eb, pairedDeviceID: b, name: "B")
            let ia = try sa.read(), ib = try sb.read()
            let beforeA = try Data(contentsOf: ea.deviceJSON), beforeB = try Data(contentsOf: eb.deviceJSON)
            do {
                try sa.write(ib)
                throw NSError(domain: "foreign write accepted", code: 1)
            } catch DeviceIdentityError.foreignDeviceWrite {
                print("PASS A writing B rejected explicitly")
            }
            try check(try Data(contentsOf: ea.deviceJSON) == beforeA
                      && Data(contentsOf: eb.deviceJSON) == beforeB, "both files unchanged after rejection")
            // Simulate external substitution; a bound writer cannot overwrite the replacement.
            try ib.encoded().write(to: ea.deviceJSON, options: .atomic)
            try rejects("replaced on-disk identity rejected") { try sa.write(ia) }
            let linkEntry = entry(root, "link")
            try FileManager.default.createDirectory(at: linkEntry.root, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkEntry.deviceJSON, withDestinationURL: eb.deviceJSON)
            try rejects("device.json symlink cannot claim remote file") {
                _ = try DeviceIdentityStore.forLocalDevice(entry: linkEntry, pairedDeviceID: b)
            }
            try check(try Data(contentsOf: eb.deviceJSON) == beforeB, "symlink target untouched")
            let alias = entry(root, "entrance-alias")
            try FileManager.default.createSymbolicLink(at: alias.root, withDestinationURL: eb.root)
            let aliasStore = try DeviceIdentityStore.forLocalDevice(entry: alias, pairedDeviceID: b)
            try aliasStore.write(ib)
            try check(try aliasStore.read() == ib, "legitimate entrance symlink supported")
            try FileManager.default.moveItem(at: alias.root, to: root.appendingPathComponent("saved-alias"))
            try FileManager.default.createSymbolicLink(at: alias.root, withDestinationURL: ea.root)
            try rejects("retargeted entrance rejected by bound writer") { try aliasStore.write(ib) }
        case "reader":
            let ra = registry(root, "ra")
            let missing = TatwoFlexPrimaryReader.read(entry: ea, registryURL: ra.url, environment: [:])
            try check(!missing.isAssigned && !missing.isLocalPrimary && missing.epoch == nil,
                      "missing identity is unknown")
            try check(!FileManager.default.fileExists(atPath: ea.root.path), "reader does not create entry")
            let sa = try DeviceIdentityStore.forLocalDevice(entry: ea, pairedDeviceID: a, name: "A")
            let sb = try DeviceIdentityStore.forLocalDevice(entry: eb, pairedDeviceID: b, name: "B")
            let values = try migration()
            try sa.write(values["legacy-primary"]!)
            try sb.write(values["legacy-secondary"]!)
            _ = try ra.add(id: a, name: "Mini fixture", host: "fixture", user: "fixture",
                           publicKeyFingerprint: "fixture", role: .secondary, epoch: 999)
            let before = try Data(contentsOf: eb.deviceJSON)
            let mini = TatwoFlexPrimaryReader.read(entry: ea, registryURL: ra.url, environment: [:])
            let book = TatwoFlexPrimaryReader.read(entry: eb, registryURL: ra.url, environment: [:])
            try check(mini.isLocalPrimary && mini.epoch == 1, "primary reader uses local sovereignty")
            try check(!book.isLocalPrimary && book.currentPrimaryName == "Mini fixture" && book.epoch == 1,
                      "secondary resolves primary UUID against registry name only")
            try check(try Data(contentsOf: eb.deviceJSON) == before, "status read leaves identity unchanged")
            var sameName = try sb.read()
            sameName.name = "Mini fixture"
            try sb.write(sameName)
            try check(!TatwoFlexPrimaryReader.read(entry: eb, registryURL: ra.url, environment: [:]).isLocalPrimary,
                      "same display names cannot elevate secondary")
            try Data("bad json".utf8).write(to: ea.deviceJSON)
            try check(!TatwoFlexPrimaryReader.read(entry: ea, registryURL: ra.url, environment: [:]).isAssigned,
                      "corrupt identity never falls back to fixture")
        case "roles":
            let defaults = UltraworkRoleConfiguration.defaultValue
            try check(defaults.primaryModelID == "fable-5.1", "constitution lead Fable 5.1")
            try check(defaults.auxiliaryModelIDs == ["gpt-6-astra", "opus-5", "grok-build", "gpt-6-astra"],
                      "constitution loops/refinement/mechanic/other-family reviewer")
            var custom = defaults
            custom.setPrimary("custom")
            custom.setAuxiliary("custom-worker", at: 5)
            try check(custom.auxiliaryModelID(at: 5) == "custom-worker", "explicit overrides retained")
            try check(try JSONDecoder().decode(UltraworkRoleConfiguration.self,
                      from: JSONEncoder().encode(custom)) == custom, "role configuration roundtrip")
        case "pairing":
            let hostEnv = ["TATWO_OS_ROOT": ea.root.path, "TATWO2_PAIRING_HOST": "127.0.0.1"]
            let clientEnv = ["TATWO_OS_ROOT": eb.root.path]
            let hr = registry(root, "host-live"), cr = registry(root, "client-live")
            let hostStore = try DeviceIdentityStore.forLocalDevice(entry: ea, pairedDeviceID: a, name: "Host")
            try hostStore.write(migration()["legacy-primary"]!)
            let host = DevicePairingHost(registry: hr, environment: hostEnv)
            defer { host.cancelPairingWindow() }
            let client = DevicePairingClient(
                registry: cr, privateKeyURL: root.appendingPathComponent("ssh/id_ed25519"),
                environment: clientEnv, sshVerifier: { _ in true },
                hostFingerprintResolver: { _ in "SHA256:synthetic-host" })
            func pair() throws -> DeviceRecord {
                let window = try host.startPairingWindow()
                let port = Int(window.listenAddress.split(separator: ":").last!)!
                return try client.pair(host: "127.0.0.1", port: port, code: window.code, name: "Client")
            }
            let peer = try pair()
            let local = try DeviceIdentityStore.readLocal(entry: eb)!
            try check(peer.id == a && peer.id != local.deviceID, "wire returns distinct host and client UUIDs")
            try check(hr.list().first?.id == local.deviceID && cr.list().first?.id == a,
                      "each registry records the remote device, not itself")
            let pairedAgain = try pair()
            try check(pairedAgain.id == a && hr.list().count == 1 && cr.list().count == 1,
                      "re-pairing retains identity without duplicate rows")
            let stale = try host.startPairingWindow()
            try hostStore.write(migration(2)["legacy-primary"]!)
            try rejects("pairing code rejected after sovereignty epoch changes") {
                _ = try client.pair(host: "127.0.0.1",
                    port: Int(stale.listenAddress.split(separator: ":").last!)!,
                    code: stale.code, name: "Client")
            }
            try check(try pair().id == a, "new pairing window uses updated epoch")
            let pub = try String(contentsOf: root.appendingPathComponent("ssh/id_ed25519.pub"), encoding: .utf8)
            try check(try hr.pairingDeviceID(publicKey: pub, requestedID: nil, localDeviceID: a) == local.deviceID,
                      "legacy request recovers existing UUID by SSH fingerprint")
            try rejects("same key cannot request second UUID") {
                _ = try hr.pairingDeviceID(publicKey: pub, requestedID: c, localDeviceID: a)
            }
            try rejects("different key cannot claim registered UUID") {
                _ = try hr.pairingDeviceID(publicKey: otherKey, requestedID: local.deviceID, localDeviceID: a)
            }
            try rejects("remote cannot claim host UUID") {
                _ = try hr.pairingDeviceID(publicKey: otherKey, requestedID: a, localDeviceID: a)
            }
            // Old client bug: its local UUID was stored against the host's SSH fingerprint.
            let legacy = registry(root, "legacy-client")
            _ = try legacy.add(id: local.deviceID, name: peer.name, host: peer.host, user: peer.user,
                               publicKeyFingerprint: peer.publicKeyFingerprint,
                               workdirMap: ["fixture-source": "fixture-destination"], role: .primary, epoch: 1)
            _ = try legacy.recordPairedHost(peer, localDeviceID: local.deviceID)
            try check(legacy.list().count == 1 && legacy.list().first?.id == a,
                      "legacy peer UUID corrected without a parallel registry")
            try check(legacy.list().first?.workdirMap["fixture-source"] == "fixture-destination"
                      && legacy.list().first?.role == .primary && legacy.list().first?.epoch == 1,
                      "legacy peer metadata retained")
            let conflict = registry(root, "conflict")
            _ = try conflict.add(id: local.deviceID, name: "unrelated", host: "other", user: peer.user,
                                 publicKeyFingerprint: "other")
            try rejects("ambiguous legacy row not silently replaced") {
                _ = try conflict.recordPairedHost(peer, localDeviceID: local.deviceID)
            }
        default: throw NSError(domain: "unknown mode", code: 1)
        }
    }
}
`);
  execFileSync('swiftc', [
    '-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    ...['TatwoEntry', 'DeviceIdentity', 'DeviceRegistry', 'DevicePairingCode', 'DevicePairingStubs',
      'DevicePairingHost', 'DevicePairingClient'].map(name => join(app, 'Facade', name + '.swift')),
    join(app, 'Chat/UltraworkRoleConfiguration.swift'), join(root, 'Reader.swift'),
    driver, '-o', outputBinary,
  ], { encoding: 'utf8', timeout: 180_000 });
  binary = outputBinary;
  return binary;
}

for (const mode of ['format', 'registry', 'migration', 'guards', 'reader', 'roles', 'pairing']) {
  test(`W76 production Swift: ${mode}`, () => {
    const root = testScratch(`w76-${mode}-`);
    const hardware = execFileSync('/usr/sbin/sysctl', ['-n', 'hw.model'], { encoding: 'utf8' }).trim();
    const env = Object.fromEntries(Object.entries(process.env)
      .filter(([key]) => !key.startsWith('TATWO') && !key.startsWith('GIT_')));
    const output = execFileSync(probe(), [mode, root, hardware], {
      encoding: 'utf8', env, timeout: 90_000,
    });
    assert.match(output, new RegExp(`W76 PASS ${mode}`));
  });
}

test('W76 wiring: production reader is fixture-free; pairing carries real IDs and epoch', () => {
  const stubs = source('Facade/DevicesStubs.swift');
  assert.doesNotMatch(stubs, /DevicesExportSyncFixture/);
  assert.match(source('Facade/DevicePairingHost.swift'), /authorityEpoch: UInt64\(identity\.epoch \?\? 0\)/);
  assert.match(source('Facade/DevicePairingHost.swift'), /hostDeviceID: local\.deviceID/);
  assert.match(source('Facade/DevicePairingClient.swift'), /pairedDeviceID: deviceID/);
  assert.match(source('Chat/UltraworkRoleConfiguration.swift'), /與憲法 §4 一致，改表先改憲法/);
});
