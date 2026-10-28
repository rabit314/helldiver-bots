"""Offline public-package checks. Never starts or attaches to a game process."""
import importlib.util
from pathlib import Path
import re
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'mod'))
import install


def check(root=ROOT):
    data = install.manifest(root)
    expected = set(data['files'])
    actual = {p.name for p in (root / 'mod').iterdir() if p.is_file()}
    if actual != expected:
        raise ValueError('Payload/manifest mismatch: ' + str(actual ^ expected))
    for name in expected:
        path = root / 'mod' / name
        if path.suffix not in ('.lua', '.py', '.pyw', '.bat', '.ps1'):
            raise ValueError('Unexpected payload type: ' + name)
        source = path.read_text(encoding='utf-8')
        if re.search(r'[A-Za-z]:\\(?:Users|Games|Work)\\', source):
            raise ValueError('Machine-specific path: ' + name)
        if path.suffix in ('.py', '.pyw'):
            compile(source, str(path), 'exec')
    compile((root / 'install.py').read_text(encoding='utf-8'), 'install.py', 'exec')
    import game_path
    with patch.object(game_path, 'game_directory', return_value=root):
        spec = importlib.util.spec_from_file_location('package_squadmates', root / 'mod/squadmates.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    commands = {name: getattr(module, 'ai_' + name + '_command')()
                for name in ('module', 'control', 'recovery', 'task', 'tactics', 'readiness', 'mobility', 'equipment')}
    commands['runtime'] = module.ai_command(True, seed=2147483646, auto_deploy=True, target_count=3)
    lengths = {name: len(command.encode('utf-8')) for name, command in commands.items()}
    if any(size >= module.SOURCE_LIMIT for size in lengths.values()):
        raise ValueError('Lua stage exceeds bridge capacity.')
    print(f"Verified {len(expected)} payload files; Python syntax and all nine loader sizes pass.")
    print('Stage bytes: ' + ', '.join(f'{name}={size}' for name, size in lengths.items()))
    return data


if __name__ == '__main__':
    check()
