"""Behavior tests using synthetic apps and command doubles; never touches host apps/TCC."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]

class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tatwo-update-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apps = self.root / 'Applications'
        self.apps.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.root),
                        PATH=str(self.bin) + ':' + os.environ['PATH'])
        self.app = self.root / 'payload' / 'TATWO OS.app'
        self.make_app(self.app, 'trusted', 'new')
        self.dest = self.apps / 'TATWO OS.app'
        self.make_app(self.dest, 'trusted', 'old')
        self.stub('plistbuddy', 'cat "${@: -1}" | head -1')
        self.stub('codesign', '''app="${@: -1}"
identity=$(cat "$app/identity")
case "$1" in
  -dv) [[ "$identity" != adhoc ]] || { echo Signature=adhoc >&2; exit 0; }; echo Signature=persistent >&2 ;;
  -dr) echo "designated => $identity" >&2 ;;
  --verify)
    [[ "$identity" != broken ]] || exit 1
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -R ]]; then shift; [[ "$1" == "$identity" ]] || exit 1; fi
      shift
    done ;;
esac
''')
        self.stub('pgrep', '[[ "${RUNNING:-0}" == 1 ]]')
        self.stub('spctl', '[[ "${DENY_FIRST:-0}" != 1 ]]')
        self.stub('lsregister', 'exit 0')
        self.stub('open', '[[ "${FAIL_OPEN:-0}" != 1 ]]')
        self.stub('ditto', '[[ "${FAIL_COPY:-0}" != 1 ]] || exit 1; cp -R "$1" "$2"')
        self.stub('curl', '''out=""
for ((i=1;i<=$#;i++)); do
  if [[ "${!i}" == -o ]]; then j=$((i+1)); out="${!j}"; fi
done
case "$out" in
  */release.json) cp "$FIXTURE/release.json" "$out"; printf 200 ;;
  *.sha256) cp "$FIXTURE/archive.sha256" "$out" ;;
  *.zip) cp "$FIXTURE/archive.zip" "$out" ;;
esac
''')
        self.stub('plutil', '''case "$2" in
assets.0.name) echo TATWO-OS.zip ;;
assets.1.name) echo TATWO-OS.zip.sha256 ;;
assets.0.browser_download_url) echo https://github.com/tatwo214/TATWO-OS-2.0-beta1-dev-test/releases/download/v1/TATWO-OS.zip ;;
assets.1.browser_download_url) echo https://github.com/tatwo214/TATWO-OS-2.0-beta1-dev-test/releases/download/v1/TATWO-OS.zip.sha256 ;;
*) exit 1 ;;
esac
''')
        self.env['FIXTURE'] = str(self.root)
        (self.root / 'release.json').write_text(json.dumps({}))
        installer = (ROOT / 'install.sh').read_text()
        installer = installer.replace('/Applications', str(self.apps))
        # Restore user-relative Applications paths after replacing system paths.
        installer = installer.replace('$HOME' + str(self.apps), '$HOME/Applications')
        installer = installer.replace('/usr/libexec/PlistBuddy', str(self.bin / 'plistbuddy'))
        installer = installer.replace('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', str(self.bin / 'lsregister'))
        self.installer = self.root / 'install.sh'
        self.installer.write_text(installer)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\nset -e\n' + body + '\n')
        path.chmod(0o755)

    def make_app(self, path, identity, version):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_text('ai.tatwo.tatwo2\n')
        (path / 'identity').write_text(identity)
        (path / 'version').write_text(version)

    def install(self, success):
        archive = self.root / 'archive.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            for path in self.app.rglob('*'):
                z.write(path, path.relative_to(self.app.parent))
        (self.root / 'archive.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  TATWO-OS.zip\n')
        result = subprocess.run(['bash', str(self.installer)], env=self.env, capture_output=True, text=True, errors="backslashreplace")
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertFalse((self.apps / '.tatwo-update.lock').exists())
        return result

    def assert_old(self):
        self.assertEqual((self.dest / 'version').read_text(), 'old')

    def test_two_updates_keep_unique_backups(self):
        self.install(True)
        (self.app / 'version').write_text('newer')
        self.install(True)
        self.assertEqual((self.dest / 'version').read_text(), 'newer')
        backups = list(self.home.rglob('previous.app.disabled'))
        self.assertEqual(len(backups), 2)
        self.assertEqual({(p / 'version').read_text() for p in backups}, {'old', 'new'})

    def test_changed_identity_rejected(self):
        (self.app / 'identity').write_text('different')
        self.install(False)
        self.assert_old()

    def test_adhoc_rejected(self):
        (self.app / 'identity').write_text('adhoc')
        self.install(False)
        self.assert_old()

    def test_legacy_adhoc_rejected(self):
        (self.dest / 'identity').write_text('adhoc')
        self.install(False)
        self.assert_old()

    def test_wrong_bundle_id_rejected(self):
        (self.app / 'Contents/Info.plist').write_text('other.app\n')
        self.install(False)
        self.assert_old()

    def test_broken_signature_rejected(self):
        (self.app / 'identity').write_text('broken')
        self.install(False)
        self.assert_old()

    def test_duplicate_rejected(self):
        self.make_app(self.home / 'Applications/tatwo2.app', 'trusted', 'duplicate')
        self.install(False)
        self.assert_old()

    def test_running_app_rejected(self):
        self.env['RUNNING'] = '1'
        self.install(False)
        self.assert_old()

    def test_copy_failure_preserves_old(self):
        self.env['FAIL_COPY'] = '1'
        self.install(False)
        self.assert_old()

    def test_launch_failure_rolls_back(self):
        self.env['FAIL_OPEN'] = '1'
        self.install(False)
        self.assert_old()
        self.assertEqual(len(list(self.apps.rglob('failed.app.disabled'))), 1)

    def test_first_install_requires_gatekeeper(self):
        self.dest.rename(self.root / 'old-fixture')
        self.env['DENY_FIRST'] = '1'
        self.install(False)
        self.assertFalse(self.dest.exists())

    def test_first_install_launch_failure_retains_candidate(self):
        self.dest.rename(self.root / 'old-fixture')
        self.env['FAIL_OPEN'] = '1'
        self.install(False)
        self.assertFalse(self.dest.exists())
        self.assertEqual(len(list(self.apps.rglob('failed.app.disabled'))), 1)

    def test_build_rejects_missing_or_adhoc_identity_before_building(self):
        for identity in ['', '-']:
            env = dict(self.env, TATWO2_SIGN_IDENTITY=identity)
            result = subprocess.run(['bash', 'scripts/build-app.sh'], cwd=ROOT, env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'persistent signing identity', result.stderr)

    def test_first_install_accepted(self):
        self.dest.rename(self.root / 'old-fixture')
        self.install(True)
        self.assertEqual((self.dest / 'version').read_text(), 'new')

    def test_release_identity_gate(self):
        gate = (ROOT / 'scripts/verify-update-identity.sh').read_text().replace('/usr/libexec/PlistBuddy', str(self.bin / 'plistbuddy'))
        path = self.root / 'gate.sh'
        path.write_text(gate)
        for identity, expected in [('trusted', 0), ('different', 1), ('adhoc', 1), ('broken', 1)]:
            (self.app / 'identity').write_text(identity)
            result = subprocess.run(['bash', str(path), str(self.dest), str(self.app)], env=self.env, capture_output=True)
            self.assertEqual(result.returncode == 0, expected == 0, identity)

    def test_public_entrypoints_match(self):
        self.assertEqual((ROOT / 'install.sh').read_bytes(), (ROOT / 'public/install.sh').read_bytes())

if __name__ == '__main__':
    unittest.main(verbosity=2)
