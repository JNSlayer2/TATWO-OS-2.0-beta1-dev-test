import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, realpathSync, readdirSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const peer = read('App/Sources/Tatwo2/Facade/PeerUpdateSource.swift');
const updater = read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
const registry = read('App/Sources/Tatwo2/Facade/DeviceRegistry.swift');
const sync = read('App/Sources/Tatwo2/Facade/RemoteEngineSync.swift');
const card = read('App/Sources/Tatwo2/New/DevicesCard.swift');

test('GitHub release and all fresh checksums precede peer lookup; misses alone download', () => {
  const positions = ['let release =', 'var expectedHashes:', 'expectedHashes[archive.name] =',
    'PeerUpdateSource.discover(DeviceRegistry().list())', 'for offer in offers',
    'Self.digest(candidate), actual == expected', 'moveItem(at: candidate, to: zip)',
    'progress.download(request:', 'Self.digest(zip) == expected.lowercased()',
    'PeerUpdateSource.publish(directory, tag: tag)'].map(s => updater.indexOf(s, updater.indexOf('private func prefetch')));
  // The first digest(zip) belongs to the independently revalidated local cache.
  positions[8] = updater.indexOf('Self.digest(zip) == expected.lowercased()', positions[7]);
  assert.ok(positions.every((n, i) => n >= 0 && (!i || n > positions[i - 1])), positions);
  assert.match(updater, /session\.data\(for: try assetRequest\(checksum\), delegate: UpdateRedirectDelegate.shared\)/);
  assert.match(updater, /try\? await PeerUpdateSource\.pull[\s\S]*try\? await Self\.digest/);
  assert.match(updater, /try Task\.checkCancellation\(\)\s+downloadSource = deltaProgress \+ "從 GitHub 下載…"/);
  assert.match(updater, /invalid-\\\(UUID\(\)\.uuidString\)/);
  assert.doesNotMatch(peer, /https?:|TATWO_OS_IMAGE|--delete/);
});

