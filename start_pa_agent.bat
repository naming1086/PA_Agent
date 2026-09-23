@echo off
setlocal
REM ============================================================
REM  PA Agent Launcher
REM  Project : Price Action AI Analysis Agent
REM  Usage   : Double-click this file to start the GUI.
REM  Note    : Everything is resolved relative to this file, so
REM            the project can be moved/copied anywhere.
REM ============================================================
title PA Agent

REM --- Work in the folder that holds this script ---------------
cd /d "%~dp0"

echo ============================================================
echo  Starting PA Agent (Price Action AI Analysis)...
echo  Project dir: %CD%
echo ============================================================
echo.

REM --- Pick an interpreter: project venv first, then 3.13 / 3.12 / python
set "PY_EXE="
if exist "%~dp0.venv\Scripts\python.exe"    set "PY_EXE="%~dp0.venv\Scripts\python.exe""
if not defined PY_EXE ( py -3.13 -c "import sys" >nul 2>nul && set "PY_EXE=py -3.13" )
if not defined PY_EXE ( py -3.12 -c "import sys" >nul 2>nul && set "PY_EXE=py -3.12" )
if not defined PY_EXE ( py -3.11 -c "import sys" >nul 2>nul && set "PY_EXE=py -3.11" )
if not defined PY_EXE ( python  -c "import sys" >nul 2>nul && set "PY_EXE=python" )

REM --- Abort with instructions when no Python is available -----
if not defined PY_EXE (
  echo [ERROR] No usable Python found. PA Agent needs Python 3.11 or newer.
  echo.
  echo   Option 1 - install Python, then run this file again:
  echo       winget install -e --id Python.Python.3.12
  echo.
  echo   Option 2 - create an isolated environment inside the project:
  echo       python -m venv .venv
  echo       .venv\Scripts\python -m pip install -e .
  echo.
  pause
  exit /b 1
)

echo Interpreter: %PY_EXE%
echo.

%PY_EXE% run.py

echo.
echo ============================================================
echo  PA Agent has exited.
echo  If the window closed unexpectedly, check:
echo    %CD%\logs\pa_agent.log
echo    %CD%\logs\crash.log
echo ============================================================
pause
