import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).parents[1] / 'scripts/install-engines.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class EngineInstallTests(unittest.TestCase):
    def git(self, path, *args):
        return subprocess.check_output(['git', '-C', str(path), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def test_fetch_pinned_source_and_preserve_uncommitted_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin = root / 'origin'
            origin.mkdir()
            self.git(origin, 'init', '-b', 'main')
            self.git(origin, 'config', 'user.name', 'Test')
            self.git(origin, 'config', 'user.email', 'test@example.invalid')
            (origin / 'source.c').write_text('original\n')
            self.git(origin, 'add', 'source.c')
            self.git(origin, 'commit', '-m', 'Source')
            revision = self.git(origin, 'rev-parse', 'HEAD')
            sources = root / 'sources'
            sources.mkdir()
            repo = {'directory': 'component', 'revision': revision, 'url': str(origin)}
            path = installer.fetch_repository(repo, sources)
            self.assertEqual(self.git(path, 'rev-parse', 'HEAD'), revision)
            (path / 'source.c').write_text('local work\n')
            with self.assertRaisesRegex(installer.SetupError, 'uncommitted changes'):
                installer.fetch_repository(repo, sources)
            self.assertEqual((path / 'source.c').read_text(), 'local work\n')

    def test_existing_non_repository_and_symlink_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = {'directory': 'component', 'revision': 'a' * 40, 'url': 'https://github.com/example/component.git'}
            path = root / 'component'
            path.mkdir()
            (path / 'work.txt').write_text('keep')
            with self.assertRaisesRegex(installer.SetupError, 'not a Git repository'):
                installer.fetch_repository(spec, root)
            self.assertEqual((path / 'work.txt').read_text(), 'keep')
            link = root / 'link'
            link.symlink_to(path)
            with self.assertRaisesRegex(installer.SetupError, 'symbolic link'):
                installer.fetch_repository(dict(spec, directory='link'), root)

    def test_failed_signing_restores_installed_engine(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'GooseHUB.app'
            engines = app / 'Contents/Resources/Engines'
            engines.mkdir(parents=True)
            (engines / 'working.txt').write_text('working engine')
            staged = root / 'staging'
            staged.mkdir()
            (staged / 'new.txt').write_text('new engine')
            calls = []

            def sign(args, **kwargs):
                calls.append(args)
                if len(calls) == 1:
                    raise installer.SetupError('Signing failed')
                return ''

            with patch.object(installer, 'run', side_effect=sign):
                with self.assertRaisesRegex(installer.SetupError, 'Signing failed'):
                    installer.install(app, staged, {}, root / 'entitlements')
            self.assertEqual((engines / 'working.txt').read_text(), 'working engine')
            self.assertEqual((staged / 'new.txt').read_text(), 'new engine')
            self.assertFalse((app.parent / ('.' + app.name + '-Engines-previous')).exists())

    def test_checksum_failure_prevents_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in installer.REQUIRED:
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b'built')
                p.chmod(0o755)
            manifest = {'assets': [{'path': 'Wine/bin/wine', 'sha256': installer.digest(root / 'Wine/bin/wine')}]}
            installer.verify_runtime(root, manifest)
            (root / 'Wine/bin/wine').write_bytes(b'corrupt')
            with self.assertRaisesRegex(installer.SetupError, 'checksum failed'):
                installer.verify_runtime(root, manifest)


if __name__ == '__main__':
    unittest.main()
