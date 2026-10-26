@echo off
setlocal
set "SCRIPT=%~dp0opencode-unlimited.ps1"

where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
