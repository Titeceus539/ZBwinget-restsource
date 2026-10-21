@echo off
rem Double-click launcher for the ZB Winget control panel.
where pwsh >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh^) not found. Install it, or run: powershell -File "%~dp0ZB-Winget-UI.ps1"
  pause
  exit /b 1
)
start "" pwsh -Sta -NoProfile -File "%~dp0ZB-Winget-UI.ps1"
