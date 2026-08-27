@echo off
rem One-shot setup on a fresh PC. Needs kinetix_key.txt (optional) next to this file
rem (the standalone installer writes it). See setup.ps1 for the real work.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
pause
