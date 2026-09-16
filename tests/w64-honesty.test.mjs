import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, symlinkSync, utimesSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const fixtureRoot = mkdtempSync(join(tmpdir(), 'w64-honesty-'));
after(() => {
  writeFileSync(join(fixtureRoot, 'RESTORE.md'), '# Synthetic W64 fixtures\nSource: ' + fixtureRoot + '\nReason: only synthetic test data and compiled test executables, no user data. Restore with Trash > Put Back. Permanent removal requires independent review.\n');
  const r = spawnSync('/usr/bin/trash', [fixtureRoot], {encoding:'utf8'});
  assert.equal(r.status, 0, r.stderr);
});
const root = () => mkdtempSync(join(fixtureRoot, 'case-'));
function compile(source) {
  const dir = root(), file = join(dir,'main.swift'), bin = join(dir,'fixture');
  writeFileSync(file,source);
  const r = spawnSync('swiftc',['-parse-as-library',file,'-o',bin],{encoding:'utf8',timeout:60000});
  assert.equal(r.status,0,r.stderr); return bin;
}
const stubs = read('App/Sources/Tatwo2/Facade/DevicesStubs.swift');
test('W64 A production inventory: each unavailable field stays nil, real dispatch pressure levels, interval CPU and sysctl truth', () => {
  const models = stubs.slice(stubs.indexOf('enum TatwoHostMemoryPressureLevelV1'), stubs.indexOf('// HOST-INVENTORY-COLLECTOR-BEGIN'));
  const collector = stubs.split('// HOST-INVENTORY-COLLECTOR-BEGIN\n')[1].split('// HOST-INVENTORY-COLLECTOR-END')[0];
  const bin = compile(`import Foundation\nimport Darwin\n${models}\n${collector}\n@main struct Main {
    static func main() throws {
      typealias C = TatwoDeviceHostInventoryCollector
      let absent = C.Sources(string:{ _ in nil },memorySize:{nil},pressure:{nil},cpu:{nil})
      let empty = C.collectOnce(sources:absent)!
      precondition(empty.hardwareModel == nil && empty.chipName == nil && empty.ramTotalBytes == nil)
      precondition(empty.cpuPercent == nil && empty.memoryPressureLevel == nil && empty.activeLoopCount == nil)
      for field in 0..<5 {
        var keys = [String]()
        let value = C.collectOnce(activeLoopCount:0, sources:.init(string:{ name in
          keys.append(name)
          if name == "hw.model" { return field == 0 ? nil : "FixtureModel" }
          if name == "machdep.cpu.brand_string" { return field == 1 ? nil : "FixtureChip" }
          preconditionFailure("unexpected fallback query")
        },memorySize:{field == 2 ? nil : 123456},pressure:{field == 3 ? nil : 2},cpu:{field == 4 ? nil : 37.5}))!
        precondition(value.hardwareModel == (field == 0 ? nil : "FixtureModel"))
        precondition(value.chipName == (field == 1 ? nil : "FixtureChip"))
        precondition(value.ramTotalBytes == (field == 2 ? nil : 123456))
        precondition(value.memoryPressureLevel == (field == 3 ? nil : .warn))
        precondition(value.cpuPercent == (field == 4 ? nil : 37.5) && value.activeLoopCount == 0)
        precondition(Set(keys) == Set(["hw.model","machdep.cpu.brand_string"]))
      }
      for bad in [Double.nan, .infinity, -1, 101] {
        let value = C.collectOnce(sources:.init(string:{_ in " "},memorySize:{0},pressure:{3},cpu:{bad}))!
        precondition(value.hardwareModel == nil && value.chipName == nil && value.ramTotalBytes == nil && value.cpuPercent == nil && value.memoryPressureLevel == nil)
      }
      precondition(C.memoryPressureLevel(1) == .normal && C.memoryPressureLevel(2) == .warn && C.memoryPressureLevel(4) == .critical)
      precondition(C.memoryPressureLevel(0) == nil && C.memoryPressureLevel(99) == nil)
      let sampler = C.CPUSampler()
      func ticks(_ u:UInt32,_ s:UInt32,_ i:UInt32,_ n:UInt32) -> C.CPUSampler.Ticks { .init(user:u,system:s,idle:i,nice:n) }
      precondition(sampler.sample(read:{ticks(0,0,0,0)}) == nil)
      precondition(sampler.sample(read:{ticks(20,10,70,0)}) == 30)
      precondition(sampler.sample(read:{ticks(20,10,70,0)}) == nil)
      precondition(sampler.sample(read:{nil}) == nil)
      precondition(sampler.sample(read:{ticks(20,10,70,0)}) == nil)
      precondition(sampler.sample(read:{ticks(20,10,80,0)}) == 0)
      let wrap = C.CPUSampler()
      precondition(wrap.sample(read:{ticks(.max,.max,.max,.max)}) == nil)
      precondition(wrap.sample(read:{ticks(0,0,0,0)}) == 75)
      let live = C.collectOnce()!
      precondition(live.cpuPercent == nil)
      Thread.sleep(forTimeInterval:0.1)
      let second = C.collectOnce()!
      if let cpu = second.cpuPercent { precondition(cpu.isFinite && (0...100).contains(cpu)) }
      print(String(decoding:try JSONEncoder().encode(live),as:UTF8.self))
    }
  }`);
  const r=spawnSync(bin,[],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
  const actual=JSON.parse(r.stdout);
  for(const [field,key] of [['hardwareModel','hw.model'],['chipName','machdep.cpu.brand_string'],['ramTotalBytes','hw.memsize']]) {
    const p=spawnSync('/usr/sbin/sysctl',['-n',key],{encoding:'utf8'});
    if(p.status===0) assert.equal(String(actual[field]),p.stdout.trim()); else assert.equal(actual[field],undefined);
  }
});
test('W64 A grep forbids fabricated specifications in the runtime stub; fresh nils cannot be refilled from snapshots', () => {
  const r=spawnSync('/usr/bin/grep',['-En','Mac16,10|Apple M4|24[[:space:]]*GB|24[[:space:]]*\\*[[:space:]]*1_024|25_769_803_776|25769803776|cpuPercent:[[:space:]]*12','App/Sources/Tatwo2/Facade/DevicesStubs.swift'],{encoding:'utf8'});
  assert.equal(r.status,1,r.stdout+r.stderr);
  const src=read('App/Sources/Tatwo2/Pages/DevicesComposition.swift');
  const merge=src.slice(src.indexOf('    static func mergedHostInventory('),src.indexOf('    static func identityCards('));
  assert.match(merge,/if let collected \{ return collected.isEmpty \? nil : collected \}/);
  assert.doesNotMatch(merge,/collected\?\.[\w]+\s*\?\?/);
  const display=src.slice(src.indexOf('    static func localInventoryForDisplay()'),src.indexOf('struct DevicesIdentityCardModel'));
  assert.match(display,/if isActive\(\) \{ return localInventory\(\) \}/);
  assert.doesNotMatch(display,/\?\? localInventory\(\)/);
  assert.doesNotMatch(stubs,/hostInventory: DevicesExportSyncFixture.localInventory\(\)/);
});
test('W64 A production hardware summary displays dashes for unavailable fields', () => {
  const src=read('App/Sources/Tatwo2/Pages/DevicesComposition.swift');
  const start=src.indexOf('    static func hardwareLine(');
  const end=src.indexOf('\n    }',start)+6;
  const formatter=src.slice(start,end);
  const bin=compile(`import Foundation
    enum Presentation { ${formatter} }
    @main struct Main { static func main() {
      precondition(Presentation.hardwareLine(model:nil,chip:nil,ramLabel:nil) == "—")
      precondition(Presentation.hardwareLine(model:"FixtureModel",chip:nil,ramLabel:"8 GB") == "FixtureModel · — · 8 GB")
      precondition(Presentation.hardwareLine(model:" ",chip:"FixtureChip",ramLabel:nil) == "— · FixtureChip · —")
    } }`);
  const r=spawnSync(bin,[],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
});
const install=read('install.sh');
const hygiene=install.split('# UPDATE-ARCHIVE-HYGIENE-BEGIN\n')[1].split('# UPDATE-ARCHIVE-HYGIENE-END')[0];
const transaction=install.split('# TRANSACTION-BEGIN\n')[1].split('# TRANSACTION-END')[0];
function setup() {
  const dir=root(), archives=join(dir,'Library/Application Support/TATWO OS/UpdateArchives');
  mkdirSync(archives,{recursive:true}); mkdirSync(join(dir,'trash')); mkdirSync(join(dir,'Applications'));
  return {dir,archives};
}
function shell(code,fixture,extra={}) {
  return spawnSync('/bin/bash',['-c',`set -eu\n${transaction}\n${hygiene}\ntrash() {
    # 產品碼會先把路徑解析成實體路徑再丟棄（防符號連結逃逸），所以守門也要比實體路徑。
    # 否則在預設 macOS（TMPDIR 位於 /var -> /private/var 連結下）這個替身必定誤判。
    local target archroot
    target="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
    archroot="$(cd "$ARCHIVES" && pwd -P)"
    [[ "$target" == "$archroot/"* && ! -L "$1" ]] || exit 90
    mv "$1" "$HOME/trash/"
  }\n${code}`],{encoding:'utf8',env:{...process.env,HOME:fixture.dir,ARCHIVES:fixture.archives,DEST:join(fixture.dir,'Applications/App.app'),...extra}});
}
function directory(parent,name,time=100) {
  const p=join(parent,name); mkdirSync(p); writeFileSync(join(p,'delta.app.disabled.part-1'),'synthetic partial'); utimesSync(p,time,time); return p;
}
function backup(path) {
  mkdirSync(join(path,'previous.app.disabled/Contents'),{recursive:true});
  writeFileSync(join(path,'previous.app.disabled/Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2</string></dict></plist>');
}
const dirs=p=>readdirSync(p,{withFileTypes:true}).filter(e=>e.isDirectory()).map(e=>e.name).sort();
test('W64 B 52-directory legacy fixture retains one failed diagnosis and the real backup, not delta chunks', () => {
  const f=setup();
  for(let i=0;i<45;i++) directory(f.archives,`failed-.tatwo-update.f${i}.noindex`,100+i);
  for(let i=0;i<6;i++) directory(f.archives,`.tatwo-update.s${i}.noindex`,100+i);
  const old=directory(f.archives,'.tatwo-update.old.noindex',100); backup(old);
  assert.equal(dirs(f.archives).length,52);
  const r=shell('retain_update_archives',f); assert.equal(r.status,0,r.stderr);
  const remaining=dirs(f.archives); assert.equal(remaining.length,2);
  assert.ok(remaining.includes('failed-.tatwo-update.f44.noindex'));
  const saved=remaining.find(n=>n.startsWith('.tatwo-update.backup.')); assert.ok(saved);
  assert.ok(existsSync(join(f.archives,saved,'previous.app.disabled/Contents/Info.plist')));
  assert.ok(!existsSync(join(f.archives,saved,'delta.app.disabled.part-1')));
  assert.equal(dirs(join(f.dir,'trash')).length,51);
  assert.match(readFileSync(join(f.archives,'cleanup-manifest.md'),'utf8'),/Restore: macOS Trash/);
});
test('W64 B only the two newest validated backup directories survive', () => {
  const f=setup();
  for(let i=0;i<5;i++) { const d=directory(f.archives,`.tatwo-update.backup.b${i}.noindex`); backup(d); utimesSync(d,100+i,100+i); }
  const r=shell('retain_update_archives',f); assert.equal(r.status,0,r.stderr);
  assert.deepEqual(dirs(f.archives),['.tatwo-update.backup.b3.noindex','.tatwo-update.backup.b4.noindex']);
});
test('W64 B rejects outside, sibling, nested, symlink and non-updater paths; preserves unknown and live material', () => {
  const f=setup(), outside=directory(f.dir,'outside'), nested=directory(f.archives,'user-data');
  const nestedStage=directory(nested,'.tatwo-update.nested.noindex');
  const link=join(f.archives,'.tatwo-update.link.noindex'); symlinkSync(outside,link);
  const live=directory(f.archives,'failed-.tatwo-update.live.noindex'); writeFileSync(join(live,'owner'),`${process.pid}\n`);
  const bad=directory(f.archives,'.tatwo-update.unrecognized-backup.noindex'); symlinkSync(outside,join(bad,'previous.app.disabled'));
  const sibling=directory(f.dir,'UpdateArchives-sibling');
  const spoofedRoot=directory(f.dir,'.tatwo-update.outside-root');
  const r=shell(`for item in "$OUTSIDE" "$ARCHIVES" "$ARCHIVES/../UpdateArchives-sibling" "$SIBLING" "$LINK" "$NESTED" "$NESTED_STAGE"; do
    if trash_update_archive "$ARCHIVES" "$item" fixture; then exit 91; fi
  done
  if trash_update_archive "$HOME" "$SPOOFED_ROOT" fixture; then exit 92; fi
  retain_update_archives`,f,{OUTSIDE:outside,SIBLING:sibling,LINK:link,NESTED:nested,NESTED_STAGE:nestedStage,SPOOFED_ROOT:spoofedRoot});
  assert.equal(r.status,0,r.stderr);
  for(const p of [outside,sibling,link,nested,nestedStage,live,bad,spoofedRoot]) assert.ok(existsSync(p),p);
  assert.deepEqual(dirs(join(f.dir,'trash')),[]);
  const other=setup(), home=root(); mkdirSync(join(home,'Library/Application Support'),{recursive:true});
  symlinkSync(join(other.dir,'Library/Application Support/TATWO OS'),join(home,'Library/Application Support/TATWO OS'));
  const denied=shell('retain_update_archives',{...other,dir:home}); assert.notEqual(denied.status,0);
  assert.deepEqual(dirs(other.archives),[]);
  const linkedHome=root(); mkdirSync(join(linkedHome,'Library/Application Support/TATWO OS'),{recursive:true});
  symlinkSync(other.archives,join(linkedHome,'Library/Application Support/TATWO OS/UpdateArchives'));
  assert.notEqual(shell('retain_update_archives',{...other,dir:linkedHome}).status,0);
});
test('W64 B EXIT success/failure retires only its own stage and keeps the latest failure', () => {
  for(const success of [true,false]) {
    const f=setup(), parent=join(f.dir,'Applications');
    const stage=directory(parent,'.tatwo-update.own.noindex'), foreign=directory(parent,'.tatwo-update.foreign.noindex');
    mkdirSync(join(stage,'download')); writeFileSync(join(stage,'download/package.zip'),'synthetic');
    for(let i=0;i<3;i++) directory(f.archives,`failed-.tatwo-update.old${i}.noindex`,1);
    if(success) backup(stage);
    const cleanup=install.slice(install.indexOf('cleanup() {'),install.indexOf('trap cleanup EXIT'));
    const r=shell(`${cleanup}\nSTAGE="$OWN"; LOCK=""; PREVIOUS=""; REPLACED=0; COMMITTED=${success?1:0}; trap cleanup EXIT; exit ${success?0:17}`,f,{OWN:stage});
    assert.equal(r.status,success?0:17,r.stderr); assert.ok(!existsSync(stage)); assert.ok(existsSync(foreign));
    const remaining=dirs(f.archives), failures=remaining.filter(n=>n.startsWith('failed-'));
    assert.equal(failures.length,1);
    if(!success) assert.equal(failures[0],'failed-.tatwo-update.own.noindex');
    else assert.equal(remaining.filter(n=>n.startsWith('.tatwo-update.backup.')).length,1);
  }
});
test('W64 B app gates selected archive bytes before payload download; named safety budget and Island notice are wired', () => {
  const src=read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
  const prefetch=src.slice(src.indexOf('    private func prefetch(tag:'));
  assert.ok(prefetch.indexOf('candidateBytes += archive.size')<prefetch.indexOf('let folder ='));
  assert.ok(prefetch.indexOf('try checkSpace()')<prefetch.indexOf('let folder ='));
  assert.match(src,/archiveSafetyMultiplier: Int64 = 2/);
  assert.match(src,/IslandNotice.shared.info\(title: "無法開始更新", detail: error.localizedDescription\)/);
  assert.match(src,/待接 todo #25 治理器的磁碟保留額/);
  assert.match(install,/UPDATE_FAILED_RETENTION=1/); assert.match(install,/UPDATE_BACKUP_RETENTION=2/);
  assert.match(install,/TEMP="\$STAGE\/download"/);
  assert.equal(install,read('public/install.sh'));
});

test('W64 B legacy backup ordering preserves subsecond recency and cleanup failure keeps recoverable data', () => {
  const f=setup();
  for(let i=0;i<3;i++) {
    const d=directory(f.archives,`.tatwo-update.legacy${i}`); backup(d);
    writeFileSync(join(d,'previous.app.disabled/Contents/version'),String(i));
    utimesSync(d,100+i/10,100+i/10);
  }
  let r=shell('retain_update_archives',f); assert.equal(r.status,0,r.stderr);
  assert.deepEqual(dirs(f.archives).map(n=>readFileSync(join(f.archives,n,'previous.app.disabled/Contents/version'),'utf8')).sort(),['1','2']);
  const scratch=directory(f.archives,'.tatwo-update.failed-cleanup');
  r=shell('trash() { return 12; }; retain_update_archives',f);
  assert.notEqual(r.status,0); assert.ok(existsSync(scratch));
});
