# Development

## Layout

- `mod/`: runtime Python/Lua and the installed launcher. All runtime dependencies are Python's standard library or APIs provided by the installed game.
- `install.py`, `Install.bat`, `Uninstall.bat`: isolated install/remove entry points.
- `manifest.json`: SHA-256 allowlist of distributable runtime files.
- `tests/`: installer and portable path tests using temporary fake game folders. No actual game process is started or attached.
- `tools/`: package verification and ZIP generation.

## Offline checks

Use Python 3.10+:

```console
python install.py --check
python -m unittest discover -s tests -v
python tools/check_package.py
```

After deliberately editing runtime files, regenerate the manifest and build:

```console
python tools/build_release.py --refresh-manifest
```

For an unchanged checkout:

```console
python tools/build_release.py
```

The result is `dist/helldiver-bots-0.23.1-menu3.6.zip` and its SHA-256 checksum. The builder uses an explicit allowlist; it does not archive the workspace or the installed game. A source download from GitHub also contains a usable installer and the same mod files.

## Command-line installation

Close the game and mod menus first:

```console
python install.py --game-dir "D:\SteamLibrary\steamapps\common\Helldivers"
python install.py --uninstall --game-dir "D:\SteamLibrary\steamapps\common\Helldivers"
```

Game-root validation checks the expected executable path, not the executable's contents. Runtime signature detection is a separate bridge step. Installer tests use placeholder executable files only to exercise filesystem behavior.

Keep game bundles, disassembly, native bytecode, saves, diagnostic logs, settings, credentials, and crash dumps out of commits and releases. Submit minimal reproducible changes; use mocked engine boundaries for offline tests and distinguish them from live playtests.
