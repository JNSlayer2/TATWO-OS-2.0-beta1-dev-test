import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const root = resolve(import.meta.dirname, '..');
test('W26 candidate gates reject each failed check on a fake bundle, including reverse DR', () => {
  const dir=mkdtempSync(join(tmpdir(),'w26-package-'));
  const code=`
import importlib.util, pathlib, plistlib, subprocess
spec=importlib.util.spec_from_file_location('gates', ${JSON.stringify(join(root,'scripts/package-release-gates.py'))})
g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
root=pathlib.Path(${JSON.stringify(dir)})
app=root/'candidate.app'; base=root/'previous.app'
for p in [app,base]:
 (p/'Contents').mkdir(parents=True)
 (p/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'2.0.6','CFBundleIdentifier':'ai.tatwo.tatwo2'}))
for failure in ['none','baseline','version','adhoc','signature','dr-read','dr-forward','dr-reverse','gatekeeper','ticket','dr-string','development']:
 calls=[]
 def run(*args):
  args=tuple(map(str,args)); calls.append(args)
  bad=(failure=='signature' and args[:2]==('codesign','--verify') or
   failure=='dr-read' and args[:2]==('codesign','-dr') or
   failure=='dr-forward' and '-R' in args and args[-1]==str(app) or
   failure=='dr-reverse' and '-R' in args and args[-1]==str(base) or
   failure in ('gatekeeper','development') and args[0]=='spctl' or failure in ('ticket','development') and args[0]=='xcrun')
  if bad: raise subprocess.CalledProcessError(1,args)
  text='Signature=adhoc' if failure=='adhoc' and args[:2]==('codesign','-dv') else ('Authority=Apple Development: fixture' if failure=='development' else 'Authority=Developer ID Application: fixture') if args[:2]==('codesign','-dvv') else 'designated => identifier "fixture"'
  return subprocess.CompletedProcess(args,0,stdout='',stderr=text)
 g.run=run
 try:
  g.candidate(app,'v2.0.7' if failure=='version' else 'v2.0.6', '' if failure=='baseline' else 'different' if failure=='dr-string' else str(base))
 except (ValueError,subprocess.CalledProcessError):
  assert failure not in ('none','development'),failure
 else: assert failure in ('none','development'),failure
print('12 candidate scenarios PASS')
`;
  const r=spawnSync('python3',['-E','-c',code],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr); assert.match(r.stdout,/12 candidate scenarios PASS/);
});

test('W26 archive gates fail closed for each unpack/verify/difference gate and bind actual hashes', () => {
  const dir=mkdtempSync(join(tmpdir(),'w26-archives-'));
  const code=`
import importlib.util, pathlib, json, subprocess, hashlib
spec=importlib.util.spec_from_file_location('gates', ${JSON.stringify(join(root,'scripts/package-release-gates.py'))})
g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
root=pathlib.Path(${JSON.stringify(dir)})
for failure in ['none','full-unpack','app-unpack','runtime-unpack','nested-signature','full-signature','assembled-signature','difference','manifest','runtime-count']:
 out=root/failure; out.mkdir()
 for name in ['TATWO-OS.zip','TATWO-OS-app.zip','TATWO-OS-runtime-123456789abc.zip','TATWO-OS.manifest.json']:
  if failure=='manifest' and name.endswith('.json'): continue
  (out/name).write_text(name)
 if failure=='runtime-count': (out/'TATWO-OS-runtime-abcdefabcdef.zip').write_text('duplicate')
 def extract(archive,target):
  kind='full' if archive.name=='TATWO-OS.zip' else 'app' if archive.name=='TATWO-OS-app.zip' else 'runtime'
  if failure==kind+'-unpack': raise ValueError(kind)
  if kind=='runtime':
   (target/'Frameworks').mkdir(parents=True); (target/'Frameworks/F.framework').mkdir()
  else:
   resources=target/'TATWO OS.app/Contents/Resources'; resources.mkdir(parents=True)
   (resources/'runtime-layer.json').write_text(json.dumps({'paths':['Frameworks/F.framework']}))
 def run(*args):
  if failure=='nested-signature' and args[0]=='codesign': raise ValueError('nested signature')
 def candidate(app,*args):
  if failure==('full-signature' if 'full' in app.parts else 'assembled-signature'): raise ValueError('seal')
 g.train.inspect_archive=lambda p:None
 g.train.extract=extract; g.run=run; g.candidate=candidate
 g.train.delta.manifest=lambda app,*args: {'files':str(app)} if failure=='difference' else {'files':[]}
 try: g.archives(out,'v2.0.6','fixture')
 except ValueError:
  assert failure!='none',failure
  assert not (out/'TATWO-OS.install-ready').exists(),failure
 else:
  assert failure=='none',failure
  for line in (out/'TATWO-OS.install-ready').read_text().splitlines():
   digest,name=line.split(); assert hashlib.sha256((out/name).read_bytes()).hexdigest()==digest
print('10 archive scenarios PASS')
`;
  const r=spawnSync('python3',['-E','-c',code],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr); assert.match(r.stdout,/10 archive scenarios PASS/);
});

test('W26 actual package shell never exposes output or gh command on candidate/archives failure', () => {
  for (const gate of ['candidate','archives']) {
    const dir=mkdtempSync(join(tmpdir(),'w26-shell-gate-'));
    mkdirSync(join(dir,'scripts')); mkdirSync(join(dir,'bin'));
    copyFileSync(join(root,'scripts/package-release.sh'),join(dir,'scripts/package-release.sh'));
    writeFileSync(join(dir,'scripts/build-app.sh'),'mkdir -p "$1/tatwo2.app"\n');
    writeFileSync(join(dir,'scripts/runtime-layer.sh'),'touch "$3/TATWO-OS-app.zip" "$3/TATWO-OS-runtime-123456789abc.zip"\n');
    writeFileSync(join(dir,'scripts/per-file-delta.py'),'');
    writeFileSync(join(dir,'scripts/package-release-gates.py'),`import sys\nraise SystemExit(1 if sys.argv[1]==${JSON.stringify(gate)} else 0)\n`);
    for (const [cmd,body] of Object.entries({codesign:'exit 0',xattr:'exit 0',unzip:'echo TATWO\\ OS.app/Contents/Info.plist',ditto:'touch "\${@: -1}"'})) {
      writeFileSync(join(dir,'bin',cmd),`#!/bin/bash\n${body}\n`,{mode:0o755});
    }
    const out=join(dir,'release');
    const r=spawnSync('bash',[join(dir,'scripts/package-release.sh'),out],{encoding:'utf8',env:{...process.env,PATH:join(dir,'bin')+':'+process.env.PATH,TATWO_OS_VERSION:'v2.0.6.001',TATWO2_SIGN_IDENTITY:'fixture',TATWO2_RELEASE_BASELINE:'fixture',TATWO_OS_DELTA_FROM:'none'}});
    assert.notEqual(r.status,0); assert.ok(!existsSync(out)); assert.doesNotMatch(r.stdout,/gh release create/);
  }
});
