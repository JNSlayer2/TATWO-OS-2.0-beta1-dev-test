import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const updater = read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
const checker = read('App/Sources/Tatwo2/Facade/GitHubReleaseUpdateChecker.swift');
const card = read('App/Sources/Tatwo2/New/UpdateAvailableCard.swift');

test('W24 detection starts prefetch only for an install-ready newer release, all three triggers share check', () => {
  assert.match(checker, /isNewer\(release.tag_name, than: installedVersion\)/);
  assert.match(checker, /release.assets\?\.contains[\s\S]*TATWO-OS.install-ready[\s\S]*InAppUpdater.shared.prefetch/);
  assert.match(checker, /30 \* 1_000_000_000/);
  assert.match(checker, /6 \* 60 \* 60 \* 1_000_000_000/);
  assert.match(checker, /checkForUpdatesFromUser\(\) \{ Task \{ await check\(\) \} \}/);
  const prepare = updater.slice(updater.indexOf('private func beginPrefetch'), updater.indexOf('func cancelUpdate'));
  assert.match(prepare, /try checkSpace\(\)[\s\S]*phase = \.ready/);
  assert.doesNotMatch(prepare, /handOff|NSApp.terminate/);
});

test('W24 network starts fail-closed, rejects expensive/constrained paths, allows explicit download', () => {
  assert.match(updater, /private var unmetered = false/);
  assert.match(updater, /NWPathMonitor\(\)/);
  assert.match(updater, /path.status == \.satisfied && path.isExpensive == false && !path.isConstrained/);
  assert.match(updater, /guard force \|\| unmetered/);
  assert.match(updater, /!allowed && !self.manualDownload && self.phase == \.starting/);
  assert.match(updater, /等 Wi‑Fi 再自動下載/);
  assert.match(updater, /prefetch\(to: tag, repository: repository, force: true\)/);
});

test('W24 cache and Applications space gates run before bytes, after verification and before handoff', () => {
  assert.match(updater, /for volume in \[directory, URL\(fileURLWithPath: Self.destinationApp\).deletingLastPathComponent\(\)\]/);
  assert.match(updater, /max\(2_000_000_000, candidateBytes \* 2\)/);
  assert.match(updater, /\.systemFreeSize/);
  assert.match(updater, /candidateBytes \+= size.int64Value/);
  assert.match(updater, /try checkSpace\(\)[\s\S]*let plannedBytes/);
  assert.match(updater, /try checkSpace\(\) \} catch[\s\S]*handOff\(tag: tag, repository: prepared.repository/);
});

