@echo off
rem Double-click to start the NVR server in this window (Ctrl+C or closing the window stops it).
rem Runs start-server.ps1 even when PowerShell scripts are disabled on this PC (this run only).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-server.ps1"
pause
