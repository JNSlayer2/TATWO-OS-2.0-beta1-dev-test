import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { once } from 'node:events';
import { testScratch } from './helpers/test-scratch.mjs';

const install = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
const transport = install.split('# DOWNLOAD-RETRY-BEGIN\n')[1].split('# DOWNLOAD-RETRY-END')[0];
// phase_time 住在 INVISIBLE-PRIMITIVES（delta／runtime 組裝與 transport 都用它）；切片 fixture 一律先帶 primitives。
const primitivesBlock = install.split('# INVISIBLE-PRIMITIVES-BEGIN\n')[1].split('# INVISIBLE-PRIMITIVES-END')[0];
// Only the fixture removes the HTTPS restriction; production keeps TLS and its GitHub trust anchor.
const localCurl = `curl() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in --proto|--proto-redir) shift; shift;; *) args+=("$1"); shift;; esac
  done
  command curl "\${args[@]}"
}`;
const python = String.raw`
import http.server, sys, threading, json, time, socket
root = sys.argv[1]
payload = open(root + '/payload', 'rb').read()
lock = threading.Lock()
seen = set()
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_HEAD(self): self.respond(True)
    def do_GET(self): self.respond(False)
    def respond(self, head):
        body = payload[:12345] if '/small' in self.path else payload
        size = len(body)
        r = self.headers.get('Range')
        with lock:
            with open(root + '/requests', 'a') as f: f.write(json.dumps({'path': self.path, 'method':self.command, 'range':r}) + '\n')
        start, end = 0, size - 1
        if r: start, end = map(int, r.split('=')[1].split('-'))
        status = 206 if r else 200
        if '/ignored' in self.path and r: status, start, end = 200, 0, size - 1
        if '/broken' in self.path and r and start == 0: status = 503
        self.send_response(status)
        self.send_header('ETag', '"synthetic-v1"')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1 if status != 503 else 0))
        if status == 206: self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.end_headers()
        if head or status == 503: return
        data = body[start:end+1]
        if ('/corrupt' in self.path and r and start == 0) or '/mirror/' in self.path: data = bytes([data[0] ^ 255]) + data[1:]
        if '/resume' in self.path and r and start in (0, size * 2 // 6):
            with lock:
                key = self.path + ':' + str(start)
                first = key not in seen
                seen.add(key)
            if first:
                self.wfile.write(data[:65536]); self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
        if r: time.sleep(0.05)
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
`;

async function run(code, env) {
  const child = spawn('/bin/bash', ['-c', `set -euo pipefail\n${primitivesBlock}\n${transport}\n${localCurl}\nsleep() { :; }\n${code}`], { env: { ...process.env, ...env } });
  let stdout = '', stderr = '';
  child.stdout.on('data', b => stdout += b); child.stderr.on('data', b => stderr += b);
  const [status] = await once(child, 'close');
  assert.equal(status, 0, stderr.slice(-4000));
  return stdout;
}

