import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createHash } from 'node:crypto';

const updater = readFileSync(new URL('../App/Sources/Tatwo2/Facade/InAppUpdater.swift', import.meta.url), 'utf8');
const card = readFileSync(new URL('../App/Sources/Tatwo2/New/UpdateAvailableCard.swift', import.meta.url), 'utf8');
const stubs = readFileSync(new URL('../App/Sources/Tatwo2/Facade/OS1Stubs.swift', import.meta.url), 'utf8');

test('W22 exact delta naming, size boundary and quoted handoff', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w22-handoff-'));
  const deltaZip = join(dir, "delta's.zip"), manifest = join(dir, "manifest's.json");
  const result = run(0, { deltaZip, manifest });
  assert.equal(readFileSync(join(result.dir, 'delta.calls'), 'utf8'), `delta=${deltaZip}\nmanifest=${manifest}\n`);
  assert.match(updater, /TATWO-OS.manifest.json.sha256/);
});

test('update card shares the guarded update action and keeps the terminal fallback', () => {
  assert.match(card, /await updater\.activateUpdateMark\(to: release\.tag_name, repository: checker\.repository\)/);
  assert.match(card, /\.buttonStyle\(\.borderedProminent\)/);
  assert.match(card, /DisclosureGroup\("進階：用終端機更新"\)/);
  assert.match(card, /checker\.terminalInstallCommand/);
  assert.match(stubs, /InAppUpdater\.shared\.consumeResultOnLaunch\(\)/);
});

test('updater reuses install.sh from the same public repository for signing and replacement after prefetch', () => {
  assert.match(updater, /https:\/\/raw\.githubusercontent\.com\/\\\(repository\)\/main\/install\.sh/);
  assert.match(updater, /\/bin\/launchctl/);
  assert.match(updater, /"submit", "-l", label/);
  assert.match(updater, /NSApp\.terminate\(nil\)/);
  assert.match(updater, /TATWO_OS_VERSION="\$TAG" bash "\$SCRIPT"/);
  assert.doesNotMatch(updater.slice(updater.indexOf("// UPDATE-HELPER-BEGIN")), /codesign|shasum|unzip|spctl/);
  assert.match(updater, /\^v\?\[0-9\]\+\[\.\]\[0-9\]\+/);
});

// 把 Swift 裡的 helper 模板還原成真的 bash 腳本，用假的 install.sh 跑一遍。
function renderHelper({ pid, resultPath, logPath, destination, label, prefetchedZip,
  prefetchedAppZip = '', prefetchedRuntimeZip = '', prefetchedDeltaZip = '', prefetchedManifest = '', prefetchedRoute = '', wait = 10 }) {
  const begin = updater.indexOf('// UPDATE-HELPER-BEGIN');
  const end = updater.indexOf('// UPDATE-HELPER-END');
  const block = updater.slice(begin, end);
  const body = block.slice(block.indexOf('"""') + 3, block.lastIndexOf('"""'));
  const lines = body.split('\n');
  const indent = lines.find(line => line.trim().length)?.match(/^\s*/)[0].length ?? 0;
  return lines.map(line => line.slice(indent)).join('\n')
    .replace(/\\\\n/g, '\\n')
    .replace('\\(pid)', String(pid))
    .replace('\\(helperWaitSeconds)', String(wait))
    .replace(/\\\(quoted\((\w+)\)\)/g, (_, key) => {
      const values = { tag: 'v9.9.9', installURL: 'https://invalid.example/install.sh',
        resultPath, logPath, destination, label, prefetchedZip, prefetchedAppZip, prefetchedRuntimeZip, prefetchedDeltaZip, prefetchedManifest, prefetchedRoute, privateInstaller: "", githubUsername: "" };
      return "'" + values[key].replaceAll("'", "'\\''") + "'";
    });
}

