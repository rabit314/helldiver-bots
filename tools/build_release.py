"""Build a mod-only release from an explicit file allowlist."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tools'))
from check_package import check

TOP_LEVEL = ['README.md', 'LICENSE', 'CHANGELOG.md', 'Install.bat', 'Uninstall.bat',
             'install.py', 'manifest.json', '.gitignore', '.gitattributes']
DOCUMENTS = ['docs/COMPATIBILITY.md', 'docs/DEVELOPING.md']
TOOLS = ['tools/build_release.py', 'tools/check_package.py']
TESTS = ['tests/test_install.py']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refresh-manifest', action='store_true')
    args = parser.parse_args()
    if args.refresh_manifest:
        files = {}
        for path in sorted((ROOT / 'mod').iterdir()):
            if path.is_file():
                if path.is_symlink() or path.suffix not in ('.lua', '.py', '.pyw', '.bat', '.ps1'):
                    raise ValueError('Refusing unexpected payload: ' + path.name)
                files[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        data = dict(package='helldiver-bots', ai_version='0.23.1', menu_version='3.6', files=files)
        (ROOT / 'manifest.json').write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    data = check()
    names = TOP_LEVEL + DOCUMENTS + TOOLS + TESTS + ['mod/' + name for name in data['files']]
    destination = ROOT / 'dist'
    destination.mkdir(exist_ok=True)
    name = f"helldiver-bots-{data['ai_version']}-menu{data['menu_version']}.zip"
    archive = destination / name
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zipped:
        for name in sorted(names):
            path = ROOT / name
            if path.is_symlink():
                raise ValueError('Refusing link: ' + name)
            zipped.write(path, arcname='helldiver-bots/' + name)
    with zipfile.ZipFile(archive) as zipped:
        if zipped.testzip() or set(zipped.namelist()) != {'helldiver-bots/' + name for name in names}:
            raise ValueError('Archive readback failed.')
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(checksum + '  ' + archive.name + '\n', encoding='ascii')
    print(f'Built {archive.name}: {archive.stat().st_size:,} bytes; {len(names)} files.')
    print('SHA-256: ' + checksum)


if __name__ == '__main__':
    main()
