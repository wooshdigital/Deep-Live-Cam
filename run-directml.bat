@echo off
rem Always the install's own venv - a bare "python" would be whatever is on PATH.
cd /d "%~dp0"
"%~dp0venv\Scripts\python.exe" sync_working_models.py
"%~dp0venv\Scripts\python.exe" run.py --execution-provider dml
