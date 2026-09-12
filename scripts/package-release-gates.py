"""Candidate-bound gates. Failures retain hidden work; never publish partial output."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

spec = importlib.util.spec_from_file_location('train', Path(__file__).with_name('verify-release-train.py'))
train = importlib.util.module_from_spec(spec)
spec.loader.exec_module(train)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True)


def identity(app):
    run('codesign', '--verify', '--deep', '--strict', app)
    detail = run('codesign', '-dv', app)
    require('Signature=adhoc' not in detail.stdout + detail.stderr, 'ad-hoc')
    dr = run('codesign', '-dr', '-', app)
    lines = [s.removeprefix('designated => ') for s in (dr.stdout + dr.stderr).splitlines() if s.startswith('designated => ')]
    require(len(lines) == 1 and lines[0], 'missing DR')
    return lines[0]


def candidate(app, version, baseline):
    require(baseline, 'TATWO2_RELEASE_BASELINE is required')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info['CFBundleShortVersionString'] == version.removeprefix('v'), 'version binding')
    require(info['CFBundleIdentifier'] == 'ai.tatwo.tatwo2', 'bundle identifier')
    dr = identity(app)
    if Path(baseline).is_dir():
        old = identity(Path(baseline))
        run('codesign', '--verify', '--deep', '--strict', '-R', '=' + old, app)
        run('codesign', '--verify', '--deep', '--strict', '-R', '=' + dr, baseline)
    else:
        # No old executable exists to evaluate the reverse requirement against.
        # Require exact DR equality (stronger than attempting to infer equivalence).
        old = baseline.removeprefix('designated => ')
        require(dr == old, 'DR string baseline must be identical')
        run('codesign', '--verify', '--deep', '--strict', '-R', '=' + old, app)
        run('codesign', '--verify', '--deep', '--strict', '-R', '=' + dr, app)
    # Gatekeeper assessment and a stapled ticket exist only for notarized Developer ID builds.
    # Apple Development identities cannot be notarized; the installer's continuity check still binds them.
    detail = run('codesign', '-dvv', app)
    if 'Authority=Developer ID Application' in detail.stdout + detail.stderr:
        run('spctl', '--assess', '--type', 'execute', app)
        run('xcrun', 'stapler', 'validate', app)
    else:
        print('notice: not a Developer ID build; Gatekeeper/stapler gates skipped', file=sys.stderr)


def archives(root, version, baseline):
    runtime = list(root.glob('TATWO-OS-runtime-*.zip'))
    require(len(runtime) == 1, 'unique runtime')
    work = root / '.gates'
    work.mkdir()
    for archive in root.glob('*.zip'):
        train.inspect_archive(archive)
    train.extract(root / 'TATWO-OS.zip', work / 'full')
    train.extract(root / 'TATWO-OS-app.zip', work / 'app')
    train.extract(runtime[0], work / 'runtime')
    full = work / 'full/TATWO OS.app'
    assembled = work / 'app/TATWO OS.app'
    # Split app is deliberately incomplete; runtime roots are not standalone apps.
    # Check each nested Mach-O/bundle seal, then both layers' complete outer seal.
    for p in (work / 'runtime').rglob('*'):
        if p.suffix in ('.app', '.framework', '.dylib') and not p.is_symlink():
            run('codesign', '--verify', '--deep', '--strict', p)
    meta = json.loads((assembled / 'Contents/Resources/runtime-layer.json').read_text())
    for path in meta['paths']:
        run('ditto', work / 'runtime' / path, assembled / 'Contents' / path)
    candidate(full, version, baseline)
    candidate(assembled, version, baseline)
    require(train.delta.manifest(full, version, '') == train.delta.manifest(assembled, version, ''), 'offline assembly differs')
    assets = sorted(p for p in root.iterdir() if p.is_file() and (p.suffix == '.zip' or p.name == 'TATWO-OS.manifest.json'))
    require(any(p.name == 'TATWO-OS.manifest.json' for p in assets), 'missing manifest')
    ready = ''.join(f'{train.delta.digest(p)}  {p.name}\n' for p in assets)
    (root / 'TATWO-OS.install-ready').write_text(ready)
    (root / 'TATWO-OS.install-ready.sha256').write_text(f'{train.delta.digest(root / "TATWO-OS.install-ready")}  TATWO-OS.install-ready\n')


if __name__ == '__main__':
    mode, path, version = sys.argv[1:]
    (candidate if mode == 'candidate' else archives)(Path(path), version, os.environ.get('TATWO2_RELEASE_BASELINE', ''))
