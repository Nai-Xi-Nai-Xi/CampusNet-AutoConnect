@echo off
setlocal
set "CAMPUSNET_ROOT=%LOCALAPPDATA%\CampusNet-AutoConnect"
if exist "%~dp0config.json" set "CAMPUSNET_ROOT=%~dp0"
if not exist "%CAMPUSNET_ROOT%\config.json" (
    echo Run QuickSetup.cmd first.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CAMPUSNET_ROOT%\CampusNet-AutoConnect.ps1" -Once -PauseAtEnd