test('parallel discovery has one five-second device budget, bounded transfers and fixture gate before Process', () => {
  assert.match(peer, /withTaskGroup[\s\S]*for device in devices[\s\S]*group\.addTask/);
  assert.match(peer, /deadline = ProcessInfo\.processInfo\.systemUptime \+ 5/);
  assert.match(peer, /deadline - ProcessInfo\.processInfo\.systemUptime/);
  assert.match(peer, /kill\(process\.processIdentifier, SIGKILL\)/);
  assert.doesNotMatch(peer, /process\.waitUntilExit\(\)/);
  assert.ok(peer.indexOf('RemoteSyncFixture.validate') < peer.indexOf('let process = Process()'));
  assert.match(peer, /#else[\s\S]*fixtureBlocked\("release"\)/);
  assert.match(peer, /attributes\[\.type\].*\.typeRegular/);
});

test('availability published by App launch; display only; installer and signature gate unchanged', () => {
  assert.match(updater, /consumeResultOnLaunch\(\) \{\s+Task \{ await PeerUpdateSource\.publishInstalled/);
  assert.match(peer, /"--verify", "--deep", "--strict"/);
  assert.match(peer, /entries\[key\]\?\.installedApp = nil/);
  assert.match(card, /Text\(PeerUpdateSource\.summary/);
  assert.match(card, /\.task\(id: model\.devices\)/);
  assert.equal(read('install.sh'), read('public/install.sh'));
  assert.match(read('install.sh'), /actual="\$\(shasum -a 256 "\$output"\)"[\s\S]*== "\$expected"/);
  assert.match(read('install.sh'), /codesign --verify --deep --strict/);
});

test('production Swift: registry/available round-trip, LAN order, argv, capture-only, timeout and cancellation',
  { skip: process.platform !== 'darwin', timeout: 120_000 }, () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'w21-peer-')));
    const token = randomUUID();
    writeFileSync(join(root, 'owner.json'), JSON.stringify({ token }));
    const fixtureTypes = sync.slice(sync.indexOf('enum RemoteEngineSyncError'), sync.indexOf('struct RemoteEngineSync {'));
    const harness = `
import Foundation
${fixtureTypes}
@main struct Main {
  @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1]), mode = CommandLine.arguments[2]
    let device = DeviceRecord(id: "sample", name: "Mac mini 房間", host: "proxy.example", user: "sample",
      sshPort: 2222, publicKeyFingerprint: "SHA256:fixture", addedAt: Date(), lastSeenAt: Date(), workdirMap: [:],
      lanHost: "sample.local")
    let offer = PeerUpdateSource.Offer(device: device, host: "sample.local", entries: [:])
    if mode == "capture" || mode == "invalid" {
      for command in [PeerUpdateSource.ssh(device, host: "sample.local"),
        PeerUpdateSource.rsync(offer, path: "/Users/sample/Library/Application Support/TATWO OS/Updater/download/sample/project/v2.0.4/TATWO-OS-app.zip",
          destination: root.appendingPathComponent("app.zip")),
        PeerUpdateSource.rsync(offer, path: "/Applications/TATWO OS.app/Contents/./Resources/runtime",
          destination: root.appendingPathComponent("runtime"), relative: true),
        ["/usr/bin/touch", root.appendingPathComponent("MUST-NOT-EXIST").path]] {
        do { _ = try await PeerUpdateSource.run(command, seconds: 1); preconditionFailure("fixture ran") }
        catch let error as RemoteEngineSyncError {
          switch (mode, error) {
          case ("capture", .fixtureCaptureOnly), ("invalid", .fixtureBlocked): break
          default: preconditionFailure("\\(error)")
          }
        }
      }
      return
    }
    precondition(PeerUpdateSource.hosts(device) == ["sample.local", "proxy.example"])
    var bad = device; bad.user = "-oProxyCommand=bad"; precondition(PeerUpdateSource.hosts(bad).isEmpty)
    bad = device; bad.host = "bad;host"; bad.lanHost = nil; precondition(PeerUpdateSource.hosts(bad).isEmpty)
    for tag in ["../escape", "v1.2.3\\n", "v1.2.3/other"] { precondition(!PeerUpdateSource.validTag(tag)) }
    let path = "/Users/sample/Library/Application Support/TATWO OS/Updater/download/sample/project/v2.0.4/TATWO-OS-app.zip"
    precondition(PeerUpdateSource.cachePath(path, tag: "v2.0.4", name: "TATWO-OS-app.zip"))
    for wrong in [path.replacingOccurrences(of: "/sample/", with: "/../"), path + "\\n", "/etc/passwd"] {
      precondition(!PeerUpdateSource.cachePath(wrong, tag: "v2.0.4", name: "TATWO-OS-app.zip"))
    }
    let registry = DeviceRegistry(root: root.appendingPathComponent("live"), authorizedKeysURL: root.appendingPathComponent("keys"))
    try registry.add(device); precondition(registry.list().first?.lanHost == "sample.local")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: registry.url)) as! [[String: Any]]
    legacy[0].removeValue(forKey: "lanHost")
    try JSONSerialization.data(withJSONObject: legacy).write(to: registry.url)
    precondition(registry.list().count == 1 && registry.list()[0].lanHost == nil)
    try PeerUpdateSource.publish(root, tag: "v2.0.4") {
      $0.app = path; $0.sha256["TATWO-OS-app.zip"] = String(repeating: "a", count: 64)
      $0.sizes["TATWO-OS-app.zip"] = 62_300_000
    }
    try PeerUpdateSource.publish(root, tag: "v2.0.4") { $0.runtimeSha = String(repeating: "b", count: 64); $0.installedApp = "/Applications/TATWO OS.app" }
    try PeerUpdateSource.publish(root, tag: "v2.0.3") { $0.runtime = "old" }
    let entries = PeerUpdateSource.read(root)
    precondition(entries.count == 2 && entries["v2.0.4"]?.app == path)
    precondition(entries["v2.0.4"]?.sha256["TATWO-OS-app.zip"] == String(repeating: "a", count: 64))
    precondition(PeerUpdateSource.summary(entries) == "可提供更新：v2.0.4（app 62 MB／runtime 已裝）")
    precondition(PeerUpdateSource.summary([:]) == "可提供更新：無")
    let minimal = try JSONDecoder().decode([String: PeerUpdateEntry].self, from: Data(#"{"v2.0.4":{"app":"cache","sha256":{}}}"#.utf8))
    precondition(minimal["v2.0.4"]?.sizes == [:])
    precondition(PeerUpdateSource.summary(minimal) == "可提供更新：v2.0.4（app 快取）")
    let started = Date()
    print("timeout-start"); fflush(stdout)
    do { _ = try await PeerUpdateSource.run(["/bin/sleep", "10"], seconds: 0.15); preconditionFailure("no timeout") }
    catch { precondition((error as? URLError)?.code == .timedOut) }
    print("timeout-returned"); fflush(stdout)
    precondition(Date().timeIntervalSince(started) < 1)
    for _ in 0..<12 {
      let task = Task { try await PeerUpdateSource.run(["/bin/sleep", "10"], seconds: 5) }
      try await Task.sleep(for: .milliseconds(100)); task.cancel()
      do { _ = try await task.value; preconditionFailure("no cancellation") } catch { precondition(error is CancellationError) }
    }
    print("cancel-returned"); fflush(stdout)
    let output = try await PeerUpdateSource.run(["/usr/bin/printf", "ok"], seconds: 1)
    precondition(String(decoding: output, as: UTF8.self) == "ok")
    print("roundtrip / timeout / cancellation passed")
  }
}
`;
    writeFileSync(join(root, 'Main.swift'), harness);
    const binary = join(root, 'probe');
    const compile = spawnSync('swiftc', ['-D', 'DEBUG', '-swift-version', '5', '-parse-as-library',
      new URL('../App/Sources/Tatwo2/Facade/PeerUpdateSource.swift', import.meta.url).pathname,
      new URL('../App/Sources/Tatwo2/Facade/DeviceRegistry.swift', import.meta.url).pathname,
      join(root, 'Main.swift'), '-o', binary], { encoding: 'utf8', timeout: 90_000 });
    assert.equal(compile.status, 0, compile.stderr);
    const clean = { ...process.env };
    for (const key of ['TATWO2_REMOTETEST', 'TATWO2_REMOTE_SYNC_FIXTURE', 'TATWO2_REMOTE_SYNC_TOKEN']) delete clean[key];
    const run = (mode, env) => {
      const result = spawnSync(binary, [root, mode], { env: { ...clean, ...env }, encoding: 'utf8', timeout: 15_000 });
      assert.equal(result.status, 0, `${mode}: ${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
    };
    run('normal', {});
    run('capture', { TATWO2_REMOTETEST: '1', TATWO2_REMOTE_SYNC_FIXTURE: root, TATWO2_REMOTE_SYNC_TOKEN: token });
    run('invalid', { TATWO2_REMOTETEST: '1' });
    assert.ok(!existsSync(join(root, 'MUST-NOT-EXIST')));
    const commands = readdirSync(root).filter(n => n.startsWith('peer-command-'))
      .flatMap(n => JSON.parse(readFileSync(join(root, n))).commands);
    assert.equal(commands.length, 4);
    const ssh = commands.find(c => c[0] === '/usr/bin/ssh');
    assert.deepEqual(ssh.slice(1, 7), ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=2']);
    assert.equal(ssh.at(-2), 'sample@sample.local');
    for (const option of ['ControlMaster=no', 'ControlPath=none', 'ForwardAgent=no']) assert.ok(ssh.includes(option));
    assert.equal(ssh.at(-1), "cat ~/'Library/Application Support/TATWO OS/Updater/available.json'");
    const rsync = commands.find(c => c[0] === '/usr/bin/rsync' && !c.includes('--relative'));
    assert.deepEqual(rsync.slice(1, 5), ['-az', '--partial', '--inplace', '--timeout=5']);
    assert.match(rsync[6], /StrictHostKeyChecking=accept-new.*-p 2222$/);
    assert.match(rsync[7], /^sample@sample\.local:'\/Users\/sample\/Library\/Application Support/);
    assert.equal(rsync.at(-1), join(root, 'app.zip'));
    const installed = commands.find(c => c.includes('--relative'));
    assert.equal(installed.at(-2), "sample@sample.local:'/Applications/TATWO OS.app/Contents/./Resources/runtime'");
    assert.equal(installed.at(-1), join(root, 'runtime'));
  });


test('production prefetch decision executes SHA gates and per-archive fallback with isolated I/O doubles',
  { skip: process.platform !== 'darwin', timeout: 120_000 }, () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'w21-prefetch-')));
    const prefetch = updater.slice(updater.indexOf('    private func prefetch('), updater.indexOf('    private func recordDownloadProgress'))
      .replace('private func prefetch', 'func prefetch').replace(/let installed = [^\n]+/, 'let installed: String? = "2.0.5"');
    const digest = updater.slice(updater.indexOf('    private nonisolated static func digest'), updater.indexOf('    private func handOff'));
    const policy = updater.slice(updater.indexOf('    static func retryable'), updater.indexOf('    private func finish'));
    const retry = updater.slice(updater.indexOf('    private func retryDownload'), updater.indexOf('    private func helperIsActive'));
    const entry = peer.slice(peer.indexOf('struct PeerUpdateEntry'), peer.indexOf('enum PeerUpdateSource'));
    const harness = `
import Foundation
import CryptoKit
${read('App/Sources/Tatwo2/Facade/GitHubReleaseUpdateChecker.swift').split('// UPDATE-TRANSPORT-BEGIN\n')[1].split('// UPDATE-TRANSPORT-END')[0]}
${entry}
struct UpdateChannel {
  static let privateRepository = "tatwo214/TATWO-OS-2.0-private"
  var isPrivate: Bool { IO.mode == "private" }
  var username: String? { "fixture" }
  static func current() -> Self { Self() }
  func authorize(_ request: inout URLRequest) {
    if isPrivate { request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization") }
  }
}
struct Asset: Codable { let id: Int; let name: String; let browser_download_url: String; let size: Int64 }
struct Release: Codable { let tag_name: String; let draft: Bool; var prerelease = false; let assets: [Asset] }
${updater.slice(updater.indexOf('private struct UpdateArchives'), updater.indexOf('@MainActor\nfinal class InAppUpdater')).replaceAll('private ', '')}
enum UpdateRuntimeLayer { static func canReuse(contents: URL, archiveName: String) -> Bool { false } }
struct DeviceRegistry { func list() -> [String] { ["paired"] } }
enum IO {
  static var mode = "", events: [String] = [], published: [String: PeerUpdateEntry] = [:]
  static var assetNames: [String] = []
  static let runtime = "TATWO-OS-runtime-123456789abc.zip"
  static func bytes(_ name: String) -> Data {
    if name == "TATWO-OS.manifest.json" { return Data(#"{"schema":1,"files":[{"size":1000}]}"#.utf8) }
    return Data(("verified fixture " + name).utf8)
  }
}
final class ProtocolStub: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    let privateAsset = url.path.contains("/releases/assets/")
    let name = privateAsset ? IO.assetNames[Int(url.lastPathComponent)! - 1] : url.lastPathComponent
    let data: Data
    if IO.mode == "private" {
      precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
      if privateAsset { precondition(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream") }
    } else { precondition(request.value(forHTTPHeaderField: "Authorization") == nil) }
    if url.path.contains("/contents/") {
      precondition(url.query == "ref=v9.9.9"); data = Data("#!/bin/bash\\n# OFFLINE-RELEASE-BEGIN\\nexit 0\\n".utf8)
    } else if url.host == "api.github.com" && !privateAsset {
      IO.events.append("release")
      let names = IO.mode == "delta" ? ["TATWO-OS-app.zip", IO.runtime, "TATWO-OS.manifest.json", "TATWO-OS-delta-v2.0.5-v9.9.9.zip"] : IO.mode == "legacy" ? ["TATWO-OS.zip"] : ["TATWO-OS-app.zip", IO.runtime]
      let all = names + ["TATWO-OS.zip", "TATWO-OS.manifest.json"].filter { !names.contains($0) }
      IO.assetNames = all + all.map { $0 + ".sha256" } + ["TATWO-OS.install-ready"]
      let repo = IO.mode == "private" ? UpdateChannel.privateRepository : "demo/repo"
      let assets = IO.assetNames.enumerated().map { i, name in
        Asset(id:i+1, name:name, browser_download_url: "https://github.com/" + repo + "/releases/download/v9.9.9/" + name, size:name == "TATWO-OS-app.zip" ? 1000 : Int64(IO.bytes(name).count))
      }
      data = try! JSONEncoder().encode(Release(tag_name: "v9.9.9", draft: false, assets: assets))
    } else if name == "TATWO-OS.manifest.json" { data = IO.bytes(name)
    } else if name == "TATWO-OS.install-ready" {
      let names = IO.assetNames.filter { !$0.hasSuffix(".sha256") && $0 != "TATWO-OS.install-ready" }
      data = Data(names.map { name in
        let hash = SHA256.hash(data: IO.bytes(name)).map { String(format:"%02x",$0) }.joined()
        return IO.mode == "legacy" ? name : hash + "  " + name
      }.joined(separator:"\\n").utf8)
    } else {
      precondition(name.hasSuffix(".sha256")); IO.events.append(name)
      precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
      let sha = SHA256.hash(data: IO.bytes(String(name.dropLast(7)))).map { String(format: "%02x", $0) }.joined()
      data = Data((IO.mode == "malformedsha" ? "bad" : sha).utf8)
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
enum PeerUpdateSource {
  struct Device { let name = "fixture peer" }
  struct Offer { let device = Device() }
  static func discover(_ devices: [String]) async -> [Offer] {
    precondition(devices == ["paired"]); IO.events.append("discover")
    if IO.mode == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
    return [Offer()]
  }
  static func pull(_ offer: Offer, tag: String, name: String, folder: URL) async throws -> URL? {
    IO.events.append("peer:" + name)
    if IO.mode == "offline" || IO.mode == "private" || IO.mode == "badgithub" { throw URLError(.timedOut) }
    if IO.mode == "partial" && name == IO.runtime { return nil }
    let candidate = folder.appendingPathComponent(UUID().uuidString)
    try (IO.mode == "badsha" ? Data("bad".utf8) : IO.bytes(name)).write(to: candidate)
    return candidate
  }
  static func publish(_ root: URL, tag: String, edit: (inout PeerUpdateEntry) -> Void) throws {
    var entry = IO.published[tag] ?? PeerUpdateEntry(); edit(&entry); IO.published[tag] = entry
  }
}
final class UpdateDownloadProgress {
  let destination: URL
${policy}
  init(destination: URL, rebase: @escaping @Sendable (Int64, Int64) -> Void,
       report: @escaping @Sendable (Int64, Int64) -> Void) { self.destination = destination }
  func download(request: URLRequest) async throws -> URL {
    let url = request.url!
    let name: String
    if IO.mode == "private" {
      precondition(url.host == "api.github.com" && url.path.contains("/releases/assets/"))
      precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
      precondition(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
      name = IO.assetNames[Int(url.lastPathComponent)! - 1]
    } else { name = url.lastPathComponent }
    IO.events.append("github:" + name)
    try (IO.mode == "badgithub" ? Data("corrupt".utf8) : IO.bytes(name)).write(to: destination)
    return destination
  }
}
@MainActor final class Probe {
  enum Phase { case starting }
  var phase = Phase.starting, downloadID = UUID(), downloadSource = ""
  var totalBytes: Int64 = 0, downloadProgress: Double?
  var candidateBytes: Int64 = 0
  var spaceEstimates: [Int64] = []
  func checkSpace() throws {
    precondition(candidateBytes > 0)
    spaceEstimates.append(candidateBytes)
    IO.events.append("space")
  }
  var downloadedBytes: Int64 = 0, downloadBytesPerSecond: Double = 0
  var speedSamples: [(TimeInterval, Int64)] = []
  let fileManager = FileManager.default, directory: URL
  static let destinationApp = "/nonexistent-fixture/TATWO OS.app"
  init(_ root: URL) { directory = root }
  func recordDownloadProgress(_ bytes: Int64, total: Int64) {}
${prefetch}
${retry}
${digest}
}
@main struct Main {
  @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1]); IO.mode = CommandLine.arguments[2]
    let repo = IO.mode == "private" ? UpdateChannel.privateRepository : "demo/repo"
    let folder = root.appendingPathComponent("download/\\(repo)/v9.9.9")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if IO.mode == "cache" || IO.mode == "corruptcache" {
      for name in ["TATWO-OS-app.zip", IO.runtime] {
        try (IO.mode == "cache" ? IO.bytes(name) : Data("corrupt".utf8)).write(to: folder.appendingPathComponent(name))
      }
    }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProtocolStub.self]
    let session = URLSession(configuration: config), probe = Probe(root)
    do {
      let result = try await probe.prefetch(tag: "v9.9.9", repository: IO.mode == "private" ? UpdateChannel.privateRepository : "demo/repo", session: session, id: probe.downloadID)
      precondition(!["malformedsha", "cancel", "legacy", "badgithub"].contains(IO.mode))
      let paths = [result.zip, result.appZip, result.runtimeZip, result.deltaZip, result.manifest].compactMap { $0 }
      precondition(paths.count == (IO.mode == "legacy" ? 1 : 2))
      if IO.mode == "delta" { precondition(result.deltaZip != nil && result.manifest != nil && probe.downloadSource.hasPrefix("差異更新：")) }
      for path in paths { let bytes = try Data(contentsOf: path); precondition(bytes == IO.bytes(path.lastPathComponent)) }
      precondition(IO.published["v9.9.9"]?.sha256.count == paths.count)
      if IO.mode == "private" {
        precondition(result.privateInstaller != nil && result.username == nil)
        precondition(!(try! String(contentsOf:result.privateInstaller!, encoding:.utf8)).contains("fixture-only"))
      }
    } catch { precondition(["malformedsha", "cancel", "legacy", "badgithub"].contains(IO.mode), "unexpected error: \\(error)") }
    let selectedBytes: Int64 = IO.mode == "delta"
      ? Int64(IO.bytes("TATWO-OS.manifest.json").count + IO.bytes("TATWO-OS-delta-v2.0.5-v9.9.9.zip").count)
      : IO.mode == "legacy" ? Int64(IO.bytes("TATWO-OS.zip").count)
      : 1000 + Int64(IO.bytes(IO.runtime).count)
    precondition(probe.spaceEstimates.first == selectedBytes)
    precondition(IO.events.firstIndex(of:"space") == 1) // Immediately after release metadata.
    if probe.spaceEstimates.count == 2 {
      precondition(probe.spaceEstimates[1] == max(selectedBytes,1000))
    }
    if ["malformedsha", "legacy"].contains(IO.mode) { precondition(!IO.events.contains("discover")) }
    else {
      let index = IO.events.firstIndex(of: "discover")!
      precondition(IO.events[..<index].filter { $0.hasSuffix(".sha256") }.count == (IO.mode == "legacy" ? 3 : 4))
    }
    let downloads = IO.events.filter { $0.hasPrefix("github:") }
    switch IO.mode {
    case "badsha", "offline", "private": precondition(downloads.count == 2)
    case "badgithub": precondition(downloads.count == 1)
    case "partial": precondition(downloads == ["github:" + IO.runtime])
    default: precondition(downloads.isEmpty)
    }
    if IO.mode == "cache" { precondition(!IO.events.contains(where: { $0.hasPrefix("peer:") })) }
    precondition(!(try! FileManager.default.contentsOfDirectory(atPath: folder.path)).contains(where: { $0.hasPrefix("invalid-") }))
    print(IO.events.joined(separator: " -> "))
  }
}
`;
    writeFileSync(join(root, 'Main.swift'), harness);
    const binary = join(root, 'probe');
    const compiled = spawnSync('swiftc', ['-swift-version', '5', '-parse-as-library', join(root, 'Main.swift'), '-o', binary],
      { encoding: 'utf8', timeout: 90_000 });
    assert.equal(compiled.status, 0, compiled.stderr);
    for (const mode of ['peer', 'badsha', 'badgithub', 'offline', 'partial', 'cache', 'corruptcache', 'legacy', 'malformedsha', 'cancel', 'delta', 'private']) {
      const result = spawnSync(binary, [join(root, mode), mode], { encoding: 'utf8', timeout: 10_000 });
      assert.equal(result.status, 0, `${mode}: ${result.stderr}`);
    }
  });
