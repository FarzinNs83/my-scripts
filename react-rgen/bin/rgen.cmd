@echo off
REM Run rgen from a clone without installing it: put this bin folder on PATH.
setlocal
set "PYTHONPATH=%~dp0..;%PYTHONPATH%"
python -m rgen %*
exit /b %errorlevel%