function run(fakeInstallExit, options = {}) {
  const dir = options.dir ?? mkdtempSync(join(tmpdir(), "tatwo-update-quote'-"));
  const bin = join(dir, 'bin');
  mkdirSync(bin, { recursive: true });
  const fake = (name, body) => {
    writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`);
    chmodSync(join(bin, name), 0o755);
  };
  // Service, process-name and UI commands are fixtures; no real launchd/App mutation.
  fake('open', 'echo "$@" >> "$TEST_DIR/open.calls"');
  fake('launchctl', 'echo "$@" >> "$TEST_DIR/launchctl.calls"; exit "${REMOVE_EXIT:-0}"');
  fake('pgrep', `echo pgrep >> "$TEST_DIR/pgrep.calls"
    count=$(wc -l < "$TEST_DIR/pgrep.calls")
    if [ "\${RELAUNCH_AT:-0}" -gt 0 ] && [ "$count" -ge "$RELAUNCH_AT" ]; then exit 0; fi
    [ -f "$TEST_DIR/relaunched" ]`);
  fake('curl', `while [ "$#" -gt 0 ]; do
      if [ "$1" = -o ]; then shift; target="$1"; fi
      shift
    done
    echo "$target" >> "$TEST_DIR/curl.calls"
    [ "\${CURL_FAIL:-0}" = 0 ] || exit 22
    cp "$TEST_DIR/install.sh" "$target"`);
  if (options.mktempFail) fake('mktemp', 'exit 1');
  const install = join(dir, 'install.sh');
  writeFileSync(install, `#!/bin/bash
    printf 'version=%s\\nzip=%s\\n' "$TATWO_OS_VERSION" "$TATWO_OS_PREFETCHED_ZIP" >> "$TEST_DIR/install.calls"
    printf 'app=%s\\nruntime=%s\\n' "$TATWO_OS_PREFETCHED_APP_ZIP" "$TATWO_OS_PREFETCHED_RUNTIME_ZIP" > "$TEST_DIR/layers.calls"
    printf 'delta=%s\\nmanifest=%s\\n' "$TATWO_OS_PREFETCHED_DELTA_ZIP" "$TATWO_OS_PREFETCHED_MANIFEST" > "$TEST_DIR/delta.calls"
    printf '%s\\n' "$TATWO_OS_PREFETCHED_ROUTE" > "$TEST_DIR/route.calls"
    [ "\${RELAUNCH_DURING_INSTALL:-0}" = 0 ] || touch "$TEST_DIR/relaunched"
    exit ${fakeInstallExit}
  `);
  const destination = join(dir, 'TATWO OS.app');
  mkdirSync(destination, { recursive: true });
  const prefetchedZip = join(dir, 'download', 'TATWO-OS.zip');
  mkdirSync(join(dir, 'download'), { recursive: true });
  writeFileSync(prefetchedZip, 'verified fixture');
  const pid = options.stillRunning ? process.pid : options.waitForApp
    ? Number(spawnSync('bash', ['-c', 'sleep 2 >/dev/null 2>&1 & echo $!']).stdout.toString().trim())
    : 99999999;
  const script = join(dir, 'helper.sh');
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  writeFileSync(script, renderHelper({
    pid, resultPath: join(dir, options.runID ? options.runID + '.json' : 'result.json'), logPath: join(dir, 'update.log'),
    destination, prefetchedZip, prefetchedAppZip: options.appZip ?? '', prefetchedRuntimeZip: options.runtimeZip ?? '', prefetchedDeltaZip: options.deltaZip ?? '', prefetchedManifest: options.manifest ?? '', prefetchedRoute: options.route ?? '',
    label: 'ai.tatwo.tatwo2.updater.' + (options.runID ?? 'test'), wait: options.stillRunning ? 0 : 10,
  }).replace('export PATH=/usr/bin:/bin:/usr/sbin:/sbin', `export PATH=${quote(bin)}:/usr/bin:/bin:/usr/sbin:/sbin`));
  const started = Date.now();
  const result = spawnSync('bash', [script], { env: { ...process.env,
    TMPDIR: dir, TEST_DIR: dir, TATWO2_UPDATE_INSTALL_SCRIPT: options.fetchScript ? '' : install,
    RELAUNCH_AT: String(options.relaunchAt ?? 0), RELAUNCH_DURING_INSTALL: options.relaunchDuring ? '1' : '0',
    CURL_FAIL: options.curlFail ? '1' : '0', REMOVE_EXIT: options.removeFail ? '1' : '0',
  }, timeout: 30_000 });
  assert.equal(result.status, 0, result.stderr.toString());
  assert.match(readFileSync(join(dir, 'launchctl.calls'), 'utf8'), /remove ai\.tatwo\.tatwo2\.updater\.test/);
  return { dir, result, prefetchedZip, waited: Date.now() - started,
    receipt: JSON.parse(readFileSync(join(dir, options.runID ? options.runID + '.json' : 'result.json'), 'utf8')) };
}

test('helper waits for exit, passes pinned version and prefetched path, and records success', () => {
  const { dir, waited, prefetchedZip, receipt } = run(0, { waitForApp: true });
  assert.ok(waited >= 1500, `helper must wait for the app pid to exit (waited ${waited}ms)`);
  assert.equal(readFileSync(join(dir, 'install.calls'), 'utf8'), `version=v9.9.9\nzip=${prefetchedZip}\n`);
  assert.deepEqual(receipt, { ok: true, tag: 'v9.9.9', message: 'installed', runID: 'test', installSeconds: receipt.installSeconds });
  assert.ok(!existsSync(join(dir, 'open.calls')), 'installer opens the new app itself');
});

test('W20 helper passes both quoted layer paths and leaves runtime empty when reused', () => {
  for (const runtimeZip of ['', "/tmp/runtime cache's/TATWO-OS-runtime-123456789abc.zip"]) {
    const appZip = "/tmp/app cache's/TATWO-OS-app.zip";
    const { dir } = run(0, { appZip, runtimeZip });
    assert.equal(readFileSync(join(dir, 'layers.calls'), 'utf8'), `app=${appZip}\nruntime=${runtimeZip}\n`);
  }
  assert.match(updater, /prefetchedAppZip: zip\.appZip\?\.path \?\? ""/);
  assert.match(updater, /prefetchedRuntimeZip: zip\.runtimeZip\?\.path \?\? ""/);
});

test('W20 prefetch plans only needed layers and aggregates byte offsets', () => {
  assert.match(updater, /try asset\(split \? "TATWO-OS-app.zip" : "TATWO-OS.zip"\)/);
  assert.match(updater, /if !useDelta, !runtimeReusable, let runtime \{ archives\.append\(runtime\) \}/);
  assert.match(updater, /runtimes\.count == 1/);
  assert.match(updater, /archives\.reduce\(Int64\(0\)\)/);
  assert.match(updater, /for archive in archives/);
  assert.match(updater, /let checksum = try asset\(archive\.name \+ ".sha256"\)/);
  assert.match(updater, /recordDownloadProgress\(offset \+ written, total: max\(plannedBytes/);
});

test('W20 production runtime reuse decision: hash, missing paths, old apps and unsafe metadata',
  { skip: process.platform !== 'darwin' }, () => {
    const dir = mkdtempSync(join(tmpdir(), 'w20-decision-'));
    const source = updater.slice(updater.indexOf('private struct UpdateRuntimeLayer:'),
      updater.indexOf('@MainActor\nfinal class InAppUpdater'));
    const swift = join(dir, 'Decision.swift'), binary = join(dir, 'decision');
    writeFileSync(swift, `import Foundation\n${source}
let reuse = UpdateRuntimeLayer.canReuse(contents: URL(fileURLWithPath: CommandLine.arguments[1]),
                                       archiveName: CommandLine.arguments[2])
precondition(UpdateDelta.name(installed: "2.0.5", tag: "v2.0.6") == "TATWO-OS-delta-v2.0.5-v2.0.6.zip")
for old in [nil, "v2.0.6", "../bad"] { precondition(UpdateDelta.name(installed: old, tag: "v2.0.6") == nil) }
for size: Int64 in [-1, 0, 25, 99, 100, 101] {
    precondition(!UpdateDelta.reasonable(size, appSize: 100, runtimeReusable: false))
}
precondition(UpdateDelta.reasonable(24, appSize: 100, runtimeReusable: false))
precondition(!UpdateDelta.reasonable(1, appSize: 100, runtimeReusable: true))
precondition(!UpdateDelta.reasonable(1, appSize: 0, runtimeReusable: false))
precondition(!UpdateDelta.reasonable(Int64.max, appSize: Int64.max, runtimeReusable: false))
print(reuse ? "reuse" : "download")
`);
    const compile = spawnSync('swiftc', [swift, '-o', binary], { encoding: 'utf8', timeout: 60_000 });
    assert.equal(compile.status, 0, compile.stderr);
    const contents = join(dir, 'Contents'), resources = join(contents, 'Resources');
    mkdirSync(join(resources, 'runtime'), { recursive: true });
    const sha = 'a'.repeat(64), name = `TATWO-OS-runtime-${sha.slice(0, 12)}.zip`;
    const decide = archive => spawnSync(binary, [contents, archive], { encoding: 'utf8' }).stdout.trim();
    assert.equal(decide(name), 'download');
    const manifest = data => writeFileSync(join(resources, 'runtime-layer.json'), JSON.stringify(data));
    manifest({ sha, paths: ['Resources/runtime'] });
    assert.equal(decide(name), 'reuse');
    assert.equal(decide('TATWO-OS-runtime-bbbbbbbbbbbb.zip'), 'download');
    for (const paths of [[], ['Resources/missing'], ['Resources/../runtime'], ['/tmp'], ['Resources//runtime']]) {
      manifest({ sha, paths }); assert.equal(decide(name), 'download');
    }
    manifest({ sha: 'invalid', paths: ['Resources/runtime'] });
    assert.equal(decide(name), 'download');
  });

test('W23 source guards: durable resume, offset, cancellable unbounded backoff and release-scoped copy', () => {
  assert.match(updater, /appendingPathExtension\("resume"\)/);
  assert.match(updater, /Data\(contentsOf: resumeURL\)/);
  assert.match(updater, /data\.write\(to: resumeURL, options: \.atomic\)/);
  assert.match(updater, /userInfo\[NSURLSessionDownloadTaskResumeData\]/);
  assert.match(updater, /downloadTask\(withResumeData:/);
  assert.match(updater, /cancel\(byProducingResumeData:[\s\S]*saveResume\(data\)/);
  assert.match(updater, /didResumeAtOffset fileOffset:[\s\S]*rebase\(fileOffset, expectedTotalBytes\)/);
  assert.match(updater, /var delay = 2[\s\S]*while true[\s\S]*Task\.checkCancellation/);
  assert.match(updater, /min\(60, seconds \* 2\)/);
  for (const code of ['networkConnectionLost', 'timedOut', 'cannotConnectToHost', 'notConnectedToInternet', 'secureConnectionFailed']) {
    assert.ok(updater.includes(`.${code}`));
  }
  assert.match(updater, /error\.domain == "UpdaterHTTP" && \(500\.\.\.599\)\.contains\(error\.code\)/);
  assert.match(updater, /連線中斷，%d 秒後自動續傳（已下載 %\.1f MB）/);
  assert.match(updater, /downloadedBytes = resumableBytes\(for: tag\)/);
  assert.match(updater, /已暫停準備/);
  const peer = readFileSync(new URL('../App/Sources/Tatwo2/Facade/PeerUpdateSource.swift', import.meta.url), 'utf8');
  assert.match(peer, /"--partial", "--inplace"/);
  assert.match(peer, /SHA256\.hash[\s\S]*appendingPathComponent\("peer-\\\(key\)"/);
});

test('W23 real HTTP: server restart, disk resume across processes, SHA and retry policy',
  { skip: process.platform !== 'darwin', timeout: 120_000 }, async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tatwo-w23-http-'));
    const delegate = updater.slice(updater.indexOf('private final class UpdateDownloadProgress'),
      updater.indexOf('private struct UpdateRuntimeLayer:'));
    const retry = updater.slice(updater.indexOf('    private func retryDownload'),
      updater.indexOf('    private func helperIsActive')).replace('private func', 'func');
    const resumeBytes = updater.slice(updater.indexOf('    func resumableBytes'),
      updater.indexOf('    private func retryDownload'));
    const bytes = Buffer.alloc(2_097_152);
    for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 31 + 7) % 251;
    const sha = createHash('sha256').update(bytes).digest('hex');
    const swift = join(dir, 'ResumeProbe.swift'), binary = join(dir, 'resume-probe');
    writeFileSync(swift, `
import Foundation
import CryptoKit
${delegate}
@MainActor enum GitHubReleaseUpdateChecker { static let shared = GitHubReleaseUpdateCheckerValue() }
struct GitHubReleaseUpdateCheckerValue { let repository = "fixture/repo" }
enum PeerUpdateSource { static func validTag(_ tag: String) -> Bool { tag == "v9.9.9" || tag == "v9.9.8" } }
@MainActor final class Probe {
    let fileManager = FileManager.default
    let directory: URL
    var downloadedBytes: Int64 = 0
    var downloadBytesPerSecond: Double = 0
    var speedSamples: [(time: TimeInterval, bytes: Int64)] = []
    var downloadSource = "GitHub"
    init(_ directory: URL) { self.directory = directory }
${retry}
${resumeBytes}
}
@main struct Main {
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[3])
        let folder = root.appendingPathComponent("download/fixture/repo/v9.9.9")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("TATWO-OS.zip")
        let probe = Probe(root)
        var delay = 2, sequence: [Int] = []
        for _ in 0..<8 { sequence.append(delay); delay = UpdateDownloadProgress.nextDelay(delay) }
        precondition(sequence == [2, 4, 8, 16, 32, 60, 60, 60])
        for code in [URLError.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet, .secureConnectionFailed] {
            precondition(UpdateDownloadProgress.retryable(URLError(code)))
        }
        for status in [500, 503, 599] {
            precondition(UpdateDownloadProgress.retryable(NSError(domain: "UpdaterHTTP", code: status)))
        }
        for error in [NSError(domain: "UpdaterHTTP", code: 404), NSError(domain: "Updater", code: 1),
                      URLError(.cancelled) as NSError, URLError(.badURL) as NSError] {
            precondition(!UpdateDownloadProgress.retryable(error))
        }
        if mode == "backoff-cancel" {
            var attempts = 0
            let work = Task { try await probe.retryDownload { attempts += 1; throw URLError(.timedOut) } as Void }
            try await Task.sleep(for: .milliseconds(150)); work.cancel()
            do { try await work.value; preconditionFailure("cancel ignored") } catch is CancellationError {}
            precondition(attempts == 1 && probe.downloadSource.contains("2 秒後自動續傳"))
            print("cancelled backoff"); return
        }
        if mode == "resume" {
            let saved = probe.resumableBytes(for: "v9.9.9") ?? 0
            precondition(saved > 0)
            precondition(probe.resumableBytes(for: "v9.9.8") == nil)
            let peer = folder.appendingPathComponent("peer-fixture")
            try FileManager.default.createDirectory(at: peer.appendingPathComponent("runtime"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: peer.appendingPathComponent("TATWO-OS.zip"))
            try Data(repeating: 1, count: 100).write(to: peer.appendingPathComponent("runtime/ignored.zip"))
            try Data(repeating: 1, count: 100).write(to: folder.appendingPathComponent("invalid-fixture.zip"))
            precondition(probe.resumableBytes(for: "v9.9.9") == saved) // No double count or quarantined data.
        }
        var attempts = 0
        let work = Task {
            try await probe.retryDownload {
                attempts += 1
                let progress = UpdateDownloadProgress(destination: destination, rebase: { offset, _ in
                    print("resumed=\\(offset)")
                }) { written, _ in Task { @MainActor in probe.downloadedBytes = written } }
                return try await progress.download(from: URL(string: CommandLine.arguments[2])!)
            }
        }
        if mode == "cancel" {
            try await Task.sleep(for: .milliseconds(450)); work.cancel()
            do { _ = try await work.value; preconditionFailure("cancel ignored") } catch {}
            let data = try Data(contentsOf: destination.appendingPathExtension("resume"))
            precondition(!data.isEmpty && (probe.resumableBytes(for: "v9.9.9") ?? 0) > 0)
            print("cancel saved resume"); return
        }
        if mode == "denied" {
            do { _ = try await work.value; preconditionFailure("403 accepted") }
            catch { precondition((error as NSError).domain == "UpdaterHTTP" && (error as NSError).code == 403) }
            let retired = try Data(contentsOf: destination.appendingPathExtension("resume"))
            precondition(retired.isEmpty && attempts == 1)
            print("403 did not retry; stale resume retired"); return
        }
        let result = try await work.value
        for _ in 0..<10 { await Task.yield() }
        precondition(probe.downloadedBytes == 2_097_152)
        let actual = SHA256.hash(data: try Data(contentsOf: result)).map { String(format: "%02x", $0) }.joined()
        precondition(actual == CommandLine.arguments[4])
        let retired = try Data(contentsOf: destination.appendingPathExtension("resume"))
        precondition(retired.isEmpty)
        if mode == "restart" || mode == "http503" { precondition(attempts == 2) }
        print("sha verified; attempts=\\(attempts)")
    }
}
`);
    const compile = spawnSync('swiftc', ['-swift-version', '6', '-parse-as-library', swift, '-o', binary],
      { encoding: 'utf8', timeout: 60_000 });
    assert.equal(compile.status, 0, compile.stderr);
    const ranges = [], requests = new Map();
    let port, reopen;
    const server = createServer((request, response) => {
      const count = (requests.get(request.url) ?? 0) + 1; requests.set(request.url, count);
      const start = Number(request.headers.range?.match(/bytes=(\d+)-/)?.[1] ?? 0);
      if (request.headers.range) ranges.push({ path: request.url, start });
      if (request.url === '/http503' && count === 1) { response.writeHead(503); response.end(); return; }
      if (request.url === '/expired' && count === 2) { response.writeHead(403); response.end(); return; }
      if (request.url === '/expired' && count === 3) assert.equal(request.headers.range, undefined);
      response.writeHead(start ? 206 : 200, {
        'Content-Length': bytes.length - start, 'Accept-Ranges': 'bytes', ETag: '"fixture-w23"',
        'Last-Modified': 'Fri, 11 Sep 2026 00:00:00 GMT',
        ...(start ? { 'Content-Range': `bytes ${start}-${bytes.length - 1}/${bytes.length}` } : {}),
      });
      let offset = start;
      const timer = setInterval(() => {
        const end = Math.min(offset + 65_536, bytes.length);
        response.write(bytes.subarray(offset, end)); offset = end;
        if (request.url === '/restart' && count === 1 && offset >= 524_288) {
          clearInterval(timer); server.closeAllConnections();
          server.close(() => { reopen = setTimeout(() => server.listen(port, '127.0.0.1'), 400); });
        } else if (offset === bytes.length) { clearInterval(timer); response.end(); }
      }, 50);
      response.on('close', () => clearInterval(timer));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    port = server.address().port;
    const runProbe = async (mode, path, root) => {
      const result = await new Promise((resolve, reject) => {
        const child = spawn(binary, [mode, `http://127.0.0.1:${port}/${path}`, root, sha], { timeout: 20_000 });
        let stdout = '', stderr = '';
        child.stdout.on('data', data => { stdout += data; });
        child.stderr.on('data', data => { stderr += data; });
        child.on('error', reject);
        child.on('close', code => resolve({ code, stdout, stderr }));
      });
      assert.equal(result.code, 0, `${mode}: ${result.stdout}\n${result.stderr}`);
      console.log(`${mode}: ${result.stdout.trim()}`);
      return result.stdout;
    };
    try {
      await runProbe('backoff-cancel', 'unused', join(dir, 'backoff'));
      await runProbe('restart', 'restart', join(dir, 'restart'));
      assert.ok(ranges.some(r => r.path === '/restart' && r.start > 0), 'restart must request remaining bytes');
      await runProbe('http503', 'http503', join(dir, 'http503'));
      await runProbe('cancel', 'persistent', join(dir, 'persistent'));
      await runProbe('resume', 'persistent', join(dir, 'persistent'));
      assert.ok(ranges.some(r => r.path === '/persistent' && r.start > 0), 'new process must resume from disk');
      await runProbe('cancel', 'expired', join(dir, 'expired'));
      await runProbe('denied', 'expired', join(dir, 'expired'));
      assert.ok(ranges.some(r => r.path === '/expired' && r.start > 0), '403 must exercise a resumed request');
      await runProbe('fresh', 'expired', join(dir, 'expired'));
    } finally {
      clearTimeout(reopen); server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    }
  });

