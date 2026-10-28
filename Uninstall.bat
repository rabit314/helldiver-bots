@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0mod\python_runner.ps1" -Script "%~dp0install.py" -Uninstall
if errorlevel 1 pause
