"""Inside-out signing; baseline reuse compares stripped copies, never source code."""
import hashlib
import os
import re
import plistlib
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


def run(*args, check=True):
    return subprocess.run(list(map(str, args)), check=check, capture_output=True)


def macho(p):
    if p.is_symlink() or not p.is_file():
        return False
    with p.open('rb') as f:
        return f.read(4) in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                             b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                             b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca')


def bundle(p):
    if not p.is_dir():
        return False
    if p.suffix in ('.app', '.framework'):
        return True
    return p.suffix in ('.xpc', '.appex', '.bundle', '.plugin') and any(
        f.is_file() and plistlib.loads(f.read_bytes()).get('CFBundleExecutable')
        for f in (p / 'Contents/Info.plist', p / 'Resources/Info.plist', p / 'Info.plist'))


def objects(root):
    paths = [root, *root.rglob('*')] if root.is_dir() else [root]
    return [p for p in paths if not p.is_symlink() and
            (macho(p) or bundle(p))]


def signer(p, work):
    prefix = work / 'cert'
    result = run('codesign', '-dvv', '--extract-certificates=' + str(prefix), p, check=False)
    if result.returncode:
        return None
    cert = Path(str(prefix) + '0')
    if b'Signature=adhoc' in result.stderr:
        return b'adhoc'
    return hashlib.sha256(cert.read_bytes()).digest() if cert.exists() else None


def policy(p):
    detail = run('codesign', '-dvv', p, check=False).stderr
    identifier = re.search(rb'^Identifier=(.*)$', detail, re.M)
    flags = re.search(rb'flags=0x([0-9a-f]+)', detail)
    ent = run('codesign', '-d', '--entitlements', ':-', p, check=False).stdout
    # 0x2=adhoc, 0x20000=linker-signed; keep hardened runtime (0x10000).
    return (identifier[1] if identifier else None,
            int(flags[1], 16) & ~0x20002 if flags else 0, ent)


def stripped(root):
    with tempfile.TemporaryDirectory(prefix='tatwo-unsigned-') as tmp:
        copy = Path(tmp) / root.name
        run('ditto', '--norsrc', root, copy)
        # Bundles first: remove their resource seal and executable signature together.
        for p in sorted(objects(copy), key=lambda p: len(p.parts)):
            if run('codesign', '-d', p, check=False).returncode == 0:
                seals = list(p.rglob('_CodeSignature/CodeResources')) if bundle(p) else []
                run('codesign', '--remove-signature', p)
                for seal in seals:
                    if not seal.exists() and seal.parent.is_dir() and not any(seal.parent.iterdir()):
                        seal.parent.rmdir()  # Only the now-empty seal directory in this scratch copy.
        # Removing a CMS can leave __LINKEDIT.vmsize enlarged. A fixed ad-hoc
        # round-trip on detached files canonicalizes that codesign-owned allocation.
        for p in objects(copy):
            if macho(p):
                detached = Path(tmp) / 'detached-code'
                shutil.copyfile(p, detached)
                run('codesign', '--force', '--sign', '-', '--identifier', 'tatwo-unsigned', detached)
                run('codesign', '--remove-signature', detached)
                shutil.copyfile(detached, p)
        h = hashlib.sha256()
        for p in sorted([copy, *copy.rglob('*')] if copy.is_dir() else [copy]):
            info = p.lstat()
            payload = os.readlink(p) if p.is_symlink() else None
            if p.is_file() and not p.is_symlink():
                content = hashlib.sha256()
                with p.open('rb') as f:
                    for chunk in iter(lambda: f.read(1048576), b''):
                        content.update(chunk)
                payload = content.hexdigest()
            h.update((repr((str(p.relative_to(copy)), stat.S_IFMT(info.st_mode),
                            stat.S_IMODE(info.st_mode), payload)) + '\n').encode())
        return h.digest()


def tree_identical(new_root, old_root, skip):
    """Byte/mode/link-identical trees, ignoring one top-level file name."""
    def snapshot(root):
        out = {}
        for p in root.rglob('*'):
            rel = p.relative_to(root).as_posix()
            if rel == skip:
                continue
            info = os.lstat(p)
            if stat.S_ISLNK(info.st_mode):
                out[rel] = ('link', os.readlink(p))
            elif stat.S_ISREG(info.st_mode):
                h = hashlib.sha256()
                with p.open('rb') as f:
                    for chunk in iter(lambda: f.read(1048576), b''):
                        h.update(chunk)
                out[rel] = ('file', stat.S_IMODE(info.st_mode), h.hexdigest())
            else:
                out[rel] = ('dir', stat.S_IMODE(info.st_mode))
        return out
    return snapshot(new_root) == snapshot(old_root)


