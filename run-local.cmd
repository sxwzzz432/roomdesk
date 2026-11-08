@echo off
rem ===========================================================
rem  RoomDesk local mode launcher (no Docker)
rem  All logic lives in run-local.ps1 - this file only kicks it off.
rem
rem  Usage:
rem    run-local.cmd                     start API (+ worker window)
rem    run-local.cmd -NoWorker           API only
rem    run-local.cmd -Port 8001          change API port
rem    run-local.cmd -PreflightOnly      check/repair environment, do not start
rem    run-local.cmd -Migrate            force re-run migrations (idempotent)
rem ===========================================================
chcp 65001 >nul
setlocal
set "SCRIPT=%~dp0run-local.ps1"

if not exist "%SCRIPT%" (
  echo [FAIL] run-local.ps1 not found next to this file.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

if errorlevel 1 (
  echo.
  echo [FAIL] startup failed, see messages above.
  pause
  exit /b 1
)
exit /b 0
