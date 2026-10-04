@echo off
setlocal
title WinOptSuite
cd /d "%~dp0"

rem --- Administrator check: re-launch elevated (UAC prompt) if needed ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Asking Windows for administrator rights...
    set "WINOPT_BAT=%~f0"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:WINOPT_BAT -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo Administrator rights were not granted. Nothing was changed.
        pause
    )
    exit /b
)

rem --- Windows PowerShell 5.1 is required (several tools do not work in PowerShell 7) ---
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    echo Windows PowerShell 5.1 was not found. WinOptSuite cannot run.
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinOptSuite.ps1"
set "rc=%errorlevel%"
if not "%rc%"=="0" (
    echo.
    echo WinOptSuite stopped with exit code %rc%. Logs: %ProgramData%\WinOptSuite\logs
    pause
)
exit /b %rc%
