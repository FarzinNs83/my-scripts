@echo off
REM Run fgen from a clone without installing it: put this bin folder on PATH.
setlocal
set "PYTHONPATH=%~dp0..;%PYTHONPATH%"
python -m fgen %*
exit /b %errorlevel%