test('W87a real threaded HTTP Range fixture: join, resume, reject, fallback and receipts', { timeout: 180000 }, async t => {
  const root = testScratch('w87a-http-');
  const payload = Buffer.alloc(24_000_007);
  for (let i = 0; i < payload.length; i++) payload[i] = i % 251;
  writeFileSync(join(root, 'payload'), payload);
  writeFileSync(join(root, 'server.py'), python);
  const updater = readFileSync(new URL('../App/Sources/Tatwo2/Facade/InAppUpdater.swift', import.meta.url), 'utf8');
  const checker = readFileSync(new URL('../App/Sources/Tatwo2/Facade/GitHubReleaseUpdateChecker.swift', import.meta.url), 'utf8');
  const machinery = updater.slice(updater.indexOf('private final class UpdateDownloadProgress'), updater.indexOf('private struct UpdateRuntimeLayer')) + updater.split('// PARALLEL-DOWNLOAD-BEGIN\n')[1].split('// PARALLEL-DOWNLOAD-END')[0];
  const redirect = checker.slice(checker.indexOf('final class UpdateRedirectDelegate:'), checker.indexOf('\n}', checker.indexOf('final class UpdateRedirectDelegate:')) + 2);
  const main = `import Foundation\nimport CryptoKit\n${machinery}\n${redirect}\n
  @main struct Main {
    static func main() async throws {
      let a = CommandLine.arguments
      let operation = Task { try await UpdateParallelDownload.download(request: URLRequest(url: URL(string: a[1])!),
        destination: URL(fileURLWithPath: a[2]), size: Int64(a[3])!, expected: a[4]) { _, _ in } }
      if a.count > 5 {
        try await Task.sleep(for: .milliseconds(20)); operation.cancel()
        do { _ = try await operation.value; fatalError("cancelled transfer completed") }
        catch is CancellationError { print("cancelled"); return }
      }
      do { print(try await operation.value) }
      catch { print("download failed"); exit(1) }
    }
  }`;
  writeFileSync(join(root, 'main.swift'), main);
  const compiled = spawnSync('swiftc', ['-parse-as-library', join(root, 'main.swift'), '-o', join(root, 'probe')], { encoding: 'utf8' });
  assert.equal(compiled.status, 0, compiled.stderr);
  const server = spawn('python3' , ['-u', join(root, 'server.py'), root]);
  let errors = ''; server.stderr.on('data', b => errors += b);
  try {
    const [portBytes] = await once(server.stdout, 'data');
    const base = `http://127.0.0.1:${String(portBytes).trim()}`;
    for (const mode of ['good', 'resume', 'broken', 'ignored', 'corrupt', 'small', 'mirror']) {
      await t.test(mode, async () => {
        const dir = join(root, mode); mkdirSync(dir);
        const data = mode === 'small' ? payload.subarray(0, 12345) : payload;
        const hash = createHash('sha256').update(data).digest('hex');
        const output = join(dir, 'archive.zip');
        writeFileSync(output + '.sha256', `${hash}  archive.zip\n`);
        // The URL rewrite is fixture-only; the production mirror guard still requires HTTPS.
        const mirrorCurl = mode === 'mirror' ? `
          eval "$(declare -f curl | sed '1s/curl/local_curl/')"
          curl() { local args=() arg; for arg in "$@"; do
            case "$arg" in https://fixture.invalid/*) arg="$BASE\${arg#https://fixture.invalid}";; esac
            args+=("$arg"); done; local_curl "\${args[@]}"; }
        ` : '';
        const command = `${mirrorCurl}\nretry_download "$OUTPUT" "$BASE/${mode === 'mirror' ? 'fallback' : mode}/archive.zip"\nphases_json > "$TEMP/phases.json"`;
        const env = {
          TEMP: dir, OUTPUT: output, BASE: base, DOWNLOAD_SIZE: String(data.length),
          TATWO_OS_DOWNLOAD_PARTS: '6', TATWO_OS_MIRROR_BASE: mode === 'mirror' ? 'https://fixture.invalid/mirror' : '',
          TATWO_OS_OFFLINE_RELEASE: '',
        };
        if (mode === 'corrupt') {
          await run('if retry_download "$OUTPUT" "$BASE/corrupt/archive.zip"; then exit 99; fi', env);
          assert.ok(!existsSync(output));
          assert.ok(!existsSync(output + '.parts'));
          assert.ok(!existsSync(output + '.joining'));
          const requests = readFileSync(join(root, 'requests'), 'utf8').trim().split('\n').map(JSON.parse)
            .filter(r => r.path === '/corrupt/archive.zip' && r.method === 'GET');
          assert.equal(requests.length, 6);
          assert.ok(requests.every(r => r.range !== null), 'corrupt join must not trigger a full GET');
          return;
        }
        await run(command, env);
        assert.equal(createHash('sha256').update(readFileSync(output)).digest('hex'), hash);
        const phases = JSON.parse(readFileSync(join(dir, 'phases.json')));
        assert.deepEqual(Object.keys(phases), ['download', 'verify', 'extract', 'switch']);
        assert.equal(phases.download.length, 1);
        assert.equal(phases.download[0].source, 'github');
        assert.equal(phases.download[0].bytes, data.length);
        assert.ok(phases.download[0].seconds >= 0);
        assert.equal(phases.download[0].parts, ['good', 'resume', 'mirror'].includes(mode) ? 6 : 1);
        const requests = readFileSync(join(root, 'requests'), 'utf8').trim().split('\n').map(JSON.parse)
          .filter(r => r.path === `/${mode === 'mirror' ? 'fallback' : mode}/archive.zip` && r.method === 'GET');
        if (mode === 'small') assert.ok(requests.every(r => r.range === null));
        if (mode === 'good') assert.equal(requests.filter(r => r.range).length, 6);
        if (mode === 'resume') {
          assert.ok(requests.some(r => r.range?.startsWith('bytes=65536-')));
          assert.ok(requests.some(r => r.range?.startsWith(`bytes=${Math.floor(data.length * 2 / 6) + 65536}-`)));
        }
        if (mode === 'broken') assert.equal(requests.filter(r => r.range === `bytes=0-${Math.floor(data.length / 6) - 1}`).length, 3);
        if (['broken', 'ignored'].includes(mode)) assert.ok(requests.some(r => r.range === null));
      });
    }
    await t.test('verified mirror is used without a GitHub payload request', async () => {
      const dir = join(root, 'mirror-success'); mkdirSync(dir);
      const hash = createHash('sha256').update(payload).digest('hex');
      const output = join(dir, 'archive.zip');
      writeFileSync(output + '.sha256', `${hash}  archive.zip\n`);
      const rewrite = `eval "$(declare -f curl | sed '1s/curl/local_curl/')"
        curl() { local args=() arg; for arg in "$@"; do
          case "$arg" in https://fixture.invalid/*) arg="$BASE\${arg#https://fixture.invalid}";; esac
          args+=("$arg"); done; local_curl "\${args[@]}"; }`;
      await run(`${rewrite}\nretry_download "$OUTPUT" "$BASE/unused/archive.zip"\nphases_json > "$TEMP/phases.json"`, {
        TEMP: dir, OUTPUT: output, BASE: base, DOWNLOAD_SIZE: String(payload.length),
        TATWO_OS_DOWNLOAD_PARTS: '6', TATWO_OS_MIRROR_BASE: 'https://fixture.invalid/good', TATWO_OS_OFFLINE_RELEASE: '',
      });
      const phases = JSON.parse(readFileSync(join(dir, 'phases.json')));
      assert.equal(phases.download[0].source, 'mirror');
      assert.equal(phases.download[0].parts, 6);
      assert.equal(createHash('sha256').update(readFileSync(output)).digest('hex'), hash);
      assert.ok(!readFileSync(join(root, 'requests'), 'utf8').includes('/unused/'));
    });
    for (const mode of ['good', 'resume', 'broken', 'ignored', 'corrupt', 'small']) {
      await t.test('URLSession ' + mode, async () => {
        const data = mode === 'small' ? payload.subarray(0, 12345) : payload;
        const hash = createHash('sha256').update(data).digest('hex');
        const output = join(root, 'swift-' + mode + '.zip');
        const result = spawnSync(join(root, 'probe'), [base + '/' + mode + '/swift.zip', output, String(data.length), hash], {
          encoding: 'utf8', timeout: 60000, env: { ...process.env, TATWO_OS_DOWNLOAD_PARTS: '6' }
        });
        if (mode === 'corrupt') {
          assert.equal(result.status, 1, result.stderr);
          assert.match(result.stdout, /download failed/);
          assert.ok(!existsSync(output));
          assert.ok(!readdirSync(root).some(name => name.startsWith('swift-corrupt.zip.parts-')));
          assert.ok(!existsSync(output + '.joining'));
          const requests = readFileSync(join(root, 'requests'), 'utf8').trim().split('\n').map(JSON.parse)
            .filter(r => r.path === '/corrupt/swift.zip' && r.method === 'GET');
          assert.equal(requests.length, 6);
          assert.ok(requests.every(r => r.range !== null));
          return;
        }
        assert.equal(result.status, 0, result.stderr);
        assert.equal(createHash('sha256').update(readFileSync(output)).digest('hex'), hash);
        assert.equal(Number(result.stdout.trim()), ['good', 'resume'].includes(mode) ? 6 : 1);
        if (mode === 'resume') {
          const requests = readFileSync(join(root, 'requests'), 'utf8').trim().split('\n').map(JSON.parse)
            .filter(r => r.path === '/resume/swift.zip');
          assert.ok(requests.some(r => r.range?.startsWith(`bytes=${Math.floor(data.length * 2 / 6) + 65536}-`)), JSON.stringify(requests));
        }
      });
    }
    for (const reusable of [true, false]) {
      await t.test(`installer runtime reuse=${reusable} decides before any runtime HTTP request`, async () => {
        const dir = join(root, 'reuse-' + reusable); mkdirSync(dir);
        const source = join(dir, 'split', 'TATWO OS.app'), dest = join(dir, 'installed.app');
        for (const app of [source, dest]) mkdirSync(join(app, 'Contents', 'Resources'), { recursive: true });
        const sha = 'a'.repeat(64), name = `TATWO-OS-runtime-${sha.slice(0, 12)}.zip`;
        const meta = { sha, paths: ['Resources/runtime-fixture'] };
        writeFileSync(join(source, 'Contents', 'Resources', 'runtime-layer.json'), JSON.stringify(meta));
        writeFileSync(join(dest, 'Contents', 'Resources', 'runtime-layer.json'), JSON.stringify(meta));
        if (reusable) writeFileSync(join(dest, 'Contents', 'Resources', 'runtime-fixture'), 'synthetic runtime');
        writeFileSync(join(dir, 'release.json'), JSON.stringify({ assets: [{ name, size: payload.length }] }));
        const assembly = install.slice(install.indexOf('assemble_runtime() ('), install.indexOf('# RUNTIME-ASSEMBLY-END'));
        await run(`
          soft_fail() { echo "$*" >&2; exit 1; }
          # Simulate baseline metadata becoming readable only after app.zip arrives.
          # A pre-reuse read may not justify speculative runtime traffic.
          plutil() { [[ -f "$TEMP/app.zip" ]] || return 1; /usr/bin/plutil "$@"; }
          layer_download() { curl -fsS "$BASE/reuse-$REUSABLE/$1" -o "$3"; }
          ditto() { if [[ "$3" == "$TEMP/runtime.zip" ]]; then
            printf synthetic > "$SOURCE/Contents/Resources/runtime-fixture"; fi; }
          clone_copy() { cp "$1" "$2"; }
          verify_signed_app() { :; }
          ${primitivesBlock}
          ${assembly}
          assemble_runtime`, {
          TEMP: dir, STAGE: dir, SOURCE: source, DEST: dest, BASE: base, REUSABLE: String(reusable),
          RUNTIME_NAMES: ` ${name} `,
        });
        const requests = readFileSync(join(root, 'requests'), 'utf8').trim().split('\n').map(JSON.parse)
          .filter(r => r.path === `/reuse-${reusable}/${name}`);
        assert.equal(requests.length, reusable ? 0 : 1);
        assert.ok(existsSync(join(source, 'Contents', 'Resources', 'runtime-fixture')));
      });
    }
    await t.test('both transports use the same default and invalid-override fallback', async () => {
      const count = Number(install.match(/TATWO_OS_DOWNLOAD_PARTS:-([0-9]+)/)[1]);
      const hash = createHash('sha256').update(payload).digest('hex');
      for (const configured of ['', 'invalid']) {
        for (const client of ['shell', 'swift']) {
          const label = `${client}-${configured || 'default'}`;
          const output = join(root, label + '.zip'), path = `/good/${label}.zip`;
          const env = { ...process.env, TATWO_OS_DOWNLOAD_PARTS: configured };
          if (configured === '') delete env.TATWO_OS_DOWNLOAD_PARTS;
          if (client === 'shell') {
            writeFileSync(output + '.sha256', `${hash}  archive.zip\n`);
            await run('retry_download "$OUTPUT" "$BASE$ASSET_PATH"', {
              ...env, TEMP: root, OUTPUT: output, BASE: base, ASSET_PATH: path,
              DOWNLOAD_SIZE: String(payload.length), TATWO_OS_MIRROR_BASE: '', TATWO_OS_OFFLINE_RELEASE: '',
              TATWO_OS_DOWNLOAD_PARTS: configured,
            });
          } else {
            const result = spawnSync(join(root, 'probe'), [base + path, output, String(payload.length), hash], {
              encoding: 'utf8', timeout: 60000, env,
            });
            assert.equal(result.status, 0, result.stderr);
            assert.equal(Number(result.stdout.trim()), count);
          }
          assert.equal(createHash('sha256').update(readFileSync(output)).digest('hex'), hash);
          const requests = readFileSync(join(root, 'requests'), 'utf8').trim().split('\n').map(JSON.parse)
            .filter(r => r.path === path && r.method === 'GET');
          assert.equal(requests.length, count, label);
          assert.ok(requests.every(r => r.range !== null));
        }
      }
    });
    await t.test('URLSession cancellation does not leave an unverified final archive', async () => {
      const hash = createHash('sha256').update(payload).digest('hex');
      const output = join(root, 'cancelled.zip');
      const result = spawnSync(join(root, 'probe'), [base + '/good/cancelled.zip', output, String(payload.length), hash, 'cancel'], {
        encoding: 'utf8', timeout: 60000, env: { ...process.env, TATWO_OS_DOWNLOAD_PARTS: '6' }
      });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout.trim(), 'cancelled');
      assert.throws(() => readFileSync(output), { code: 'ENOENT' });
    });
  } finally {
    server.kill(); await once(server, 'close');
    console.log("W87a HTTP evidence: " + root);
  }
});

