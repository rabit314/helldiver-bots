@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0python_runner.ps1" -Script "%~dp0HelldiversModMenu.pyw" -Windowless
if errorlevel 1 pause