test('W42 shared three-state UI preserves ready-only handoff and hides background progress', () => {
  assert.equal((card.match(/await updater\.activateUpdateMark/g) ?? []).length, 2);
  assert.match(card, /私人通道 · /);
  assert.match(card, /\.help\(updater\.updateMarkHelp\)/);
  assert.doesNotMatch(card, /updater\.update\(to:|preparationTitle|現在就下載/);
  assert.match(updater, /guard phase == \.ready, let prepared, prepared.tag == tag/);
  const action = updater.slice(updater.indexOf('    func activateUpdateMark'), updater.indexOf('    private func checkSpace'));
  const download = action.slice(action.indexOf('if !userStarted'), action.indexOf('confirmingRestart = true'));
  assert.match(download, /prefetch\(to: tag, repository: repository, force: true\)/);
  assert.doesNotMatch(download, /handOff|update\(to:|terminate/);
});

test('W24 offline restart caches tag-pinned script and hash-bound metadata, namespaced by repository', () => {
  assert.match(updater, /contents\/install.sh\?ref=\\\(tag\)/);
  assert.match(updater, /# OFFLINE-RELEASE-BEGIN/);
  assert.match(updater, /markerMatches\(archive.name, expected\)/);
  assert.match(updater, /download\/\\\(repository\)\/\\\(tag\)/);
  assert.match(updater, /TATWO_OS_OFFLINE_RELEASE/);
});

test('W24 production Swift state methods: metered override, space gate, candidate cancellation, ready-only handoff', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w24-state-'));
  const methods = updater.slice(updater.indexOf('    private func checkSpace()'), updater.indexOf('    private func revalidate('));
  const cancel = updater.slice(updater.indexOf('    func cancelUpdate()'), updater.indexOf('    func resumableBytes'));
  const swift = `import Foundation
struct UpdateArchives {}
@MainActor enum GitHubReleaseUpdateChecker { static let shared = Checker() }
struct Checker { let repository = "fixture/repo" }
final class Space {
 var free: Int64 = 10_000_000_000
 func createDirectory(at: URL, withIntermediateDirectories: Bool) throws {}
 var removed = 0
 func removeItem(at: URL) throws { removed += 1 }
 func attributesOfFileSystem(forPath: String) throws -> [FileAttributeKey:Any] { [.systemFreeSize:NSNumber(value:free)] }
}
@MainActor final class Probe {
 enum Phase: Equatable { case idle, starting, ready, handedOff, failed(String) }
 static let destinationApp = "/fixture/Applications/TATWO OS.app"
 var phase = Phase.idle, unmetered = false, manualDownload = false, userStarted = false
 var candidateBytes: Int64 = 0, downloadedBytes: Int64 = 12_300_000, totalBytes: Int64 = 15_700_000
 var pendingCandidate: (tag:String, repository:String)?
 var prepared: (tag:String, repository:String, archives:UpdateArchives)?
 var preparationReason = ""
 var download: Task<Void,Never>?
 var downloadID = UUID(), rejectValidation = false
 func revalidate(tag: String, repository: String, folder: URL) async throws { if rejectValidation { throw URLError(.resourceUnavailable) } }
 let fileManager = Space(), directory = URL(fileURLWithPath:"/fixture/cache")
 var started = 0, handoffs = 0
 func beginPrefetch(to: String, repository: String) { started += 1; phase = .starting }
 func handOff(tag: String, repository: String, zip: UpdateArchives) { handoffs += 1; phase = .handedOff }
${methods}
${cancel}
}
@main struct Main {
 @MainActor static func main() async throws {
  let p = Probe(), repo = "fixture/repo"
  p.prefetch(to:"v2.0.6", repository:repo)
  precondition(p.started == 0 && p.preparationReason.contains("Wi‑Fi"))
  p.fileManager.free = 134 * 1024 * 1024
  p.prefetch(to:"v2.0.6", repository:repo, force:true)
  precondition(p.started == 0 && p.preparationReason.contains("空間不足"))
  p.fileManager.free = 10_000_000_000
  p.prefetch(to:"v2.0.6", repository:repo, force:true)
  precondition(p.started == 1 && p.phase == .starting && p.manualDownload)
  precondition(p.preparationTitle("v2.0.6") == "正在準備 v2.0.6（12.3 / 15.7 MB）")
  p.manualDownload = false
  p.prefetch(to:"v2.0.6", repository:repo, force:true)
  precondition(p.manualDownload && p.started == 1)
  p.update(to:"v2.0.6"); precondition(p.handoffs == 0)
  let task = Task<Void,Never> {}; p.download = task
  p.prefetch(to:"v2.0.7", repository:repo)
  precondition(task.isCancelled && p.pendingCandidate?.tag == "v2.0.7" && !p.manualDownload)
  p.prefetch(to:"v2.0.8", repository:repo, force:true)
  precondition(p.manualDownload && p.pendingCandidate?.tag == "v2.0.8")
  p.cancelUpdate(); precondition(p.pendingCandidate == nil)
  p.phase = .ready; p.prepared = ("v2.0.7",repo,UpdateArchives()); p.candidateBytes = 6_000_000_000
  p.update(to:"v2.0.7"); precondition(p.handoffs == 0 && p.prepared == nil)
  p.phase = .ready; p.prepared = ("v2.0.7",repo,UpdateArchives()); p.candidateBytes = 1
  p.update(to:"v2.0.6"); precondition(p.handoffs == 0)
  p.update(to:"v2.0.7",repository:"other/repo"); precondition(p.handoffs == 0)
  p.update(to:"v2.0.7"); precondition(p.handoffs == 0 && p.phase == .starting && p.manualDownload)
  await p.download?.value; precondition(p.handoffs == 1)
  p.phase = .ready; p.prepared = ("v2.0.7",repo,UpdateArchives()); p.rejectValidation = true
  p.update(to:"v2.0.7"); await p.download?.value
  precondition(p.handoffs == 1 && p.prepared == nil && p.fileManager.removed == 1 && p.phase == .failed("版本已撤回或無法確認"))
  p.rejectValidation = false
  p.phase = .ready; p.prepared = ("v2.0.7",repo,UpdateArchives())
  p.update(to:"v2.0.7"); let validating = p.download
  p.prefetch(to:"v2.0.8", repository:repo, force:true)
  await validating?.value
  precondition(p.handoffs == 1 && p.fileManager.removed == 1 && p.started == 2)
  precondition(p.phase == .starting && p.pendingCandidate?.tag == "v2.0.8" && p.manualDownload)
  p.phase = .ready; p.invalidateCandidate(); precondition(p.phase == .idle && p.prepared == nil)
  print("state gates PASS")
 }
}`;
  const file = join(dir, 'Probe.swift'), binary = join(dir, 'probe'); writeFileSync(file, swift);
  let result = spawnSync('swiftc', ['-parse-as-library', '-num-threads', '2', file, '-o', binary], {encoding:'utf8', timeout:60000});
  assert.equal(result.status, 0, result.stderr);
  result = spawnSync(binary, [], {encoding:'utf8'}); assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /state gates PASS/);
});