test('failure reopens only a stopped App and exits zero even if launchctl removal fails', () => {
  const { dir, receipt } = run(3, { removeFail: true });
  assert.deepEqual(receipt, { ok: false, tag: 'v9.9.9', message: 'install_failed_exit_3', runID: 'test', installSeconds: receipt.installSeconds });
  assert.match(readFileSync(join(dir, 'open.calls'), 'utf8'), /TATWO OS\.app/);
  const restarted = run(3, { relaunchDuring: true });
  assert.equal(restarted.receipt.message, 'install_failed_exit_3');
  assert.ok(!existsSync(join(restarted.dir, 'open.calls')));
});

for (const relaunchAt of [1, 2]) {
  test(`relaunch at pgrep check ${relaunchAt} prevents install and open`, () => {
    const { dir, receipt } = run(0, { relaunchAt, fetchScript: true });
    assert.equal(receipt.message, 'app_relaunched');
    assert.ok(!existsSync(join(dir, 'install.calls')));
    assert.ok(!existsSync(join(dir, 'open.calls')));
  });
}

test('real suffix-free mktemp succeeds twice in the same TMPDIR', () => {
  const { dir } = run(0, { fetchScript: true });
  run(0, { dir, fetchScript: true, runID: 'second' });
  const paths = readFileSync(join(dir, 'curl.calls'), 'utf8').trim().split('\n');
  assert.equal(new Set(paths).size, 2);
  for (const path of paths) {
    assert.match(path, /tatwo-install\.[A-Za-z0-9]{6}$/);
    assert.ok(existsSync(path));
  }
});

