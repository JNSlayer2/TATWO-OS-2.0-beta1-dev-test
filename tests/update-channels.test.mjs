import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const checker = read('App/Sources/Tatwo2/Facade/GitHubReleaseUpdateChecker.swift');
const updater = read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
const installer = read('scripts/install-private.sh');
const promote = read('scripts/promote-release.sh');
const verify = read('scripts/verify-release-train.py');

test('production Swift four-component precedence, malformed/overflow boundaries and channel credential isolation', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w25-swift-'));
  const code = checker;
  writeFileSync(join(dir, 'main.swift'), code + `
@MainActor final class InAppUpdater {
  static let shared = InAppUpdater()
  func prefetch(to: String, repository: String) {}
  func invalidateCandidate() {}
}
struct GitHubAccountRecord { let username: String }
struct GitHubAccountsStore {
  func loadAccounts() throws -> [GitHubAccountRecord] { [] }
  func mcpToken(username: String) throws -> String? { nil }
}
let ordered = ["2.0.5", "2.0.5.001", "2.0.5.002", "2.0.5.010", "2.0.5.999", "2.0.6"]
for (i,a) in ordered.enumerated() { for (j,b) in ordered.enumerated() {
  precondition(ReleaseVersionCompare.isNewer(b, than:a) == (j > i), a + " / " + b)
}}
for pair in [("2.0","2.0.0.000"), ("2.0.5.001","v2.0.5.1"), ("2.0.5+build","2.0.5")] {
 precondition(!ReleaseVersionCompare.isNewer(pair.0, than:pair.1))
 precondition(!ReleaseVersionCompare.isNewer(pair.1, than:pair.0))
}
precondition(ReleaseVersionCompare.isNewer("2.0.5.100000000000000000000000000000000", than:"2.0.5.99999999999999999999999999999999"))
precondition(ReleaseVersionCompare.isNewer("2.0.5.001", than:"2.0.5.001-beta"))
for bad in ["", "1", "1.2.3.4.5", "1..3", "1.02.3", "1.2.3.-1", "1.2.3\\n", "../1.2", "1.2.3-alpha.01"] {
 precondition(!ReleaseVersionCompare.isValid(bad), bad)
}
for marker in [false,true] { for token: String? in [nil,"","fixture-credential"] {
 let channel = UpdateChannel(requestedPrivate:marker, username:"fixture", token:token)
 precondition(channel.isPrivate == (marker && token?.isEmpty == false))
 for url in ["https://api.github.com/repos/tatwo214/TATWO-OS-2.0-private/releases/assets/42", "https://api.github.com/repos/demo/public/releases", "https://example.invalid/repos/tatwo214/TATWO-OS-2.0-private/releases", "http://api.github.com/repos/tatwo214/TATWO-OS-2.0-private/releases"] {
  var request = URLRequest(url:URL(string:url)!)
  channel.authorize(&request)
  precondition((request.value(forHTTPHeaderField:"Authorization") != nil) == (channel.isPrivate && url.hasPrefix("https://api.github.com/repos/tatwo214/TATWO-OS-2.0-private/")))
 }
}}
print("version and channel PASS")
`);
  let r = spawnSync('swiftc', ['-num-threads','2',join(dir,'main.swift'),'-o',join(dir,'probe')], {encoding:'utf8',timeout:120000});
  assert.equal(r.status,0,r.stderr);
  r = spawnSync(join(dir,'probe'),[],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
  assert.doesNotMatch(r.stdout, /fixture-credential/);
});

test('private downloads use asset IDs; credentials stay out of resume files/helper and cross-host redirects', () => {
  assert.match(updater, /releases\/assets\/\\\(id\)/);
  assert.match(updater, /application\/octet-stream/);
  assert.match(updater, /channel.authorize\(&request\)/);
  assert.match(updater, /let resume = authenticated \? nil/);
  assert.match(updater, /if let data, !authenticated/);
  assert.match(updater, /request.url\?\.host != task.originalRequest\?\.url\?\.host[\s\S]*setValue\(nil, forHTTPHeaderField: "Authorization"\)/);
  const helper = updater.slice(updater.indexOf('// UPDATE-HELPER-BEGIN'));
  assert.doesNotMatch(helper, /Bearer|GH_TOKEN|channel.token/);
  assert.match(installer, /security find-generic-password -s tatwo2-github/);
  assert.match(installer, /gh release download/);
  assert.match(installer, /set \+x/);
  assert.match(installer, /unset GH_DEBUG/);
  assert.doesNotMatch(installer, /echo.*GH_TOKEN|printf.*GH_TOKEN|--token/);
});

