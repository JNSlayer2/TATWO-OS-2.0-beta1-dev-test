import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const updater = readFileSync(new URL('../App/Sources/Tatwo2/Facade/InAppUpdater.swift', import.meta.url), 'utf8');
const card = readFileSync(new URL('../App/Sources/Tatwo2/New/UpdateAvailableCard.swift', import.meta.url), 'utf8');
const stubs = readFileSync(new URL('../App/Sources/Tatwo2/Facade/OS1Stubs.swift', import.meta.url), 'utf8');

test('update card offers a one-click update and keeps the terminal path as an advanced fallback', () => {
  assert.match(card, /Button\(updateButtonTitle\) \{ updater\.update\(to: release\.tag_name\) \}/);
  assert.match(card, /\.buttonStyle\(\.borderedProminent\)/);
  assert.match(card, /DisclosureGroup\("進階：用終端機更新"\)/);
  assert.match(card, /GitHubReleaseUpdateChecker\.installCommand/);
  assert.match(stubs, /InAppUpdater\.shared\.consumeResultOnLaunch\(\)/);
});

test('updater reuses install.sh from the same public repository for signing and replacement after prefetch', () => {
  assert.match(updater, /https:\/\/raw\.githubusercontent\.com\/\\\(repository\)\/main\/install\.sh/);
  assert.match(updater, /\/bin\/launchctl/);
  assert.match(updater, /"submit", "-l", label/);
  assert.match(updater, /NSApp\.terminate\(nil\)/);
  assert.match(updater, /TATWO_OS_VERSION="\$TAG" bash "\$SCRIPT"/);
  assert.doesNotMatch(updater, /codesign|shasum|unzip|spctl/);
  assert.match(updater, /\^v\?\[0-9\]\+\[\.\]\[0-9\]\+/);
});

// 把 Swift 裡的 helper 模板還原成真的 bash 腳本，用假的 install.sh 跑一遍。
function renderHelper({ pid, resultPath, logPath, destination, label, prefetchedZip,
  prefetchedAppZip = '', prefetchedRuntimeZip = '', wait = 10 }) {
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
        resultPath, logPath, destination, label, prefetchedZip, prefetchedAppZip, prefetchedRuntimeZip };
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
    pid, resultPath: join(dir, 'result.json'), logPath: join(dir, 'update.log'),
    destination, prefetchedZip, prefetchedAppZip: options.appZip ?? '', prefetchedRuntimeZip: options.runtimeZip ?? '',
    label: 'ai.tatwo.tatwo2.updater.test', wait: options.stillRunning ? 0 : 10,
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
    receipt: JSON.parse(readFileSync(join(dir, 'result.json'), 'utf8')) };
}

test('helper waits for exit, passes pinned version and prefetched path, and records success', () => {
  const { dir, waited, prefetchedZip, receipt } = run(0, { waitForApp: true });
  assert.ok(waited >= 1500, `helper must wait for the app pid to exit (waited ${waited}ms)`);
  assert.equal(readFileSync(join(dir, 'install.calls'), 'utf8'), `version=v9.9.9\nzip=${prefetchedZip}\n`);
  assert.deepEqual(receipt, { ok: true, tag: 'v9.9.9', message: 'installed' });
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
  assert.match(updater, /if !UpdateRuntimeLayer\.canReuse[\s\S]*archives\.append\(runtime\)/);
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
      updater.indexOf('private struct UpdateArchives'));
    const swift = join(dir, 'Decision.swift'), binary = join(dir, 'decision');
    writeFileSync(swift, `import Foundation\n${source}
let reuse = UpdateRuntimeLayer.canReuse(contents: URL(fileURLWithPath: CommandLine.arguments[1]),
                                       archiveName: CommandLine.arguments[2])
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

test('failure reopens only a stopped App and exits zero even if launchctl removal fails', () => {
  const { dir, receipt } = run(3, { removeFail: true });
  assert.deepEqual(receipt, { ok: false, tag: 'v9.9.9', message: 'install_failed_exit_3' });
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
  run(0, { dir, fetchScript: true });
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

test('source guards: progress, cancel, verified cache, active helper, zero exits', () => {
  assert.match(card, /ProgressView\(value: updater\.downloadProgress\)/);
  assert.match(card, /updater\.downloadedBytes/);
  assert.match(card, /updater\.totalBytes/);
  assert.match(card, /Button\("取消"\) \{ updater\.cancelUpdate\(\) \}/);
  assert.match(card, /return "下載並更新"/);
  assert.match(updater, /progress\.download\(/);
  assert.match(updater, /SHA256\(\)/);
  assert.match(updater, /fileExists\(atPath: zip\.path\)/);
  assert.match(updater, /Self\.digest\(zip\) == expected\.lowercased\(\)/);
  assert.match(updater, /process\.arguments = \["list", label\]/);
  assert.match(updater, /\["label": label, "tag": tag/);
  assert.match(updater, /guard !helperIsActive\(\)/);
  assert.match(updater, /case "app_relaunched"/);
  const helper = updater.split('// UPDATE-HELPER-BEGIN')[1];
  assert.doesNotMatch(helper, /exit (?!0\b)/);
  assert.doesNotMatch(helper, /launchctl remove[^\n]*&\s*$/m);
  assert.doesNotMatch(helper, /tatwo-install\.XXXXXX\.sh/);
});

test('sidebar observes releases/progress and opens the existing GitHub settings card', () => {
  const source = path => readFileSync(new URL(`../App/Sources/Tatwo2/${path}`, import.meta.url), 'utf8');
  assert.match(card, /struct SidebarUpdateShortcut/);
  assert.match(card, /if let release = checker\.availableRelease, !checker\.dismissed/);
  assert.ok(card.includes('有新版 \\(release.tag_name)'));
  assert.match(card, /updater\.downloadProgress\.map/);
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
  assert.match(updater, /session\.downloadTask\(with: url\)/);
  assert.match(updater, /withCheckedThrowingContinuation/);
  assert.match(updater, /session\.invalidateAndCancel\(\)/);
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
  assert.match(card, /已下載 %\.1f MB/);
  assert.match(card, /guard updater\.totalBytes > 0 else \{ return downloaded \}/);
  assert.match(card, /MB（約 %\.0f KB\/s）/);
  assert.match(card, /updater\.downloadBytesPerSecond \/ 1_000/);
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
    const status = card.slice(card.indexOf('    private var downloadStatus'),
      card.indexOf('    private var currentVersion')).replace('private var', 'var');
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
@MainActor struct Status {
    let updater: Probe
${status}
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
        precondition(Status(updater: probe).downloadStatus == "已下載 12.3 MB / 466.4 MB（約 115 KB/s）")
        probe.totalBytes = 0
        precondition(Status(updater: probe).downloadStatus == "已下載 12.3 MB")
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
