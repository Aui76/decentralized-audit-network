@echo off
REM Snapshot the membrane site to a timestamped zip (excludes node_modules, backups, .git).
REM Runs on your machine (no sandbox mount lag), so the zip is always the real files.
setlocal
cd /d "%~dp0"

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set TS=%%i
if not exist backups mkdir backups
set STAGE=%TEMP%\membrane-%TS%

robocopy "." "%STAGE%" /E /XD node_modules backups .git >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path '%STAGE%\*' -DestinationPath 'backups\membrane-%TS%.zip' -Force"
rmdir /s /q "%STAGE%"

echo.
echo Backup written: %~dp0backups\membrane-%TS%.zip
echo.
pause