test('public default endpoint and draft/prerelease filter unchanged; private labels are conditional', () => {
  assert.match(checker, /defaultRepository = "tatwo214\/TATWO-OS-2.0-beta1-dev-test"/);
  assert.match(checker, /releases\/latest/);
  assert.match(checker, /!release.draft && !release.prerelease/);
  assert.match(checker, /私人通道需要 GitHub 登入/);
  assert.match(checker, /tatwo2\/os\/update-channel/);
  assert.match(checker, /if isPrivateChannel != channel.isPrivate \{ availableRelease = nil \}/);
  assert.match(checker, /contents\/scripts\/install-private.sh\?ref=\\\(tag\)/);
  assert.match(checker, /TATWO_OS_VERSION=/);
  assert.doesNotMatch(checker, /ref=beta1\/integration/);
  const card = read('App/Sources/Tatwo2/New/UpdateAvailableCard.swift');
  assert.equal((card.match(/checker.isPrivateChannel \? "私人通道 · "/g) || []).length,2);
  assert.match(read('scripts/public-export.sh'), /\['scripts\/install-private.sh', 'scripts\/promote-release.sh', 'scripts\/withdraw-release.sh'\].includes\(file\)/);
});

test('promote rejects absent authorization and non-TTY before side effects; public package denied', () => {
  for (const args of [[],['v2.0.5.001','v2.0.6'],['v2.0.5.001','v2.0.6','--i-authorize']]) {
    const r = spawnSync('bash',['scripts/promote-release.sh',...args],{encoding:'utf8'});
    assert.equal(r.status,1); assert.match(r.stderr,/--i-authorize.*TTY/);
  }
  const r=spawnSync('bash',['scripts/package-release.sh'],{encoding:'utf8',env:{...process.env,TATWO_OS_VERSION:'v2.0.6',TATWO_OS_PROMOTE:''}});
  assert.equal(r.status,1); assert.match(r.stderr,/公開版只能由 promote 產生/);
});

test('promote revalidates before staging/publication; withdraw preserves recovery material', () => {
  for (const text of ['git status --porcelain','git/ref/tags/$FROM','git diff --quiet "$SHA" "$HEAD" -- "${APP_PATHS[@]}"','TATWO_OS_VERSION="$VERSION"','TATWO_OS_DELTA_FROM="$BASE"','--exclude-pre-releases','read -r ANSWER','verify-release-train.py verify','--repo "$PUBLIC" --draft=false --latest']) assert.ok(promote.includes(text),text);
  assert.ok(promote.indexOf('verify-release-train.py verify') < promote.indexOf('gh release create'));
  for(const text of ["'--verify', '--deep', '--strict'",'signed(full) == signed(assembled) == requirement','delta.manifest(assembled, tag, produced.get(\'fromTag\', \'\')) == expected',"['unzip', '-Z1'",'checksum mismatch']) assert.ok(verify.includes(text),text);
  const withdraw=read('scripts/withdraw-release.sh');
  assert.ok(withdraw.indexOf('gh release download') < withdraw.indexOf('gh release delete-asset'));
  assert.match(withdraw,/RESTORE.md/); assert.match(withdraw,/--prerelease --latest=false/);
});

test('release-train checksum verifier executes and rejects corrupt artifacts', () => {
  const root=mkdtempSync(join(tmpdir(),'w25-checksum-'));
  writeFileSync(join(root,'TATWO-OS.zip'),'fixture');
  writeFileSync(join(root,'TATWO-OS.zip.sha256'),'0'.repeat(64)+'  TATWO-OS.zip\n');
  let r=spawnSync('python3',['scripts/verify-release-train.py','checksums',root],{encoding:'utf8'});
  assert.notEqual(r.status,0); assert.match(r.stderr,/checksum mismatch/);
  const sha=spawnSync('shasum',['-a','256',join(root,'TATWO-OS.zip')],{encoding:'utf8'}).stdout.split(' ')[0];
  writeFileSync(join(root,'TATWO-OS.zip.sha256'),sha+'  TATWO-OS.zip\n');
  r=spawnSync('python3',['scripts/verify-release-train.py','checksums',root],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);
});

