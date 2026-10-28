import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'mod'))
import install
import game_path


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.game = Path(self.temp.name) / 'Game with spaces'
        self.exe = self.game / 'binaries/x64/helldivers.exe'
        self.exe.parent.mkdir(parents=True)
        self.exe.write_bytes(b'placeholder for filesystem tests, not a game')
        self.target = self.game / install.FOLDER

    def test_clean_install_only_writes_mod_subfolder(self):
        before = self.exe.read_bytes()
        target, backup = install.install(self.game)
        self.assertEqual(target, self.target)
        self.assertIsNone(backup)
        self.assertEqual(self.exe.read_bytes(), before)
        self.assertEqual({p.name for p in self.game.iterdir()}, {'binaries', install.FOLDER})
        for name, expected in install.manifest()['files'].items():
            self.assertEqual(install.digest(target / name), expected)

    def test_invalid_game_folder_does_not_write(self):
        wrong = Path(self.temp.name) / 'wrong'
        with self.assertRaises(ValueError):
            install.install(wrong)
        self.assertFalse(wrong.exists())

    def test_update_backs_up_managed_files_and_preserves_settings(self):
        install.install(self.game)
        settings = self.target / 'LoneSurvivor.settings.json'
        settings.write_text('{"custom":true}')
        _, backup = install.install(self.game)
        self.assertTrue((backup / 'squadmates.py').is_file())
        self.assertEqual(settings.read_text(), '{"custom":true}')

    def test_update_refuses_locally_edited_file(self):
        install.install(self.game)
        path = self.target / 'squadmates.py'
        path.write_text('my edits')
        with self.assertRaisesRegex(ValueError, 'edited'):
            install.install(self.game)
        self.assertEqual(path.read_text(), 'my edits')

    def test_refuses_unmanaged_existing_directory(self):
        self.target.mkdir()
        path = self.target / 'keep.txt'
        path.write_text('keep')
        with self.assertRaises(ValueError):
            install.install(self.game)
        self.assertEqual(path.read_text(), 'keep')

    def test_uninstall_preserves_settings_logs_and_game(self):
        install.install(self.game)
        settings = self.target / 'LoneSurvivor.settings.json'
        settings.write_text('keep')
        log = self.game / 'LoneSurvivor.log'
        log.write_text('keep')
        self.assertEqual(install.uninstall(self.game), [])
        self.assertEqual(settings.read_text(), 'keep')
        self.assertEqual(log.read_text(), 'keep')
        self.assertTrue(self.exe.is_file())
        self.assertFalse((self.target / 'squadmates.py').exists())

    def test_uninstall_keeps_edited_payload(self):
        install.install(self.game)
        path = self.target / 'squadmates.py'
        path.write_text('my edits')
        self.assertIn('squadmates.py', install.uninstall(self.game))
        self.assertEqual(path.read_text(), 'my edits')
        self.assertTrue((self.target / install.RECEIPT).is_file())

    def test_failed_install_rolls_back_written_files(self):
        original = install.shutil.copy2
        calls = []
        def fail_once(source, destination):
            calls.append(str(source))
            if len(calls) == 3:
                raise OSError('simulated disk failure')
            return original(source, destination)
        with patch.object(install.shutil, 'copy2', side_effect=fail_once):
            with self.assertRaises(OSError):
                install.install(self.game)
        self.assertFalse(self.target.exists())
        self.assertTrue(self.exe.exists())

    def test_manifest_rejects_path_traversal(self):
        package = Path(self.temp.name) / 'bad-package'
        package.mkdir()
        (package / 'manifest.json').write_text(json.dumps({
            'package': 'helldiver-bots', 'files': {'../outside.py': '0' * 64}}))
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            install.manifest(package)

    def test_failed_update_restores_previous_payload_and_receipt(self):
        install.install(self.game)
        before = {path.name: path.read_bytes() for path in self.target.iterdir()}
        original = install.shutil.copy2
        attempts = []
        def fail_once(source, destination):
            if Path(source).parent == ROOT / 'mod':
                attempts.append(str(source))
                if len(attempts) == 3:
                    raise OSError('simulated update disk failure')
            return original(source, destination)
        with patch.object(install.shutil, 'copy2', side_effect=fail_once):
            with self.assertRaises(OSError):
                install.install(self.game)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.target.iterdir()})

    def test_manifest_rejects_corrupted_payload(self):
        package = Path(self.temp.name) / 'bad-payload'
        (package / 'mod').mkdir(parents=True)
        (package / 'mod/file.py').write_text('changed')
        (package / 'manifest.json').write_text(json.dumps({
            'package': 'helldiver-bots', 'files': {'file.py': '0' * 64}}))
        with self.assertRaisesRegex(ValueError, 'changed'):
            install.manifest(package)

    def test_portable_paths_work_on_a_different_drive_and_folder(self):
        self.target.mkdir()
        self.assertEqual(game_path.game_directory(self.target), self.game)
        self.assertEqual(game_path.game_directory(self.game), self.game)

    def test_portable_paths_reject_missing_game(self):
        with self.assertRaisesRegex(RuntimeError, 'Install.bat'):
            game_path.game_directory(Path(self.temp.name) / 'no-game')


if __name__ == '__main__':
    unittest.main()
