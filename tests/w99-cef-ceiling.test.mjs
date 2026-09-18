// W99：CEF 設定檔上限——淘汰其他設定檔後仍超標時，先清當前設定檔的可重建快取，
// 清完仍超標才 ceilingUnsatisfied。跑真正的 production controller／store／lease
// registry，只有原生 origin-data 清除橋接是 fail-fast 替身（照 browser-stress 的寫法）。
import { testScratch } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const browser = 'App/Sources/Tatwo2/Browser/';
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const backend = read(browser + 'ChromiumCEFBackend.swift');
const profile = read(browser + 'EmbeddedBrowserProfile.swift');
const managementModel = read(browser + 'BrowserManagementViewModel.swift');
const managementView = read(browser + 'BrowserManagementView.swift');

const run = (cmd, args, options = {}) => {
  const r = spawnSync(cmd, args, {cwd: root, encoding: 'utf8', timeout: 150000, ...options});
  assert.equal(r.status, 0, `${r.error ?? ''}\n${r.stdout}\n${r.stderr}`);
  return r.stdout;
};

function slice(text, from, to, label) {
  const start = text.indexOf(from);
  const end = text.indexOf(to);
  assert.ok(start >= 0 && end > start, `slice ${label} not found`);
  return text.slice(start, end);
}

