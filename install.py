"""Install only the manifest-listed mod files; never copy or patch game assets."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent
PACKAGE = 'helldiver-bots'
FOLDER = 'HelldiverBots'
RECEIPT = '.installed.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(root=ROOT):
    data = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    if data.get('package') != PACKAGE or not data.get('files'):
        raise ValueError('Invalid package manifest.')
    for name, expected in data['files'].items():
        if Path(name).name != name or '/' in name or '\\' in name or name.startswith('.'):
            raise ValueError('Unsafe manifest filename.')
        path = root / 'mod' / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError('Missing or changed package file: ' + name)
    return data


def destination(game):
    game = Path(game).resolve()
    if not (game / 'binaries/x64/helldivers.exe').is_file():
        raise ValueError('Select the HELLDIVERS folder containing binaries/x64/helldivers.exe.')
    target = game / FOLDER
    if target.is_symlink() or target.resolve() != target:
        raise ValueError('The mod folder must not be a link or junction.')
    return game, target


def read_receipt(target):
    path = target / RECEIPT
    if path.is_symlink():
        raise ValueError('The installation receipt must not be a link.')
    if not path.is_file():
        raise ValueError('This folder is not a managed HELLDIVERS Bots installation.')
    data = json.loads(path.read_text(encoding='utf-8'))
    if data.get('package') != PACKAGE or not isinstance(data.get('files'), dict):
        raise ValueError('Invalid installation receipt.')
    return data


def install(game, root=ROOT):
    data = manifest(root)
    game, target = destination(game)
    existed = target.exists()
    old = None
    if existed:
        old = read_receipt(target)
        for name in data['files']:
            path = target / name
            if path.exists() or path.is_symlink():
                if path.is_symlink() or not path.is_file() or name not in old['files']:
                    raise ValueError('Unmanaged file would be replaced: ' + name)
                if digest(path) != old['files'][name]:
                    raise ValueError('Keep your edited file before updating: ' + str(path))
    target.mkdir(exist_ok=True)
    backup = None
    if existed:
        stamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-%fZ')
        backup = game / 'HelldiverBots_Backups' / stamp
        if backup.parent.is_symlink() or backup.parent.resolve() != backup.parent:
            raise ValueError('The backup folder must not be a link or junction.')
        backup.mkdir(parents=True)
        for name in [*data['files'], RECEIPT]:
            path = target / name
            if path.is_file():
                shutil.copy2(path, backup / name)
    written = []
    try:
        for name, expected in data['files'].items():
            written.append(name)
            shutil.copy2(root / 'mod' / name, target / name)
            if digest(target / name) != expected:
                raise OSError('Installed file did not verify: ' + name)
        written.append(RECEIPT)
        (target / RECEIPT).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    except Exception:
        for name in reversed(written):
            path = target / name
            if backup and (backup / name).is_file():
                shutil.copy2(backup / name, path)
            elif path.is_file():
                path.unlink()
        if not existed and not any(target.iterdir()):
            target.rmdir()
        raise
    return target, backup


def uninstall(game, root=ROOT):
    data = manifest(root)
    _, target = destination(game)
    receipt = read_receipt(target)
    kept = []
    for name in data['files']:
        path = target / name
        if path.is_symlink() or (path.exists() and
                (not path.is_file() or digest(path) != receipt['files'].get(name))):
            kept.append(name)
        elif path.is_file():
            path.unlink()
    if not kept:
        (target / RECEIPT).unlink()
        if not any(target.iterdir()):
            target.rmdir()
    return kept


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir', type=Path, help='Game root; omit to open a folder picker')
    parser.add_argument('--uninstall', action='store_true')
    parser.add_argument('--check', action='store_true', help='Verify the download without installing')
    args = parser.parse_args()
    gui = None
    try:
        data = manifest()
        if args.check:
            print(f"Verified {len(data['files'])} mod files. AI {data['ai_version']}, menu {data['menu_version']}.")
            return 0
        if not args.game_dir:
            import tkinter as tk
            from tkinter import filedialog, messagebox
            gui = tk.Tk()
            gui.withdraw()
            action = 'Remove' if args.uninstall else 'Install'
            messagebox.showinfo('HELLDIVERS Bots', action + ' HELLDIVERS Bots.\n\n'
                'Close the game and all mod menus first. Select the game folder '\
                'containing binaries/x64/helldivers.exe.\n\n'
                'In Steam: game Properties > Installed Files > Browse.')
            selected = filedialog.askdirectory(title=action + ' HELLDIVERS Bots - select game folder')
            if not selected:
                return 0
            args.game_dir = Path(selected)
        if args.uninstall:
            kept = uninstall(args.game_dir)
            message = 'Mod files removed. Settings, logs and backups are preserved.'
            if kept:
                message += '\nEdited files were kept: ' + ', '.join(kept)
                message += '\nRemove those manually after keeping any changes you need.'
        else:
            target, backup = install(args.game_dir)
            message = f'Installed successfully.\n\nOpen {target / "Launch_Mod_Menu.bat"}\n'
            message += '\nLaunch your game normally. Enter a solo mission, then tap F6.'
            if backup:
                message += f'\nPrevious mod files: {backup}'
        print(message)
        if gui:
            messagebox.showinfo('HELLDIVERS Bots', message)
        return 0
    except Exception as exc:
        print('Installation error: ' + str(exc), file=sys.stderr)
        if gui:
            from tkinter import messagebox
            messagebox.showerror('HELLDIVERS Bots', str(exc))
        return 1
    finally:
        if gui:
            gui.destroy()


if __name__ == '__main__':
    raise SystemExit(main())
