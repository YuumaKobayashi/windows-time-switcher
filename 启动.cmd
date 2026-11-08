@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-SystemTimezone.ps1"

if errorlevel 1 (
    echo Script failed. Press any key to close.
    pause >nul
)