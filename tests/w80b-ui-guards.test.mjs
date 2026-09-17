import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

test('W80b production Swift: secondary cannot access provider credentials; no key cannot enable semantics',
  { timeout: 180000 }, () => {
    const root = testScratch('w80b-swift-');
    const app = fileURLToPath(new URL('../App/Sources/Tatwo2/Facade/', import.meta.url));
    // Only unrelated runtime/resource locations and credential storage are fixtures.
    // Role validation, all mutation guards and Published settings are production Swift.
    fs.writeFileSync(path.join(root, 'Resources.swift'), `
import Foundation
enum NativeStagingIsolation { static func isEnabled(_ e: [String: String]) -> Bool { true } }
struct EnginePaths {
    init(environment: [String: String] = [:]) {}
    var runtimeBinDirectory: URL { URL(fileURLWithPath: "/fixture-missing") }
}
enum ClaudeSidecar {
    enum Kind { case claude }
    static func scriptPath(for kind: Kind) -> String { "/fixture-missing/claude-sidecar/sidecar.mjs" }
}
struct FixtureRecord { var id = ""; var role: DeviceRole?; var host = ""; var user = ""; var sshPort = 22; var name = "" }
enum DeviceStatusReader { static func registry() -> [FixtureRecord] { [] } }
struct FixtureHealth { var value: String?; var reason: String? }
enum GBrainHealth { static func read(entry: TatwoEntry) -> FixtureHealth { .init(value: nil, reason: "not_configured") } }
`);
    fs.writeFileSync(path.join(root, 'Checks.swift'), `
import Foundation
final class MemorySecrets: GBrainSecretStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var reads = 0
    private(set) var writes = 0
    func contains(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[name] != nil }
    func read(_ name: String) throws -> String? { lock.lock(); defer { lock.unlock() }; reads += 1; return values[name] }
    func save(_ value: String, name: String) throws { lock.lock(); defer { lock.unlock() }; writes += 1; values[name] = value }
    func remove(_ name: String) throws { lock.lock(); defer { lock.unlock() }; writes += 1; values.removeValue(forKey: name) }
}
@main struct Checks {
    static func require(_ ok: Bool, _ label: String) {
        if !ok { fatalError(label) }
        print("PASS " + label)
    }
    static func settle(_ predicate: () -> Bool) {
        let until = Date().addingTimeInterval(3)
        while !predicate() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let primary = "11111111-1111-4111-8111-111111111111"
        let secondary = "22222222-2222-4222-8222-222222222222"
        for role in [DeviceRole.secondary, .primary] {
            let folder = root.appendingPathComponent(role.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let entry = TatwoEntry(environment: ["TATWO_OS_ROOT": folder.path], preference: nil)
            let identity = DeviceIdentity(deviceID: role == .primary ? primary : secondary,
                name: "fixture", hardwareModel: "fixture", role: role, epoch: 1,
                primaryDeviceID: primary, updatedAt: Date())
            try identity.encoded().write(to: entry.deviceJSON)
            let vault = MemorySecrets()
            let service = GBrainService(entry: entry, secrets: vault)
            require(service.isPrimary == (role == .primary), "role from validated device identity")
            service.setSemantic(true)
            require(!FileManager.default.fileExists(atPath: entry.gbrainDir.appendingPathComponent("preferences.json").path),
                    "no-key semantic enable does not persist a preference")
            if role == .secondary {
                service.saveKey("fixture", provider: "openai")
                service.removeKey(provider: "openai")
                service.testKey(provider: "openai")
                require(vault.reads == 0 && vault.writes == 0, "secondary provider actions do not touch a credential store")
            } else {
                service.saveKey("fixture", provider: "openai")
                settle { service.openAIConfigured }
                require(service.openAIConfigured, "primary save publishes configured without publishing key")
                service.removeKey(provider: "openai")
                settle { !service.openAIConfigured }
                require(!service.openAIConfigured && !service.semanticEnabled, "removing provider credential disables semantics")
            }
        }
    }
}
`);
    const binary = path.join(root, 'checks');
    execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
      ...['TatwoEntry', 'DeviceIdentity', 'GBrainKeychain', 'GBrainService'].map(n => path.join(app, `${n}.swift`)),
      path.join(root, 'Resources.swift'), path.join(root, 'Checks.swift'), '-o', binary],
    { encoding: 'utf8', timeout: 150000 });
    const home = path.join(root, 'home'); fs.mkdirSync(home);
    const output = execFileSync(binary, [root], { encoding: 'utf8', timeout: 10000,
      env: { HOME: home, TMPDIR: process.env.TMPDIR, PATH: '/usr/bin:/bin' } });
    assert.match(output, /PASS secondary provider actions do not touch a credential store/);
    assert.match(output, /PASS no-key semantic enable does not persist a preference/);
    assert.match(output, /PASS removing provider credential disables semantics/);
  });