function fixture(name, source) {
  const dir = path.join(testScratch('w99-cef-ceiling-'), name);
  fs.mkdirSync(dir, {recursive: true});
  const file = path.join(dir, 'Checks.swift'), binary = path.join(dir, 'checks');
  fs.writeFileSync(file, source);
  run('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    file, '-o', binary]);
  const output = run(binary, [dir]);
  process.stdout.write(output);
  return output;
}

test('W99 enforce clears rebuildable caches of the current profile before failing closed', {
  skip: process.platform !== 'darwin', timeout: 180000,
}, () => {
  const ledgerTypes = slice(profile, 'enum EmbeddedBrowserProfileStorageKind:',
    'struct EmbeddedBrowserProfileCapacityReport:', 'ledger');
  // Production store + directory measurement + lease/purge error vocabulary.
  const storeAndErrors = slice(backend, 'enum TatwoCEFProfileStoreError:',
    'enum TatwoCEFOriginDataClearBridge {', 'store');
  const leases = slice(backend, '@MainActor\nfinal class TatwoCEFProfileLeaseRegistry',
    'enum TatwoCEFProfileCeilingError:', 'leases');
  const ceiling = slice(backend, 'enum TatwoCEFProfileCeilingError:',
    'enum TatwoCEFProfileLocationResolver {', 'ceiling');
  assert.ok(ceiling.includes('struct TatwoCEFProfileCeilingController'));
  assert.ok(!leases.includes('struct TatwoCEFProfileCeilingResult'));

  const output = fixture('ceiling', `import AppKit
import Darwin
${ledgerTypes}${storeAndErrors}
// 原生清除橋接在本測試絕不該被呼叫：踩到就當場炸。
enum TatwoCEFOriginDataClearBridge {
  static func clear(origin: String, persistentProfilePath: String,
    completion: @escaping @Sendable (Result<TatwoCEFOriginDataClearReceipt,TatwoCEFOriginDataClearError>) -> Void) {
    fatalError("W99 must not clear origin data")
  }
}
final class TatwoCEFOriginDataClearCallbackGate: @unchecked Sendable {
  func claimTerminalResult() -> Bool { fatalError("not a W99 test") }
}
enum TatwoCEFProfileLocationResolver {
  static func rootCacheURL(bundle: Bundle = .main,
    fileManager: FileManager = .default) -> URL? { nil }
}
${leases}${ceiling}
let megabyte = 1_024 * 1_024
let slack = 512 * 1_024
let currentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
let archivedID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
let olderArchivedID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
let orphanID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

// 登入態與使用者資料：超標情境下一個 byte 都不准動。
let protectedFiles = [
  ["Cookies"],
  ["Local Storage", "leveldb", "000003.log"],
  ["IndexedDB", "https_x.com_0.indexeddb.leveldb", "CURRENT"],
  ["Login Data"],
  ["Preferences"],
]

struct Stamp: Equatable {
  let size: UInt64
  let modified: TimeInterval
}

final class Disposals {
  var urls: [URL] = []
}

struct Setup {
  let store: TatwoCEFProfileStore
  let currentURL: URL
  let ledger: EmbeddedBrowserProfileCapacityLedger
  let disposals: Disposals
  let protectedBefore: [Stamp]
}

// 檔案系統的 allocated size 以 block 計，留 512 KB 容差；目錄清單仍是精確比對。
func isAbout(_ value: UInt64, megabytes: Int) -> Bool {
  let expected = UInt64(megabytes * megabyte)
  return value >= expected && value < expected + UInt64(slack)
}

func at(_ base: URL, _ components: [String]) -> URL {
  var url = base
  for component in components { url.appendPathComponent(component) }
  return url
}

func writeFile(_ url: URL, megabytes: Int) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(count: megabytes * megabyte).write(to: url)
}

func stamp(_ url: URL) throws -> Stamp {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  let size = (attributes[.size] as? NSNumber)?.uint64Value ?? .max
  let modified = (attributes[.modificationDate] as? Date)?
    .timeIntervalSince1970 ?? -1
  return Stamp(size: size, modified: modified)
}

func protectedStamps(_ profileURL: URL) throws -> [Stamp] {
  try protectedFiles.map { try stamp(at(profileURL, $0)) }
}

func caseRoot(_ root: URL, _ name: String) throws -> URL {
  let url = root.appendingPathComponent(name, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func entry(_ id: UUID, archived: Bool, accessed: Date)
  -> EmbeddedBrowserProfileCapacityEntry {
  EmbeddedBrowserProfileCapacityEntry(
    profileIdentifier: id, storageKind: .cefAppOwned, generation: 0,
    lastAccessedAt: accessed, isArchived: archived)
}

// 當前設定檔 9 MB：可重建快取 4 MB（CacheStorage 3、Cache 1）＋登入態 5 MB。
// 另一個已封存設定檔 2 MB，全域 11 MB。
func makeSetup(_ scratch: URL, _ name: String, _ now: Date) throws -> Setup {
  let root = try caseRoot(scratch, name)
  let store = TatwoCEFProfileStore(rootCacheURL: root)
  let currentURL = try store.profileURL(for: currentID, generation: 0)
  try writeFile(at(currentURL, ["Service Worker", "CacheStorage", "blob-0"]), megabytes: 3)
  try writeFile(at(currentURL, ["Cache", "data-0"]), megabytes: 1)
  for components in protectedFiles {
    try writeFile(at(currentURL, components), megabytes: 1)
  }
  let archivedURL = try store.profileURL(for: archivedID, generation: 0)
  try writeFile(at(archivedURL, ["blob"]), megabytes: 2)
  return Setup(
    store: store,
    currentURL: currentURL,
    ledger: EmbeddedBrowserProfileCapacityLedger(entries: [
      entry(currentID, archived: false, accessed: now),
      entry(archivedID, archived: true, accessed: now.addingTimeInterval(-3_600)),
    ]),
    disposals: Disposals(),
    protectedBefore: try protectedStamps(currentURL))
}

@MainActor
func enforce(
  _ setup: Setup, ceilingBytes: UInt64
) throws -> TatwoCEFProfileCeilingResult {
  try TatwoCEFProfileCeilingController(store: setup.store).enforce(
    byteCeiling: ceilingBytes,
    currentIdentifier: currentID,
    activeIdentifiers: [],
    ledger: setup.ledger,
    leaseRegistry: TatwoCEFProfileLeaseRegistry(),
    removeLedgerRecord: { _ in },
    disposer: { url in
      setup.disposals.urls.append(url)
      try FileManager.default.removeItem(at: url)
    })
}

@main struct Checks {
 @MainActor static func main() throws {
  let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    .resolvingSymlinksInPath()
  let now = Date(timeIntervalSince1970: 1_789_000_000)

  // 預設清單就是 spec 列的可重建目錄，且不含任何登入態路徑。
  let cachePaths = TatwoCEFProfileCeilingController.defaultCurrentProfileCachePaths
  let protectedPaths = TatwoCEFProfileCeilingController.defaultProtectedPaths
  precondition(cachePaths.first == "Service Worker/CacheStorage")
  for expected in ["Service Worker/CacheStorage", "Cache", "Code Cache", "GPUCache",
                   "Media Cache", "DawnCache", "GraphiteDawnCache",
                   "Service Worker/ScriptCache"] {
    precondition(cachePaths.contains(expected), "missing cache path \\(expected)")
  }
  for guarded in ["Cookies", "Local Storage", "IndexedDB", "Session Storage",
                  "Login Data", "Web Data", "History", "Preferences", "Network"] {
    precondition(protectedPaths.contains(guarded), "missing protected path \\(guarded)")
    precondition(!cachePaths.contains(guarded), "cache list touches \\(guarded)")
  }

  // (a) 當前設定檔的 CacheStorage 超標 → 被 dispose、不丟錯、結果列出目錄與 bytes。
  // (b) 登入態檔案的 mtime 與大小一個都不動。
  let single = try makeSetup(scratch, "cachestorage", now)
  let singleResult = try enforce(single, ceilingBytes: UInt64(7 * megabyte + slack))
  precondition(singleResult.evictedCacheDirectories == ["Service Worker/CacheStorage"],
    "unexpected cache eviction \\(singleResult.evictedCacheDirectories)")
  precondition(isAbout(singleResult.cacheBytesFreed, megabytes: 3),
    "unexpected freed bytes \\(singleResult.cacheBytesFreed)")
  precondition(isAbout(singleResult.bytesBefore, megabytes: 11))
  precondition(isAbout(singleResult.bytesAfter, megabytes: 6))
  precondition(isAbout(singleResult.currentProfileBytes, megabytes: 6))
  precondition(singleResult.evictedProfiles.count == 1
    && singleResult.evictedProfiles[0].profileIdentifier == archivedID)
  precondition(!FileManager.default.fileExists(
    atPath: at(single.currentURL, ["Service Worker", "CacheStorage"]).path))
  precondition(FileManager.default.fileExists(
    atPath: at(single.currentURL, ["Cache", "data-0"]).path))
  let singleAfter = try protectedStamps(single.currentURL)
  precondition(singleAfter == single.protectedBefore, "protected login state changed")
  precondition(single.disposals.urls.count == 2)

  // (a) 順序：仍超標就照 spec 順序往下清，不跳號。
  let pair = try makeSetup(scratch, "cache-order", now)
  let pairResult = try enforce(pair, ceilingBytes: UInt64(5 * megabyte + slack))
  precondition(
    pairResult.evictedCacheDirectories == ["Service Worker/CacheStorage", "Cache"],
    "unexpected order \\(pairResult.evictedCacheDirectories)")
  precondition(isAbout(pairResult.cacheBytesFreed, megabytes: 4))
  precondition(isAbout(pairResult.bytesAfter, megabytes: 5))
  let pairAfter = try protectedStamps(pair.currentURL)
  precondition(pairAfter == pair.protectedBefore)

  // (c) 連可重建快取都清光仍超標 → ceilingUnsatisfied，且不先破壞任何東西。
  let strict = try makeSetup(scratch, "still-over", now)
  let strictCeiling = UInt64(4 * megabyte + slack)
  var strictThrown = false
  var strictTotal: UInt64 = 0
  var strictLimit: UInt64 = 0
  do {
    _ = try enforce(strict, ceilingBytes: strictCeiling)
  } catch TatwoCEFProfileCeilingError.ceilingUnsatisfied(let total, let limit) {
    strictThrown = true
    strictTotal = total
    strictLimit = limit
  }
  precondition(strictThrown, "expected ceilingUnsatisfied")
  precondition(strictLimit == strictCeiling)
  precondition(isAbout(strictTotal, megabytes: 11))
  precondition(strict.disposals.urls.isEmpty, "fail-closed must not destroy data")
  let strictAfter = try protectedStamps(strict.currentURL)
  precondition(strictAfter == strict.protectedBefore)

  // (d) 其他設定檔的淘汰順序不變：孤兒最先，再來最久沒用的已封存設定檔。
  let orderRoot = try caseRoot(scratch, "profile-order")
  let orderStore = TatwoCEFProfileStore(rootCacheURL: orderRoot)
  for id in [currentID, archivedID, olderArchivedID, orphanID] {
    let url = try orderStore.profileURL(for: id, generation: 0)
    try writeFile(at(url, ["blob"]), megabytes: 1)
  }
  let orderDisposals = Disposals()
  let orderResult = try TatwoCEFProfileCeilingController(store: orderStore).enforce(
    byteCeiling: UInt64(megabyte + slack),
    currentIdentifier: currentID,
    activeIdentifiers: [],
    ledger: EmbeddedBrowserProfileCapacityLedger(entries: [
      entry(currentID, archived: false, accessed: now),
      entry(archivedID, archived: true, accessed: now.addingTimeInterval(-100)),
      entry(olderArchivedID, archived: true, accessed: now.addingTimeInterval(-200)),
    ]),
    leaseRegistry: TatwoCEFProfileLeaseRegistry(),
    removeLedgerRecord: { _ in },
    disposer: { url in
      orderDisposals.urls.append(url)
      try FileManager.default.removeItem(at: url)
    })
  precondition(
    orderResult.evictedProfiles.map(\\.profileIdentifier)
      == [orphanID, olderArchivedID, archivedID],
    "unexpected profile order \\(orderResult.evictedProfiles)")
  precondition(orderResult.evictedCacheDirectories.isEmpty)
  precondition(orderResult.cacheBytesFreed == 0)
  precondition(isAbout(orderResult.currentProfileBytes, megabytes: 1))

  print("W99 ceiling PASS cacheEvicted=\\(singleResult.evictedCacheDirectories) "
    + "freedMB=\\(singleResult.cacheBytesFreed / UInt64(megabyte)) "
    + "loginStateUntouched=true profileOrder=unchanged "
    + "failClosed=ceilingUnsatisfied; CEF runtime not simulated")
 }
}
`);
  assert.match(output, /W99 ceiling PASS/);
});

test('W99 ceiling constant is 2 GB and the management page reuses the same constant', () => {
  const constant = profile.match(
    /static let maximumCEFProfileBytes: UInt64 = ([^\n]+)/g) ?? [];
  assert.equal(constant.length, 1);
  assert.match(constant[0], /= 2 \* 1_024 \* 1_024 \* 1_024$/);
  // 管理頁與 provider 都吃同一個常數，不准出現第二個上限數字。
  for (const [name, text] of [['viewModel', managementModel], ['view', managementView]]) {
    const uses = text.match(
      /EmbeddedBrowserSessionPersistenceContract\s*\n?\s*\.maximumCEFProfileBytes/g) ?? [];
    assert.ok(uses.length >= 1, `${name} must read the shared ceiling constant`);
    assert.doesNotMatch(text, /512 \* 1_024 \* 1_024/);
    assert.doesNotMatch(text, /1_024 \* 1_024 \* 1_024/);
  }
});

test('W99 fail-closed message is plain Chinese and keeps the raw error for diagnosis', () => {
  assert.doesNotMatch(profile, /CEF profile capacity failed closed/);
  assert.doesNotMatch(profile, /Browser profile capacity failed closed/);
  assert.match(profile, /瀏覽器快取超過上限/);
  assert.match(profile, /設定 › 瀏覽器管理/);
  assert.match(profile, /ceilingUnsatisfied totalBytes=/);
  assert.match(profile, /case cefCeilingExceeded\(totalBytes: UInt64, byteCeiling: UInt64\)/);
});

test('W99 management page shows current profile size and the last cache eviction', () => {
  assert.match(backend, /struct TatwoCEFProfileCacheStatus: Codable, Equatable, Sendable/);
  assert.match(profile, /TatwoCEFProfileCacheStatus\.record\(result: ceilingResult\)/);
  assert.match(managementModel, /var cacheStatus: TatwoCEFProfileCacheStatus\? = nil/);
  assert.match(managementModel, /cacheStatus: TatwoCEFProfileCacheStatus\.load\(\)/);
  assert.match(managementView, /static func cacheStatusText\(/);
  assert.match(managementView, /browser-management-cache-status/);
});