def main():
    app, identity = Path(sys.argv[1]).absolute(), sys.argv[2]
    baseline_value = os.environ.get('TATWO2_RELEASE_BASELINE', '')
    baseline = Path(baseline_value) if os.path.isdir(baseline_value) else None
    contents = app / 'Contents'
    with tempfile.TemporaryDirectory(prefix='tatwo-signer-') as tmp:
        work = Path(tmp)
        probe = work / 'probe'
        shutil.copyfile('/usr/bin/true', probe)
        run('codesign', '--force', '--sign', identity, '--timestamp=none', probe)
        selected = signer(probe, work)
        assert selected, 'missing signing identity'

        def compatible(p, old, own):
            for code in objects(p):
                prior = old / code.relative_to(p) if p.is_dir() else old
                expected = selected if own else signer(code, work)
                if not expected or run('codesign', '--verify', '--deep', '--strict', prior, check=False).returncode or signer(prior, work) != expected:
                    return False
                new_policy, old_policy = policy(code), policy(prior)
                # Linker-generated identifiers can differ from codesign's default identifier.
                if own and b'linker-signed' in run('codesign', '-dvv', code, check=False).stderr:
                    new_policy, old_policy = new_policy[1:], old_policy[1:]
                if new_policy != old_policy:
                    return False
            return True

        def process(p, own):
            if p.is_symlink():
                return
            assert not any((contents / a).is_symlink() for a in p.relative_to(contents).parents), 'symlink candidate ancestor'
            old = baseline / 'Contents' / p.relative_to(contents) if baseline else None
            code = macho(p) or bundle(p)
            valid = code and run('codesign', '--verify', '--deep', '--strict', p, check=False).returncode == 0
            expected = selected if own else signer(p, work) if valid else b'adhoc'
            if valid and not own and bundle(p):
                assert expected and expected != b'adhoc', 'vendor bundle requires a persistent signing identity'
            if code and old is not None and old.exists() and not old.is_symlink() and expected:
                ancestors = old.relative_to(baseline).parents
                safe = not any((baseline / a).is_symlink() for a in ancestors)
                if safe and run('codesign', '--verify', '--deep', '--strict', old, check=False).returncode == 0 and signer(old, work) == expected:
                    # Entitlements are signature data, but must never silently roll back.
                    if compatible(p, old, own) and stripped(p) == stripped(old):
                        run('ditto', '--norsrc', old, p)
                        print('runtime reuse:', p.relative_to(contents), flush=True)
                        return
            if valid and not own:
                return  # Preserve a vendor bundle's seal as a unit when its content changed.
            if p.is_dir():
                for child in sorted(p.iterdir()):
                    process(child, own)
            if code and (own or not valid):
                run('codesign', '--force', '--sign', identity if own else '-', '--timestamp=none',
                    '--preserve-metadata=entitlements,flags,runtime', p)
                run('codesign', '--verify', '--strict', p)
                print('runtime sign:', p.relative_to(contents), flush=True)

        runtime_paths = [r for r in Path(__file__).with_name('runtime-layer.txt').read_text().splitlines() if r.strip() and not r.startswith('#')]
        for relative in runtime_paths:
            assert relative.startswith(('Resources/', 'Frameworks/')) and all(x not in ('', '.', '..') for x in relative.split('/')), 'invalid runtime path'
            process(contents / relative, relative.startswith('Frameworks/'))
        for helper in sorted((contents / 'Frameworks').glob('* Helper*.app')):
            process(helper, True)
        # npm's hidden lockfile drifts with the npm version while the installed tree stays identical
        # (2026-09-13: v2.0.6 promote changed only this file and forced a 450 MB runtime re-download).
        # Adopt the baseline bytes only when everything else under that node_modules is identical.
        if baseline:
            for lock in sorted(contents.rglob('node_modules/.package-lock.json')):
                relative = lock.relative_to(contents)
                if not any(relative.as_posix().startswith(r.rstrip('/') + '/') for r in runtime_paths):
                    continue
                old = baseline / 'Contents' / relative
                if lock.is_symlink() or old.is_symlink() or not (lock.is_file() and old.is_file()):
                    continue
                if lock.read_bytes() == old.read_bytes():
                    continue
                if tree_identical(lock.parent, old.parent, skip=lock.name):
                    shutil.copyfile(old, lock)
                    os.chmod(lock, stat.S_IMODE(os.lstat(old).st_mode))
                    print('runtime reuse:', relative, '(npm hidden lockfile; tree otherwise identical)', flush=True)


if __name__ == '__main__':
    main()