test('private installer executes authenticated adapter with tag-pinned shared guards and no public network', () => {
  const dir=mkdtempSync(join(tmpdir(),'w25-private-'));
  const shared=read('install.sh').split('# RUNTIME-ASSEMBLY-BEGIN')[0];
  writeFileSync(join(dir,'install.sh'), shared + '\ncurl -o "$TEMP/archive.zip" "$ZIP_URL"\n');
  const url='https://github.com/tatwo214/TATWO-OS-2.0-private/releases/download/v2.0.5.001/';
  writeFileSync(join(dir,'release.json'),JSON.stringify({tag_name:'v2.0.5.001',draft:false,prerelease:false,assets:
    ['TATWO-OS.zip','TATWO-OS.zip.sha256','TATWO-OS.install-ready'].map(name=>({name,browser_download_url:url+name}))}));
  const r=spawnSync('bash',['-c',`
set -euo pipefail
security() { printf '%s' fixture-memory-only; }
gh() {
  [[ "$GH_TOKEN" == fixture-memory-only ]] || return 91
  printf '%s\\n' "$*" >> "$FIXTURE/calls"
  if [[ "$1" == api && "$2" == *contents/install.sh* ]]; then cat "$FIXTURE/install.sh"
  elif [[ "$1" == api && "$2" == *releases/tags/* ]]; then cat "$FIXTURE/release.json"
  elif [[ "$1 $2" == 'release download' ]]; then
    while [[ $# -gt 0 ]]; do if [[ "$1" == --output ]]; then shift; printf bytes > "$1"; fi; shift; done
  else return 92; fi
}
export -f gh security
TATWO_OS_VERSION=v2.0.5.001 TATWO_OS_GITHUB_USERNAME=fixture bash scripts/install-private.sh
`],{encoding:'utf8',env:{...process.env,FIXTURE:dir,GH_DEBUG:'api'}});
  assert.equal(r.status,0,r.stderr);
  const calls=readFileSync(join(dir,'calls'),'utf8');
  assert.match(calls,/contents\/install.sh\?ref=v2.0.5.001/);
  assert.match(calls,/release download v2.0.5.001 --repo tatwo214\/TATWO-OS-2.0-private/);
  assert.doesNotMatch(calls+r.stdout+r.stderr,/fixture-memory-only|beta1-dev-test/);
});

