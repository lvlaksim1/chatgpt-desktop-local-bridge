@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-Update.ps1"
if errorlevel 1 (
  echo.
  echo Update failed. The installed version was left unchanged or rolled back.
  pause
  exit /b 1
)
exit /b 0
