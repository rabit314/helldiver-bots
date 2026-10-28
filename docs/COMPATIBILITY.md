# Compatibility and validation

## Scope

- Target: HELLDIVERS 1: Dive Harder Edition, Windows x64.
- The bridge identifies functions in the user's executable using unique signatures before installing its memory hook. A different build may be refused. Matching signatures alone cannot prove every engine contract is compatible.
- Python: 64-bit Python 3.10+ and Tkinter; this package is checked with Python 3.14. Other supported Python versions have not all been exercised.
- Solo play is the intended starting point. Public matchmaking, remote players, split-screen, Linux/Proton, consoles, and other executable revisions have not been validated for this package.
- Offline Esc pause only activates when the mod can establish its local solo/offline conditions. It is not a promise that every session pauses.
- There is no verified stable maximum bot count. Start with one, then increase gradually.

## Existing evidence

These results come from the development project, before public packaging:

- Lone Survivor 2.1 is an accepted working baseline confirmed by its user.
- AI 0.23.1 passed 528 affected offline checks, including 21 new checks. Five matched regression scenarios failed on archived 0.23.0 and passed on 0.23.1.
- Menu 3.6 passed 58 focused offline checks, 36 layout cases across 100/125/150% scaling, and all nine Lua loader stages.
- Latest source was installed and hash-verified in the original environment on 2026-10-23. The latest combined build's physical playtest remains pending.

These are historical validation results, not a claim that this repository reruns the full development test suite or that another PC's installation works. Private engine fixtures, extracted bytecode, logs, and crash dumps are deliberately excluded.

## Public-package checks

The public tools check payload hashes, Python syntax, nine staged loader sizes, installer behavior, and archive contents without attaching to or starting HELLDIVERS. Local release preparation also compiles the Lua sources and staged commands using the existing private LuaJIT tooling. These checks do not establish real terrain behavior, engine collision, animation/vehicle parenting, multiplayer compatibility, or freedom from future native crashes.

The packaging changes replace machine-specific paths, use Steam for the Launch button, and add isolated install/remove tools. Gameplay Lua is byte-for-byte unchanged from the current development source. No live test was performed as part of public packaging.