test('W87a both installer copies and App keep checksum authority, phase handoff, and bounded ranges', () => {
  assert.equal(install, readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8'));
  const swift = readFileSync(new URL('../App/Sources/Tatwo2/Facade/InAppUpdater.swift', import.meta.url), 'utf8');
  assert.match(swift, /withThrowingTaskGroup/);
  assert.doesNotMatch(swift, /async let (first|second)/);
  assert.match(swift, /for archive in archives \{\s*let zip = try await fetch/);
  assert.match(swift, /http.expectedContentLength == size/);
  assert.match(swift, /response.statusCode == 206/);
  assert.match(swift, /for attempt in 0..<3/);
  assert.match(swift, /TATWO_OS_PHASES_FILE/);
  assert.match(swift, /update-mirror-base/);
  assert.doesNotMatch(install, /runtime_pid/);
  const card = readFileSync(new URL('../App/Sources/Tatwo2/New/UpdateAvailableCard.swift', import.meta.url), 'utf8');
  assert.doesNotMatch(card, /TextField|update-mirror-base/);
  assert.match(card, /updater.lastPhases/);
  assert.match(install, /TATWO_OS_MIRROR_BASE/);
});

test('W87a installer reserves range peak on both volumes before requesting ZIPs', () => {
  const root = testScratch('w87a-space-');
  const primitives = install.split('# INVISIBLE-PRIMITIVES-BEGIN\n')[1].split('# INVISIBLE-PRIMITIVES-END')[0];
  const selection = install.slice(install.indexOf('DOWNLOAD_RESERVE_BYTES=0'),
    install.indexOf('[[ "$INSTALL_READY" == 1 ]]'));
  const preflight = install.slice(install.indexOf('check_space "$(dirname "$DEST")" "$CANDIDATE_BYTES"'),
    install.indexOf('SOURCE="$STAGE/split/TATWO OS.app"'));
  const assets = [
    ['TATWO-OS.zip', 250_000_000, 'https://fixture.invalid/full.zip'],
    ['TATWO-OS-app.zip', 10_000_000, 'https://fixture.invalid/app.zip'],
    ['TATWO-OS-runtime-aaaaaaaaaaaa.zip', 240_000_000, 'https://fixture.invalid/runtime.zip'],
  ].map(([name, size, browser_download_url]) => ({ name, size, browser_download_url }));
  writeFileSync(join(root, 'release.json'), JSON.stringify({ assets }));
  for (const [tempFree, destFree, succeeds] of [
    [2_000_000, 2_000_000, false], // old 2× expanded estimate would pass
    [2_000_000, 4_000_000, false], [4_000_000, 2_000_000, false],
    [4_000_000, 4_000_000, true],
  ]) {
    const result = spawnSync('/bin/bash', ['-c', `set -eu
      fail() { echo "$*" >&2; exit 1; }
      df() { local free=${destFree}; [[ "$2" != "$TEMP" ]] || free=${tempFree}
        printf 'fixture 9999999 0 %s 0%% /fixture\\n' "$free"; }
      ${primitives}
      INDEX=0; RUNTIME_NAMES=" "; CANDIDATE_BYTES=1024000000
      ${selection}
      [[ "$DOWNLOAD_RESERVE_BYTES" == 500000000 ]]
      ${preflight}
      echo payload-download-allowed
    `], { encoding: 'utf8', env: { ...process.env, TEMP: root, DEST: '/fixture/App.app' } });
    assert.equal(result.status, succeeds ? 0 : 1, result.stderr);
    assert.equal(result.stdout.includes('payload-download-allowed'), succeeds);
    if (!succeeds) assert.match(result.stderr, /空間不足.*分段下載峰值/);
  }
});

test('W87a App preflight includes parts/joining in addition to staging before payload', () => {
  const root = testScratch('w87a-app-space-');
  const swift = readFileSync(new URL('../App/Sources/Tatwo2/Facade/InAppUpdater.swift', import.meta.url), 'utf8');
  const checkSpace = swift.slice(swift.indexOf('    private func checkSpace()'),
    swift.indexOf('    func preparationTitle(')).replace('private func', 'func');
  const main = `import Foundation
    struct IslandNotice {
      static let shared = IslandNotice()
      func info(title: String, detail: String) {}
    }
    struct FakeFileManager {
      var free: Int64
      func createDirectory(at: URL, withIntermediateDirectories: Bool) throws {}
      func attributesOfFileSystem(forPath: String) throws -> [FileAttributeKey: Any] {
        [.systemFreeSize: NSNumber(value: free)]
      }
    }
    struct Probe {
      static let destinationApp = "/fixture/App.app"
      let directory = URL(fileURLWithPath: "/fixture/download")
      var candidateBytes: Int64 = 1_000_000_000
      var fileManager: FakeFileManager
      ${checkSpace}
    }
    for free in [Int64(2_000_000_000), 3_999_999_999, 4_000_000_000] {
      do {
        try Probe(fileManager: FakeFileManager(free: free)).checkSpace()
        precondition(free == 4_000_000_000)
      } catch { precondition(free < 4_000_000_000); precondition(error.localizedDescription.contains("空間不足")) }
    }
    do {
      try Probe(candidateBytes: Int64.max, fileManager: FakeFileManager(free: Int64.max)).checkSpace()
      fatalError("overflow accepted")
    } catch { precondition(error.localizedDescription.contains("無法確認")) }
    print("space peak PASS")
  `;
  writeFileSync(join(root, 'main.swift'), main);
  const compile = spawnSync('swiftc', [join(root, 'main.swift'), '-o', join(root, 'probe')], { encoding: 'utf8' });
  assert.equal(compile.status, 0, compile.stderr);
  const result = spawnSync(join(root, 'probe'), [], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /space peak PASS/);
  assert.ok(swift.indexOf('try checkSpace()', swift.indexOf('candidateBytes = max(candidateBytes, expandedBytes)'))
    < swift.indexOf('func fetch('));
});


test('W87a actual installer receipt and App helper preserve all phases and original prefetch source', async () => {
  const root = testScratch('w87a-receipt-');
  try {
    const writeReceipt = install.slice(install.indexOf('INSTALL_SECONDS=$(('), install.indexOf('[[ ! -e "$DEST.old" ]] || mv'));
    await run(`STAGE="$TEMP"; INSTALL_STARTED_AT=$(date +%s); LAUNCH_MESSAGE=installed; SWITCH_STARTED=$SECONDS
      phase_time verify 1; phase_time extract 2
      ${primitivesBlock}
      ${writeReceipt}`, { TEMP: root, TATWO_OS_TIMING_FILE: '', TATWO_OS_PHASES_FILE: '' });
    const receipt = JSON.parse(readFileSync(join(root, 'result.json')));
    assert.deepEqual(Object.keys(receipt.phases), ['download', 'verify', 'extract', 'switch']);
    assert.equal(receipt.phases.verify, 1); assert.equal(receipt.phases.extract, 2);
    const result = join(root, 'app-result.json');
    writeFileSync(result + '.phases', JSON.stringify(receipt.phases));
    const download = [{ name: 'fixture', source: 'mirror', bytes: 2048, seconds: 1.25, parts: 6 }];
    writeFileSync(join(root, 'download-phases.json'), JSON.stringify({ download, verify: 0.25, extract: 0, switch: 0 }));
    writeFileSync(join(root, 'seconds'), '4');
    const updater = readFileSync(new URL('../App/Sources/Tatwo2/Facade/InAppUpdater.swift', import.meta.url), 'utf8');
    const helper = updater.slice(updater.indexOf('        write_result() {'), updater.indexOf('        abnormal_exit() {')).replace(/\\\\n/g, '\\n');
    await run(`${helper}\nwrite_result true installed`, {
      TEMP: root, RESULT: result, RUN_ID: 'synthetic-run', TAG: 'v9.9.9', START_SECONDS: '0',
      TATWO_OS_TIMING_FILE: join(root, 'seconds'), PRIVATE_INSTALLER: join(root, 'install.sh'),
    });
    const app = JSON.parse(readFileSync(result));
    assert.deepEqual(app.phases.download, download);
    for (const key of ['verify', 'extract', 'switch']) assert.equal(app.phases[key], receipt.phases[key]);
    assert.equal(app.phases.prefetchVerify, 0.25);
  } finally { console.log("W87a receipt evidence: " + root); }
});