test('promote verifier executes offline layer assembly and exact DR gate on disposable sealed fixtures', () => {
  const root=mkdtempSync(join(tmpdir(),'w25-verify-'));
  // Only fixture -dv identity presentation is mocked; deep/strict verification and DR are real codesign.
  const script=String.raw`
import importlib.util, json, os, plistlib, subprocess, sys
from pathlib import Path
root=Path(sys.argv[1]); repo=Path.cwd()
def run(*args): subprocess.run(list(map(str,args)),check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
spec=importlib.util.spec_from_file_location('train',repo/'scripts/verify-release-train.py'); train=importlib.util.module_from_spec(spec); spec.loader.exec_module(train)
paths=(repo/'scripts/runtime-layer.txt').read_text().splitlines()
for version,folder in [('9.9.8','previous'),('9.9.9','release')]:
    out=root/folder; out.mkdir(); app=out/'source/TATWO OS.app'; c=app/'Contents'; (c/'MacOS').mkdir(parents=True)
    run('cp','/usr/bin/true',c/'MacOS/tatwo2')
    for p in paths:
        target=c/p; target.mkdir(parents=True)
        if p.startswith('Frameworks/'):
            (target/'Resources').mkdir(); target=target/'Resources'
        (target/'fixture').write_text('runtime bytes')
    # A real framework must have a bundle identity and executable to seal deeply.
    fw=c/'Frameworks/Chromium Embedded Framework.framework'
    run('cp','/usr/bin/true',fw/'fixture-executable')
    (fw/'Resources/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='example.fixture.runtime',CFBundleExecutable='fixture-executable',CFBundlePackageType='FMWK')))
    run('codesign','--force','--sign','-',fw)
    (c/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='ai.tatwo.tatwo2',CFBundleExecutable='tatwo2',CFBundlePackageType='APPL',CFBundleShortVersionString=version)))
    run('bash','scripts/runtime-layer.sh','prepare',app)
    run('codesign','--force','--sign','-','--requirements','=designated => identifier "ai.tatwo.tatwo2"',app)
    run('ditto','-c','-k','--norsrc','--keepParent',app,out/'TATWO-OS.zip'); train.delta.checksum(out/'TATWO-OS.zip')
    if folder=='release':
        run('bash','scripts/runtime-layer.sh','split',app,out)
        meta=out/'TATWO-OS.manifest.json'; meta.write_text(json.dumps(train.delta.manifest(app,'v9.9.9','v9.9.8'))); train.delta.checksum(meta)
# Original production policy rejects these ad-hoc fixtures.
try: train.signed(root/'release/source/TATWO OS.app')
except AssertionError as e: assert 'ad-hoc' in str(e)
else: raise AssertionError('ad-hoc accepted')
bin=root/'bin'; bin.mkdir(); shim=bin/'codesign'
shim.write_text('#!/bin/bash\nif [[ "$1" == -dv ]]; then echo "Authority=Fixture" >&2; else exec /usr/bin/codesign "$@"; fi\n'); shim.chmod(0o755)
os.environ['PATH']=str(bin)+':'+os.environ['PATH']
train.verify(root/'release',root/'previous','v9.9.8','v9.9.9')
assert 'offline 0 differences' in (root/'release/verification.txt').read_text()
# A previous public release without a manifest yields fromTag ''; any other fromTag is rejected.
import shutil
meta=root/'release/TATWO-OS.manifest.json'
for from_tag,ok in [('',True),('v0.0.1',False)]:
    meta.write_text(json.dumps(train.delta.manifest(root/'release/source/TATWO OS.app','v9.9.9',from_tag))); train.delta.checksum(meta)
    for d in [root/'release/full',root/'release/assembled',root/'previous/extracted']: shutil.rmtree(d,ignore_errors=True)
    (root/'release/verification.txt').unlink(missing_ok=True)
    try: train.verify(root/'release',root/'previous','v9.9.8','v9.9.9')
    except AssertionError as e: assert (not ok) and 'fromTag' in str(e), (from_tag,str(e))
    else: assert ok, from_tag
# A DR change is blocked even though both individual bundles remain validly signed.
other=root/'other.app'; run('ditto',root/'release/source/TATWO OS.app',other)
run('codesign','--force','--sign','-','--requirements','=designated => identifier "different.fixture"',other)
assert train.signed(other) != train.signed(root/'previous/extracted/TATWO OS.app')
`;
  const r=spawnSync('python3',['-c',script,root],{encoding:'utf8',timeout:60000});
  assert.equal(r.status,0,r.stderr);
});

test('promote archive validation rejects macOS case/Unicode collisions before extraction', () => {
  const dir=mkdtempSync(join(tmpdir(),'w25-case-'));
  const script=String.raw`
import importlib.util, sys, zipfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('train',Path('scripts/verify-release-train.py')); train=importlib.util.module_from_spec(spec); spec.loader.exec_module(train)
root=Path(sys.argv[1])
for i, names in enumerate([['App/Foo.txt','App/foo.txt'], ['App/é.txt','App/e\u0301.txt']]):
    z=root/str(i)
    with zipfile.ZipFile(z,'w') as archive:
        for name in names: archive.writestr(name,'fixture')
    try: train.extract(z,root/('out'+str(i)))
    except AssertionError as e: assert 'case-colliding' in str(e)
    else: raise AssertionError('collision accepted')
    assert not (root/('out'+str(i))).exists()
`;
  const r=spawnSync('python3',['-c',script,dir],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
  assert.match(promote,/PUBLIC_TARGET=.*git\/ref\/heads\/main/);
  assert.match(promote,/--target "\$PUBLIC_TARGET"/);
  assert.match(verify,/for archive in root.glob\('\*\.zip'\):\s+inspect_archive\(archive\)/);
  assert.match(verify,/with z.open\(entry\) as stream:/);
});
