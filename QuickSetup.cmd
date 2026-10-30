@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SETUP_EXIT=1"
if not exist "%~dp0Install-CampusNet.ps1" goto missing_files
if not exist "%~dp0CampusNet-AutoConnect.ps1" goto missing_files
if not exist "%~dp0config.example.json" goto missing_files
if not exist "%~dp0src\SrunCrypto.cs" goto missing_files
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL_EXE%" goto missing_powershell
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-CampusNet.ps1"
set "SETUP_EXIT=%ERRORLEVEL%"
if not "%SETUP_EXIT%"=="0" (
    echo.
    echo Setup stopped with exit code %SETUP_EXIT%.
)
goto finish

:missing_files
echo Setup files are missing.
echo Extract the entire ZIP first, then open QuickSetup.cmd in the extracted folder.
goto finish

:missing_powershell
echo Windows PowerShell could not be found.

:finish
echo.
echo Press any key to close this window.
pause >nul
exit /b %SETUP_EXIT%
