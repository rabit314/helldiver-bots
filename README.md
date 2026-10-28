# HELLDIVERS Bots

AI squadmates for **HELLDIVERS 1: Dive Harder Edition**, on Windows x64. Deploy companions, give orders at your cursor, and switch control between surviving squad members through a desktop mod menu.

**Current release:** AI **0.23.1** / menu **3.6** / Lone Survivor **2.1**. This is an experimental community mod. The latest gameplay changes have offline checks; a complete live playtest of this exact combined release is still pending. See [compatibility and validation](docs/COMPATIBILITY.md).

## Download and install

1. Download **[helldiver-bots-0.23.1-menu3.6.zip](https://github.com/rabit314/helldiver-bots/releases/download/v0.23.1-menu3.6/helldiver-bots-0.23.1-menu3.6.zip)** from [Releases](https://github.com/rabit314/helldiver-bots/releases) and extract the ZIP. You can also use **Code > Download ZIP**.
2. Install **64-bit Python 3.10 or newer with Tkinter** from [python.org](https://www.python.org/downloads/windows/). The package was checked with Python 3.14. No `pip` packages, Cheat Engine, or separate injector are needed.
3. Close HELLDIVERS and any existing mod menu. Double-click **`Install.bat`**.
4. Select your **HELLDIVERS game folder**, the one containing `binaries\x64\helldivers.exe`. In Steam, open the game's **Properties > Installed Files > Browse** to find it.
5. Open **`HelldiverBots\Launch_Mod_Menu.bat`** inside your game folder. Start HELLDIVERS normally and keep the menu open while playing. The menu's Launch button opens the Steam game.
6. Wait for the menu to connect and report **`VERIFIED v2.1`**. Enter a **solo mission**, give the game focus, and **tap and release F6** to deploy your first bot.

The installer checks every payload file against `manifest.json`, copies only the mod into `<game>\HelldiverBots`, and leaves game executables, bundles, and saves in place. Existing managed mod files are backed up before an update. A Steam installation on another PC has **not** yet been confirmed compatible; the bridge rejects executable signatures it cannot identify.

**Before your first mission:** the included Lone Survivor options are enabled by default: zero stratagem cooldowns and unlimited manual uses, normal empty-magazine auto-reload, faster resting stamina recovery, 2.5x player health, four solo lives, three grenades, and 3x earned XP/research. Review the menu and turn off any options you do not want. Orbital delivery timing stays normal. Earned rewards can be saved by the game; restoring normal values does not undo them.

## Controls

Hotkeys require the game to have focus. Tap actions run when you release the key; holding does not also trigger the tap action.

| Key | Action |
| --- | --- |
| **F6 tap** | Deploy one bot. |
| **F6 hold, 0.7 seconds** | Enable or resume automatic deployment to the selected minimum. |
| **F7 tap** | Dismiss all bots and pause automatic deployment for this mission. |
| **F7 hold, 0.7 seconds** | Stop automatic deployment and keep living bots. |
| **F8 tap** | Assign or cycle an order at the cursor: ground guard post, supported terminal/device, package, or vehicle seat. |
| **F8 hold, 0.7 seconds** | Cancel tasks and recall the squad. |
| **F9 tap** | Cycle control through eligible living bots, including seated bots. |
| **F9 hold, 0.7 seconds** | Return to your living original Helldiver for free. |
| **F11** | Return to the living original, or request a replacement for one life if the original is dead. |

Automatic deployment defaults **off**, with a minimum of **three**. The menu saves that choice. Incoming deliveries count toward the minimum; a dispatched drop can still arrive after stopping. F6 can add bots above the minimum. Keep counts modest: there is no established safe maximum for live play.

## What the bots can do

- Follow and guard around the player, fight, reload, help up casualties, and collect research.
- Carry packages and operate supported objective devices through native interactions.
- Use supported equipment, pilot EXOs, and occupy vehicle gunner seats. Vehicle support and navigation have engine and terrain limits.
- Make supported autonomous stratagem calls when their needs, availability, and placement checks allow it. Each bot body has two autonomous uses per distinct stratagem; manual human calls remain unlimited when the corresponding option is enabled.
- Transfer supported explicit jobs to another available standing bot after the assigned operator dies.
- Offer free death takeover when an eligible living squad member remains. Bodies retain their equipment and condition.

Bots do **not** autonomously call Metal Detector, Hellbomb, Reinforce, or SOS. These mission slots remain available for human use. Not every objective, loadout, terrain situation, or stratagem is supported. Bot throws, landing pods, and friendly fire can still be dangerous.

## Update or remove

To update, close the game and menu, extract the new release, and run `Install.bat` again. Previous managed files go into `<game>\HelldiverBots_Backups\<timestamp>`. The installer refuses to overwrite locally edited or unmanaged payload files.

To remove, close the menu and game, run **`Uninstall.bat`** from your extracted download, and select the same game folder. It removes matching installed mod files and keeps edited files, settings, logs, and backups. Restart HELLDIVERS to clear any remaining memory hooks. You can delete leftover mod settings/logs manually after keeping anything you need.

Do not run another copy of this controller or a trainer using the same Lua bridge at the same time. An older mod menu already in the game root should remain closed.

## Help and troubleshooting

| Symptom | What to check |
| --- | --- |
| Python is not found | Install 64-bit Python with Tkinter; run `Install.bat` again. The launchers also search standard Python install folders. |
| Wrong folder selected | Choose the game root, above `binaries`, rather than `binaries\x64` itself. |
| Waiting for the game | Start the x64 game, keep the menu open, and use the installed launcher. |
| Unsupported game build | Include the exact signature error in an issue. Compatibility with every executable build is not established. |
| Access denied | Run the game and menu at the same privilege level. If the game folder is protected, the installer may need matching write permission. |
| F6/F8/F9 does nothing | Focus the game, use tap/release, and check the Activity tab. Use menu buttons to distinguish hotkey issues from game connection issues. |
| Bot waits or refuses an order | Terrain, occupied landing areas, native availability, or safety checks may reject it. Try a clear nearby point and inspect the Activity tab. |

Diagnostics are written locally to the game root: `LoneSurvivor.log`, `AI_Squadmates_*.jsonl`, and `Gameplay_Logs\`. Review logs before sharing them; they can contain local paths and session information. Report the AI/menu version, game edition, exact action, and a short relevant log excerpt in [Issues](https://github.com/rabit314/helldiver-bots/issues).

## For contributors

See [DEVELOPING.md](docs/DEVELOPING.md) for file layout, offline checks, and ZIP generation. The repository contains mod source, installation tools, and documentation. Game executables, extracted game scripts, assets, saves, private logs, and the original development workspace are excluded.

Mod code is available under the [MIT license](LICENSE). HELLDIVERS and related names belong to their respective owners. This is an unofficial project and requires your own installed copy of the game.