test('timeout, mktemp failure and curl failure finish without restart loops', () => {
  const waiting = run(0, { stillRunning: true });
  assert.equal(waiting.receipt.message, 'app_still_running');
  assert.ok(!existsSync(join(waiting.dir, 'open.calls')));
  assert.ok(!existsSync(join(waiting.dir, 'install.calls')));
  for (const options of [{ mktempFail: true }, { curlFail: true }, { curlFail: true, relaunchAt: 2 }]) {
    const { dir, receipt } = run(0, { fetchScript: true, ...options });
    assert.equal(receipt.message, 'download_install_script_failed');
    assert.equal(existsSync(join(dir, 'open.calls')), !options.relaunchAt);
    assert.ok(!existsSync(join(dir, 'install.calls')));
  }
});

test('source guards: progress, guarded action, verified cache, active helper, zero exits', () => {
  assert.match(card, /updater\.updateMarkTitle/);
  assert.match(updater, /Double\(downloadedBytes\)/);
  assert.match(updater, /Double\(totalBytes\)/);
  assert.match(card, /\.disabled\(updater\.updateMarkDisabled\)/);
  assert.match(updater, /await IslandNotice.shared.confirm/);
  assert.match(updater, /progress\.download\(/);
  assert.match(updater, /SHA256\(\)/);
  assert.match(updater, /fileExists\(atPath: zip\.path\)/);
  assert.match(updater, /Self\.digest\(zip\) == expected\.lowercased\(\)/);
  assert.match(updater, /process\.arguments = \["list", label\]/);
  assert.match(updater, /\["label": label, "tag": tag/);
  assert.match(updater, /guard !helperIsActive\(\)/);
  assert.match(updater, /case "app_relaunched"/);
  const helper = updater.split('// UPDATE-HELPER-BEGIN')[1];
  assert.doesNotMatch(helper, /\bexit (?!0\b)/);
  assert.doesNotMatch(helper, /launchctl remove[^\n]*&\s*$/m);
  assert.doesNotMatch(helper, /tatwo-install\.XXXXXX\.sh/);
});

test('sidebar observes shared update state and retains settings integration', () => {
  const source = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
  assert.match(card, /struct SidebarUpdateShortcut/);
  assert.match(card, /if let release = checker\.availableRelease, !checker\.dismissed/);
  assert.match(card, /updater\.updateMarkTitle/);
  assert.match(card, /updater\.activateUpdateMark/);
  assert.match(source('Chat/ChatPage+Sidebar.swift'), /SidebarUpdateShortcut \{\s*updateSettingsSection = \.github/);
  assert.match(source('Chat/ChatPage+Panels.swift'), /TatwoSettingsPage\(model: model, initialSection: updateSettingsSection\)/);
  assert.match(source('Shell/ChatPageSettings.swift'), /if let initialSection \{ section = initialSection \}/);
  assert.match(source('Chat/ChatPage.swift'), /\.overlay \{\s*if showSettingsPage \{\s*tatwoSettingsOverlay/);
  assert.match(source('Chat/ChatPage+Panels.swift'), /\.contentShape\(Rectangle\(\)\)\s*\.onTapGesture \{\s*withAnimation[^\n]*showSettingsPage = false/);
});

test('relaunch checks use the packaged executable name, not the SwiftPM product name', () => {
  const packaging = readFileSync(new URL('../scripts/build-app.sh', import.meta.url), 'utf8');
  assert.match(packaging, /cp "\$BIN_PATH\/Tatwo2" "\$CONTENTS\/MacOS\/tatwo2"/);
  assert.match(packaging, /<key>CFBundleExecutable<\/key><string>tatwo2<\/string>/);
  assert.match(updater, /pgrep -x tatwo2/);
});

test('W19 source guards: session delegate, synchronous move, polling, monotonic progress and speed copy', () => {
  assert.match(updater, /URLSession\(configuration: \.ephemeral, delegate: self, delegateQueue: nil\)/);
  assert.match(updater, /session\.downloadTask\(with: request\)/);
  assert.match(updater, /withCheckedThrowingContinuation/);
  assert.match(updater, /task\.cancel\(byProducingResumeData:/);
  const finish = updater.slice(updater.indexOf('didFinishDownloadingTo location:'),
    updater.indexOf('didCompleteWithError error:'));
  assert.match(finish, /try FileManager\.default\.moveItem\(at: location, to: destination\)/);
  assert.doesNotMatch(finish, /Task\s*\{|async|DispatchQueue/);
  assert.match(updater, /report\(task\.countOfBytesReceived, task\.countOfBytesExpectedToReceive\)/);
  assert.match(updater, /Task\.sleep\(for: \.milliseconds\(500\)\)/);
  assert.match(updater, /polling\.cancel\(\)/);
  assert.match(updater, /downloadedBytes = max\(downloadedBytes, written\)/);
  assert.match(updater, /totalBytes = max\(totalBytes, total\)/);
  assert.match(updater, /speedSamples\.removeAll \{ \$0\.time < now - 5 \}/);
  assert.match(updater, /Double\(downloadedBytes - first\.bytes\) \/ \(now - first\.time\)/);
  assert.match(updater, /正在準備 %@（%\.1f \/ %\.1f MB）/);
});

test('W19 real HTTP download: progress changes, polling fallback, unknown length, cancellation and errors',
  { skip: process.platform !== 'darwin', timeout: 120_000 }, async () => {
    const dir = mkdtempSync(join(tmpdir(), 'tatwo-w19-http-'));
    // Compile the production delegate and reducer, not an alternate download implementation.
    const delegate = updater.slice(updater.indexOf('private final class UpdateDownloadProgress'),
      updater.indexOf('@MainActor\nfinal class InAppUpdater'))
      .replace('report(totalBytesWritten, totalBytesExpectedToWrite)',
        'if CommandLine.arguments[1] != "poll" { report(totalBytesWritten, totalBytesExpectedToWrite) }');
    const reducer = updater.slice(updater.indexOf('    private func recordDownloadProgress'),
      updater.indexOf('    private nonisolated static func digest'))
      .replace('private func', 'func');
    const harness = `
import Foundation
${delegate}
@MainActor final class Probe {
    var downloadedBytes: Int64 = 0, totalBytes: Int64 = 0
    var downloadProgress: Double?
    var downloadBytesPerSecond: Double = 0
    var speedSamples: [(time: TimeInterval, bytes: Int64)] = []
    var intermediate: Set<Int64> = []
${reducer}
}
@main struct Main {
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments[1]
        let probe = Probe()
        probe.recordDownloadProgress(100, total: 1000, now: 0)
        probe.recordDownloadProgress(300, total: 500, now: 2)
        precondition(probe.downloadBytesPerSecond == 100)
        probe.recordDownloadProgress(200, total: -1, now: 3)
        precondition(probe.downloadedBytes == 300 && probe.totalBytes == 1000)
        probe.recordDownloadProgress(700, total: 1000, now: 7)
        precondition(probe.downloadBytesPerSecond == 80) // Only samples in the last five seconds.
        probe.downloadedBytes = 12_300_000; probe.totalBytes = 466_400_000
        probe.downloadBytesPerSecond = 115_000
        probe.totalBytes = 0
        probe.downloadedBytes = 0; probe.totalBytes = 0; probe.speedSamples = []
        let destination = URL(fileURLWithPath: CommandLine.arguments[3])
        let progress = UpdateDownloadProgress(destination: destination) { written, total in
            Task { @MainActor in
                probe.recordDownloadProgress(written, total: total)
                if written > 0 && written < 2_097_152 { probe.intermediate.insert(probe.downloadedBytes) }
            }
        }
        let work = Task {
            if mode == "precancel" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return try await progress.download(from: URL(string: CommandLine.arguments[2])!)
        }
        if mode == "cancel" {
            try await Task.sleep(for: .milliseconds(750))
            work.cancel()
        }
        do {
            let result = try await work.value
            for _ in 0..<10 { await Task.yield() }
            precondition(["normal", "poll", "unknown"].contains(mode))
            let bytes = try Data(contentsOf: result)
            precondition(bytes.count == 2_097_152)
            precondition(probe.downloadedBytes == 2_097_152)
            precondition(probe.intermediate.count >= 2)
            precondition(probe.downloadBytesPerSecond > 0)
            if mode == "unknown" { precondition(probe.totalBytes == 0 && probe.downloadProgress == nil) }
            else { precondition(probe.downloadProgress == 1) }
            print("\\(mode): bytes=\\(probe.downloadedBytes), intermediate=\\(probe.intermediate.count)")
        } catch {
            precondition(["cancel", "precancel", "http", "move"].contains(mode), "\\(error)")
            if mode == "cancel" || mode == "precancel" {
                precondition(error is CancellationError || (error as? URLError)?.code == .cancelled)
                try await Task.sleep(for: .milliseconds(600)) // Let late delegate callbacks drain.
            }
            if mode != "move" { precondition(!FileManager.default.fileExists(atPath: destination.path)) }
            print("\\(mode): expected failure \\(error)")
        }
    }
}
`;
    const swift = join(dir, 'DownloadProbe.swift');
    writeFileSync(swift, harness);
    const binary = join(dir, 'probe');
    const compile = spawnSync('swiftc', ['-swift-version', '6', '-parse-as-library', swift, '-o', binary],
      { encoding: 'utf8', timeout: 60_000 });
    assert.equal(compile.status, 0, compile.stderr);
    const server = createServer((request, response) => {
      const unknown = request.url === '/unknown';
      response.writeHead(request.url === '/http' ? 503 : 200,
        unknown ? {} : { 'Content-Length': 2_097_152 });
      let chunks = 0;
      const timer = setInterval(() => {
        response.write(Buffer.alloc(65_536, 120));
        if (++chunks === 32) { clearInterval(timer); response.end(); }
      }, 100);
      response.on('close', () => clearInterval(timer));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    try {
      const base = `http://127.0.0.1:${server.address().port}`;
      for (const mode of ['normal', 'poll', 'unknown', 'cancel', 'precancel', 'http', 'move']) {
        const destination = join(dir, `${mode}.zip`);
        if (mode === 'move') writeFileSync(destination, 'keep existing destination');
        const result = await new Promise((resolve, reject) => {
          const child = spawn(binary, [mode, `${base}/${mode}`, destination], { timeout: 15_000 });
          let stdout = '', stderr = '';
          child.stdout.on('data', data => { stdout += data; });
          child.stderr.on('data', data => { stderr += data; });
          child.on('error', reject);
          child.on('close', code => resolve({ code, stdout, stderr }));
        });
        assert.equal(result.code, 0, `${mode}: ${result.stdout}\n${result.stderr}`);
        console.log(result.stdout.trim());
        if (mode === 'move') assert.equal(readFileSync(destination, 'utf8'), 'keep existing destination');
      }
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    }
  });

test('W26 terminal helper receipt is idempotent; two run IDs never overwrite each other', () => {
  const first = run(0);
  run(3, {dir:first.dir}); // Simulated launchd rerun of the same run: installer must not execute again.
  assert.equal(readFileSync(join(first.dir,'install.calls'),'utf8').split('version=').length-1,1);
  assert.equal(JSON.parse(readFileSync(join(first.dir,'result.json'))).ok,true);
  const second = run(3,{dir:first.dir,runID:'second'});
  assert.equal(second.receipt.runID,'second'); assert.equal(second.receipt.ok,false);
  assert.equal(JSON.parse(readFileSync(join(first.dir,'result.json'))).ok,true);
  assert.match(updater,/update-\\\(runID\)\.sh/);
  assert.match(updater,/results\/\\\(runID\)\.json/);
  assert.match(updater,/flock\(descriptor, LOCK_EX \| LOCK_NB\)/);
});

test('W26 actual Swift run liveness removes stale labels and acknowledges newest result by UUID', () => {
  const dir=mkdtempSync(join(tmpdir(),'w26-runs-'));
  // Real strict-valid synthetic restore baseline (ad-hoc is allowed for recovery).
  const old=join(dir,'Applications/TATWO OS.app.old'); mkdirSync(join(old,'Contents/MacOS'),{recursive:true});
  writeFileSync(join(old,'Contents/Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2</string><key>CFBundleExecutable</key><string>fixture</string></dict></plist>');
  assert.equal(spawnSync('cp',['/usr/bin/true',join(old,'Contents/MacOS/fixture')]).status,0);
  assert.equal(spawnSync('codesign',['--force','--sign','-',old]).status,0);
  const reconcile=updater.slice(updater.indexOf('    static func reconcileOnLaunch('),updater.indexOf('    private func records('));
  const records=updater.slice(updater.indexOf('    private func records('),updater.indexOf('    static func installScriptURL'));
  const active=updater.slice(updater.indexOf('    private func helperIsActive('),updater.indexOf('    private func prefetch(')).replace('private func','func');
  const consume=updater.slice(updater.indexOf('    func consumeResultOnLaunch()'),updater.indexOf('    static func describe('));
  const script=join(dir,'launchctl');
  writeFileSync(script,`#!/bin/bash
if [ "$1" = list ]; then
 case "$(cat '${dir}/state')" in
 running) echo '\"PID\" = 12345;'; exit 0;;
 absent) exit 113;;
 *) echo '\"LastExitStatus\" = 0;'; exit 0;;
 esac
fi
echo "$*" >> '${dir}/removed'
[ "$(cat '${dir}/state')" != remove-fails ]
`,{mode:0o755});
  writeFileSync(join(dir,'probe.swift'),`
import Foundation
import Darwin
@MainActor enum PeerUpdateSource { static func publishInstalled(_ u: URL) async {} }
@MainActor final class Probe {
 let fileManager=FileManager.default
 let directory=URL(fileURLWithPath:${JSON.stringify(dir)})
 var lastResult: String?
 static let destinationApp="/fixture/not-used"
 ${reconcile}
 ${records}
 ${active.replace('launchctl: String = "/bin/launchctl"',`launchctl: String = ${JSON.stringify(script)}`)}
 ${consume}
 static func describe(_ message: String) -> String { message }
}
@main struct Main {
 @MainActor static func main() throws {
 let p=Probe(), fm=FileManager.default
 let parent=p.directory.appendingPathComponent("Applications"), dest=parent.appendingPathComponent("TATWO OS.app")
 let stage=parent.appendingPathComponent(".tatwo-update.fixture.noindex")
 try fm.createDirectory(at:stage,withIntermediateDirectories:true)
 try fm.createDirectory(atPath:dest.path+".old",withIntermediateDirectories:true)
 try JSONSerialization.data(withJSONObject:["owner":"99999999","phase":"replacing","backup":dest.path+".old"])
   .write(to:stage.appendingPathComponent("transaction.json"))
 Probe.reconcileOnLaunch(destination:dest.path)
 precondition(fm.fileExists(atPath:dest.path))
 precondition(!fm.fileExists(atPath:parent.appendingPathComponent(".tatwo-update.lock").path))
 precondition(!(try! fm.contentsOfDirectory(atPath:parent.path)).contains(where: { $0.hasPrefix(".tatwo-lock-retained.") }))
 precondition(fm.fileExists(atPath:stage.appendingPathComponent("result.json").path))
 let before=try fm.contentsOfDirectory(atPath:parent.path).sorted()
 Probe.reconcileOnLaunch(destination:dest.path)
 let after=try fm.contentsOfDirectory(atPath:parent.path).sorted(); precondition(before==after)
 for name in ["runs","results","acks"] { try fm.createDirectory(at:p.directory.appendingPathComponent(name),withIntermediateDirectories:true) }
 let id=UUID().uuidString
 let record=p.directory.appendingPathComponent("runs/\\(id).json")
 try JSONSerialization.data(withJSONObject:["runID":id,"label":"ai.tatwo.tatwo2.updater."+id,"tag":"v2.0.6"]).write(to:record)
 func state(_ s:String) throws { try s.write(to:p.directory.appendingPathComponent("state"),atomically:true,encoding:.utf8) }
 try Data("broken-json".utf8).write(to:record)
 try state("running"); precondition(p.helperIsActive())
 try state("remove-fails"); precondition(p.helperIsActive())
 try state("stale"); precondition(!p.helperIsActive())
 let result=p.directory.appendingPathComponent("results/\\(id).json")
 let data=try Data(contentsOf:result)
 var pending = ["runID":id,"label":"ai.tatwo.tatwo2.updater."+id,"tag":"v2.0.6", "state":"submitted", "submittedAt":String(Date().timeIntervalSince1970)]
 try JSONSerialization.data(withJSONObject:pending).write(to:record)
 try state("absent"); precondition(p.helperIsActive())
 pending["submittedAt"]="0"; try JSONSerialization.data(withJSONObject:pending).write(to:record)
 precondition(!p.helperIsActive())
 precondition(String(decoding:data,as:UTF8.self).contains("helper_exited_abnormally"))
 try state("absent"); p.consumeResultOnLaunch()
 precondition(fm.fileExists(atPath:p.directory.appendingPathComponent("acks/\\(id).ack").path))
 precondition(try Data(contentsOf:result)==data)
 print("stale label + run result + ack PASS")
 }
}
`.replace('precondition(try Data(contentsOf:result)==data)','let retained=try Data(contentsOf:result); precondition(retained==data)'));
  let r=spawnSync('swiftc',['-parse-as-library','-num-threads','2',join(dir,'probe.swift'),'-o',join(dir,'probe')],{encoding:'utf8',timeout:120000});
  assert.equal(r.status,0,r.stderr);
  r=spawnSync(join(dir,'probe'),[],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
  assert.match(readFileSync(join(dir,'removed'),'utf8'),/remove ai\.tatwo\.tatwo2\.updater\./);
});

test('W26 helper abnormal TERM writes a terminal failure instead of restart installation', () => {
  const dir=mkdtempSync(join(tmpdir(),'w26-helper-term-'));
  const destination=join(dir,'App'); mkdirSync(destination);
  const result=join(dir,'receipt.json');
  let body=renderHelper({pid:99999999,resultPath:result,logPath:join(dir,'log'),destination,
    label:'ai.tatwo.tatwo2.updater.test',prefetchedZip:''});
  // Signal the real rendered helper immediately after trap installation; no system launchd access.
  body=body.replace('trap abnormal_exit EXIT INT TERM',() => 'trap abnormal_exit EXIT INT TERM\nkill -TERM $$');
  body=body.replaceAll('launchctl remove "$LABEL" >/dev/null 2>&1',':');
  const r=spawnSync('bash',['-c',body],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);
  assert.equal(JSON.parse(readFileSync(result)).message,'helper_exited_abnormally');
});

test('W24 helper polls 0.2 seconds with unchanged total wait and emits installSeconds', () => {
  assert.match(updater, /WAIT=\$\(\(\\\(helperWaitSeconds\) \* 5\)\)/);
  assert.match(updater, /do sleep 0\.2; i=\$\(\(i \+ 1\)\)/);
  const result = run(0);
  const receipt = JSON.parse(readFileSync(join(result.dir, 'result.json'), 'utf8'));
  assert.equal(receipt.ok, true);
  assert.ok(Number.isInteger(receipt.installSeconds) && receipt.installSeconds >= 0);
});

test('W31 helper passes prepared delta/layered route unchanged to the installer', () => {
  for (const route of ['delta', 'layered']) {
    const result = run(0, { route });
    assert.equal(readFileSync(join(result.dir, 'route.calls'), 'utf8').trim(), route);
  }
});

test('W42 production mark and action fixture: intent, integer %, false/true confirm, stale candidate and duplicate taps', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w42-mark-'));
  const title = updater.slice(updater.indexOf('enum UpdateMarkState'));
  const phase = updater.slice(updater.indexOf('    enum Phase:'), updater.indexOf('    static let shared'));
  const action = updater.slice(updater.indexOf('    var updateMarkTitle:'), updater.indexOf('    private func checkSpace'));
  const swift = `import Foundation
${title}
@MainActor final class IslandNotice {
 static let shared = IslandNotice()
 var calls = 0, answer = false
 func confirm(title: String, detail: String, confirmLabel: String, cancelLabel: String) async -> Bool {
  precondition(title == "重新啟動 TATWO OS 以完成更新？")
  precondition(detail == "會關閉目前所有工作，約 10 秒後自動重開")
  precondition(confirmLabel == "重開" && cancelLabel == "稍後")
  calls += 1; return answer
 }
}
@MainActor final class InAppUpdater {
${phase}
 var phase = Phase.idle, userStarted = false, confirmingRestart = false
 var downloadProgress: Double?, downloadID = UUID()
 var downloads = 0, updates = 0
 func prefetch(to: String, repository: String, force: Bool) {
  precondition(force); userStarted = false; downloads += 1; phase = .starting
 }
 func update(to: String, repository: String) { precondition(phase == .ready); updates += 1 }
${action}
}
@main struct Main {
 @MainActor static func main() async {
  let p = InAppUpdater(), repo = "fixture/repo", tag = "v2.0.7"
  for phase: InAppUpdater.Phase in [.idle, .starting, .ready] {
   precondition(UpdateMarkState.title(phase:phase, progress:0.76, userStarted:false) == "更新")
  }
  for percent in 0...100 {
   let progress = (Double(percent) + 0.1) / 100
   precondition(UpdateMarkState.title(phase:.starting, progress:progress, userStarted:true) == "下載中 \\(percent)%")
  }
  for progress: Double? in [nil, .nan, .infinity, -.infinity, -0.1] {
   precondition(UpdateMarkState.title(phase:.starting, progress:progress, userStarted:true) == "下載中 0%")
  }
  precondition(UpdateMarkState.title(phase:.starting, progress:1.5, userStarted:true) == "下載中 100%")
  precondition(UpdateMarkState.title(phase:.ready, progress:1, userStarted:true) == "重開")
  precondition(UpdateMarkState.title(phase:.failed("offline"), progress:nil, userStarted:false) == "更新失敗")
  await p.activateUpdateMark(to:tag, repository:repo)
  precondition(p.downloads == 1 && p.updates == 0 && p.updateMarkTitle == "下載中 0%")
  await p.activateUpdateMark(to:tag, repository:repo)
  precondition(p.downloads == 1 && p.updates == 0 && p.updateMarkDisabled)
  p.phase = .ready
  await p.activateUpdateMark(to:tag, repository:repo, confirm: { false })
  precondition(p.updates == 0 && p.updateMarkTitle == "重開" && !p.confirmingRestart)
  await p.activateUpdateMark(to:tag, repository:repo) // Real adapter, fake Island rejects.
  precondition(IslandNotice.shared.calls == 1 && p.updates == 0)
  await p.activateUpdateMark(to:tag, repository:repo, confirm: {
   await p.activateUpdateMark(to:tag, repository:repo, confirm: { preconditionFailure("duplicate prompt") })
   return true
  })
  precondition(p.updates == 1)
  await p.activateUpdateMark(to:tag, repository:repo, confirm: { p.downloadID = UUID(); return true })
  precondition(p.updates == 1)
  p.userStarted = false // A prefetched candidate still requires two separate taps.
  await p.activateUpdateMark(to:tag, repository:repo, confirm: { preconditionFailure("first tap prompted") })
  precondition(p.downloads == 1 && p.updates == 1 && p.updateMarkTitle == "重開")
  IslandNotice.shared.answer = true
  await p.activateUpdateMark(to:tag, repository:repo)
  precondition(p.updates == 2 && IslandNotice.shared.calls == 2)
  p.phase = .failed("offline")
  precondition(p.updateMarkTitle == "更新失敗" && p.updateMarkHelp == "offline" && !p.updateMarkDisabled)
  await p.activateUpdateMark(to:tag, repository:repo)
  precondition(p.downloads == 2 && p.updates == 2 && p.phase == .starting)
  p.phase = .starting; p.userStarted = false // Adopt an ongoing background download.
  await p.activateUpdateMark(to:tag, repository:repo)
  precondition(p.userStarted && p.downloads == 3 && p.updates == 2)
  p.phase = .handedOff
  await p.activateUpdateMark(to:tag, repository:repo)
  precondition(p.downloads == 3 && p.updates == 2)
  print("W42 mark/action PASS")
 }
}`;
  const file = join(dir, 'Mark.swift'), binary = join(dir, 'mark');
  writeFileSync(file, swift);
  let result = spawnSync('swiftc', ['-swift-version', '6', '-parse-as-library', file, '-o', binary], {encoding:'utf8', timeout:60000});
  assert.equal(result.status, 0, result.stderr);
  result = spawnSync(binary, [], {encoding:'utf8', timeout:10000});
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /W42 mark\/action PASS/);
});

test('W42-fix hand-off terminate bypasses the Island terminate confirmation exactly once and progress publishes per 1%', () => {
  const updaterSwift = updater;
  const stubs = readFileSync(new URL('../App/Sources/Tatwo2/Facade/OS1Stubs.swift', import.meta.url), 'utf8');
  const bypassIndex = updaterSwift.indexOf('TatwoInterruptGate.bypassNextTerminate = true');
  const terminateIndex = updaterSwift.indexOf('NSApp.terminate(nil)');
  assert.ok(bypassIndex > 0 && terminateIndex > bypassIndex, 'bypass must be armed right before the hand-off terminate');
  assert.equal((updaterSwift.match(/NSApp\.terminate\(nil\)/g) || []).length, 1);
  assert.match(stubs, /if bypassNextTerminate \{ bypassNextTerminate = false; return \.init\(requiresConfirmation: false\) \}/);
  assert.match(updaterSwift, /if next\.map\(\{ Int\(\$0 \* 100\) \}\) != downloadProgress\.map\(\{ Int\(\$0 \* 100\) \}\)/);
});
