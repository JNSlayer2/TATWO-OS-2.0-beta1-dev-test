import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const bridgePath = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm';
const bridge = fs.readFileSync(path.join(repo, bridgePath), 'utf8');
const slice = (start, end) => {
  const a = bridge.indexOf(start), b = bridge.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `missing production section: ${start}`);
  return bridge.slice(a, b);
};

const sdk = process.env.TATWO_CEF_ROOT;
test('production resource callbacks isolate subresources and stale DNS errors', {
  timeout: 90000,
  skip: process.platform !== 'darwin' || !sdk
    ? 'requires macOS and the pinned CEF SDK in TATWO_CEF_ROOT' : false,
}, () => {
  const out = path.resolve(process.env.TATWO_BROWSER_RESOURCE_EVIDENCE ?? os.tmpdir());
  fs.mkdirSync(out, { recursive: true });
  const scratch = fs.mkdtempSync(path.join(out, 'regression-'));
  const sections = {
    urlPolicy: slice('bool IsPrivateIPv4(', 'enum class PublicAddressResult'),
    urlCredentials: slice('bool URLHasCredentials(', 'NSString *OriginForURLString('),
    list: slice('NSString *CanonicalDenyListEntry(', 'std::shared_ptr<const BrowserHostDenyListSnapshot>\nLoadHostDenyListSnapshot('),
    policy: slice('struct BrowserRequestPolicySnapshot {', 'bool ApplyPrivacyStrictRequestContextPreferences('),
    actor: slice('BrowserRequestPolicySnapshot ActorRequestPolicy(', 'bool IsDeniedByLocalHostList('),
    decision: slice('bool IsDeniedByLocalHostList(', 'bool IsDeniedHostSwitch('),
    privateRetry: slice('void RememberPrivateNetworkRetry(TatwoCEFBrowserView *view,\n                                 ResourceErrorContext context, NSString *url) {', 'NSString *TakePrivateNetworkRetry('),
    handler: slice('class TatwoResourceRequestHandler final', '// Metadata callbacks are bound'),
    delivery: slice('void PublishResourceError(TatwoCEFBrowserView *view,\n                          ResourceErrorContext context,\n                          NSString *message,\n                          bool dns_failure) {', 'void UpdateLoadingState(TatwoCEFBrowserView *view, bool is_loading) {'),
    finishNavigation: slice('void FinishNavigationFrameTelemetry(TatwoCEFBrowserView *view) {', 'void InvalidateWebMCPForRendererTermination('),
    rendererNavigation: slice('void BeginRendererNavigationIfNeeded(TatwoCEFBrowserView *view) {', 'void FinishNavigationFrameTelemetry(TatwoCEFBrowserView *view) {'),
    loadError: slice('  void OnLoadError(CefRefPtr<CefBrowser> browser,', '  void OnRenderProcessTerminated('),
    documentMIME: slice('void PublishDocumentMIME(TatwoCEFBrowserView *view, ResourceErrorContext context,\n                         NSString *url, NSString *mime) {', 'void InvalidateSecurityDocumentEpoch('),
    pdfGetter: slice('- (BOOL)currentDocumentIsPDF {', '- (uint64_t)navigationGeneration'),
  };
  let fixture = fs.readFileSync(path.join(repo, 'tests/fixtures/browser-resource-block.mm.in'), 'utf8');
  for (const [key, value] of Object.entries(sections)) fixture = fixture.replace(`// INSERT ${key}`, value);
  fs.writeFileSync(path.join(scratch, 'fixture.mm'), fixture);
  const build = spawnSync('xcrun', ['clang++', '-std=c++20', '-fobjc-arc', '-fblocks', '-I' + sdk,
    '-framework', 'Foundation', path.join(scratch, 'fixture.mm'), '-o', path.join(scratch, 'fixture')],
  { cwd: repo, encoding: 'utf8', timeout: 60000 });
  fs.writeFileSync(path.join(scratch, 'compile.log'), build.stdout + build.stderr + `\nexit=${build.status}\n`);
  assert.equal(build.status, 0, build.stderr || String(build.error));
  const run = spawnSync(path.join(scratch, 'fixture'), [], { encoding: 'utf8', timeout: 20000 });
  fs.writeFileSync(path.join(scratch, 'run.log'), run.stdout + run.stderr + `\nexit=${run.status}\n`);
  process.stdout.write(run.stdout);
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /failed=0/);
  // Prove the tests detect both the original frame/resource confusion and
  // loss of the delivery-time navigation guard, using test copies only.
  for (const [name, before, after, failure] of [
    ['old-frame-check', 'const bool is_main_frame = IsMainFrameRequest(request);',
      'const bool is_main_frame = frame && frame->IsMain();', 'listed subresource never replaces page'],
    ['missing-epoch-check', '!context.epoch->IsCurrent(context.generation)',
      'false', 'stale queued error dropped'],
    ['missing-navigation-finish', 'FinishNavigationFrameTelemetry(active_view);',
      '', 'current blocked navigation finishes telemetry'],
  ]) {
    assert.ok(fixture.includes(before));
    const source = path.join(scratch, `${name}.mm`), binary = path.join(scratch, name);
    fs.writeFileSync(source, fixture.replaceAll(before, after));
    const compiled = spawnSync('xcrun', ['clang++', '-std=c++20', '-fobjc-arc', '-fblocks', '-I' + sdk,
      '-framework', 'Foundation', source, '-o', binary], { encoding: 'utf8', timeout: 60000 });
    assert.equal(compiled.status, 0, compiled.stderr);
    const negative = spawnSync(binary, [], { encoding: 'utf8', timeout: 20000 });
    fs.writeFileSync(path.join(scratch, `${name}.log`), negative.stdout + negative.stderr);
    assert.equal(negative.status, 1);
    assert.ok(negative.stderr.includes(failure), negative.stderr);
    console.log(`NEGATIVE CONTROL ${name}: regression detected`);
  }
  // Lifecycle wiring is checked separately from the fake DNS/UI adapters.
  const callbacks = sections.handler;
  assert.doesNotMatch(callbacks, /frame->IsMain\(\)/);
  assert.equal((callbacks.match(/IsMainFrameRequest\(request\)/g) ?? []).length, 3);
  assert.doesNotMatch(callbacks, /PublishVisibleError\(/);
  assert.match(bridge, /IsMainFrameRequest\(request\) && !is_redirect\) \{\s+InvalidateResourceErrors\(\)/);
  assert.match(bridge, /resource_epoch_, resource_epoch_->Capture\(\), mount_generation_/);
  assert.match(slice('uint64_t BeginNavigationFrameTelemetry(TatwoCEFBrowserView *view,\n                                       BrowserState *state,\n                                       NSString *reason) {', 'bool IsActiveMountCallback('), /InvalidateResourceErrors/);
});
