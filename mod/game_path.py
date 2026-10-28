"""Portable paths for the standalone HELLDIVERS Bots install directory."""
import os
from pathlib import Path


def game_directory(script_directory):
    here = Path(script_directory).resolve()
    for candidate in (here, here.parent):
        if (candidate / 'binaries/x64/helldivers.exe').is_file():
            return candidate
    raise RuntimeError(
        'HELLDIVERS x64 was not found. Run Install.bat and select the game folder '
        'that contains binaries/x64/helldivers.exe.'
    )


def launch_game():
    """Ask the user's installed Steam client to start their own copy."""
    os.startfile('steam://rungameid/394510')
