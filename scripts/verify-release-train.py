"""Fail-closed release verification; retain extracted evidence, never alter source bundles."""
import importlib.util
import json
from pathlib import Path
import plistlib
import posixpath
import stat
import re
import subprocess
import sys
import unicodedata
import zipfile

spec = importlib.util.spec_from_file_location('delta', Path(__file__).with_name('per-file-delta.py'))
delta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delta)


def checksums(root):
    files = [p for p in root.iterdir() if p.is_file()]
    assert files and (root / 'TATWO-OS.zip').is_file(), 'missing full archive'
    for p in files:
        if p.suffix == '.sha256':
            assert p.with_suffix('').is_file(), 'orphan checksum'
            continue
        checksum = p.with_name(p.name + '.sha256')
        # install-ready is a coordination marker, not an integrity anchor.
        if p.name == 'TATWO-OS.install-ready' and not checksum.exists():
            continue
        text = checksum.read_text().strip()
        match = re.fullmatch(r'([0-9a-fA-F]{64})\s+\*?(.+)', text)
        assert match and match[2] == p.name and delta.digest(p) == match[1].lower(), 'checksum mismatch'


def inspect_archive(archive):
    listing = subprocess.check_output(['unzip', '-Z1', str(archive)])
    assert not any(b'/._' in n or n.startswith(b'._') for n in listing.splitlines()), 'AppleDouble'
    with zipfile.ZipFile(archive) as z:
        names, links = set(), set()
        canonical = lambda name: unicodedata.normalize("NFD", name).casefold()
        for entry in z.infolist():
            name = entry.filename.rstrip('/')
            assert name and not name.startswith('/') and all(p not in ('', '.', '..') for p in name.split('/')), 'unsafe archive'
            key = canonical(name)
            assert key not in names, 'duplicate or case-colliding archive entry'
            names.add(key)
            # Check local-header consistency and CRC before ditto sees the archive.
            with z.open(entry) as stream:
                while stream.read(1048576):
                    pass
            if stat.S_ISLNK(entry.external_attr >> 16):
                assert entry.file_size <= 4096, 'invalid link'
                target = z.read(entry).decode('utf-8')
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                assert target and not target.startswith('/') and resolved != '..' and not resolved.startswith('../'), 'escaping link'
                links.add(key)
        for name in names:
            parts = name.split('/')
            assert all('/'.join(parts[:i]) not in links for i in range(1, len(parts))), 'symlink ancestor'


def extract(archive, out):
    inspect_archive(archive)
    delta.run('ditto', '-x', '-k', archive, out)


def signed(app):
    delta.run('codesign', '--verify', '--deep', '--strict', app)
    details = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True, check=True)
    assert 'Signature=adhoc' not in details.stderr + details.stdout, 'ad-hoc signature'
    dr = subprocess.run(['codesign', '-dr', '-', str(app)], capture_output=True, text=True, check=True)
    lines = [s for s in (dr.stdout + dr.stderr).splitlines() if s.startswith('designated => ')]
    assert len(lines) == 1, 'missing DR'
    return lines[0]


def verify(root, previous, base, tag):
    checksums(root)
    checksums(previous)
    extract(previous / 'TATWO-OS.zip', previous / 'extracted')
    for archive in root.glob('*.zip'):
        inspect_archive(archive)  # Includes optional delta; no archive bypasses the same static gates.
    extract(root / 'TATWO-OS.zip', root / 'full')
    extract(root / 'TATWO-OS-app.zip', root / 'assembled')
    runtime = list(root.glob('TATWO-OS-runtime-*.zip'))
    assert len(runtime) == 1, 'runtime must be unique'
    assembled = root / 'assembled/TATWO OS.app'
    extract(runtime[0], assembled / 'Contents')
    full = root / 'full/TATWO OS.app'
    for app, version in [(full, tag), (assembled, tag), (previous / 'extracted/TATWO OS.app', base)]:
        with (app / 'Contents/Info.plist').open('rb') as f:
            info = plistlib.load(f)
        assert info['CFBundleShortVersionString'] == version.removeprefix('v'), 'version binding'
        assert info['CFBundleIdentifier'] == 'ai.tatwo.tatwo2', 'bundle identity'
    requirement = signed(previous / 'extracted/TATWO OS.app')
    assert signed(full) == signed(assembled) == requirement, 'DR must be byte-identical'
    produced = json.loads((root / 'TATWO-OS.manifest.json').read_text())
    # The previous public release may predate manifests (v2.0.5 and earlier): fromTag is then empty.
    assert produced.get('fromTag') in ('', base), 'manifest/fromTag mismatch'
    expected = delta.manifest(full, tag, produced.get('fromTag', ''))
    assert delta.manifest(assembled, tag, produced.get('fromTag', '')) == expected, 'offline assembly differs'
    assert produced == expected, 'manifest/fromTag mismatch'
    (root / 'verification.txt').write_text('codesign deep/strict PASS\nDR exact PASS\napp+runtime offline 0 differences\nAppleDouble 0\n')


if __name__ == '__main__':
    if sys.argv[1] == 'checksums':
        checksums(Path(sys.argv[2]))
    else:
        verify(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5])
