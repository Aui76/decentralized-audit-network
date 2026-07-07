@echo off
REM One-click start for the Audit Cell membrane site.
REM 1) npm install (first run)  2) index chain data  3) serve + open browser
REM Set SKIP_INDEX=1 to skip the slow RPC refresh (uses existing view-model.*)
cd /d "%~dp0"

if not exist node_modules (
  echo Installing dependencies ^(first run only^)...
  call npm install
  if errorlevel 1 (
    echo npm install failed.
    pause
    exit /b 1
  )
)

REM Free port 5173 if a previous membrane serve is still running
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":5173" ^| findstr "LISTENING"') do (
  echo Stopping previous server on port 5173 ^(PID %%a^)...
  taskkill /PID %%a /F >nul 2>&1
)
ping 127.0.0.1 -n 2 >nul 2>&1

if /i "%SKIP_INDEX%"=="1" (
  echo.
  echo SKIP_INDEX=1 — using existing view-model.json / view-model.js
) else (
  echo.
  echo Refreshing chain data from Base Sepolia ^(often 2-3 minutes; no output until done^)...
  call npm run index
  if errorlevel 1 (
    echo.
    echo WARNING: indexer failed — pages may show stale or missing audits.
    echo Check internet / RPC, then run: npm run index
    echo Or retry with stale data: set SKIP_INDEX=1 ^& start.bat
    echo.
  )
)

echo.
echo ============================================================
echo  Starting server. Leave this window OPEN.
echo  Browser will open:
echo    http://127.0.0.1:5173/index.html
echo    http://127.0.0.1:5173/concern.html
echo  Press Ctrl+C here to stop.
echo ============================================================
echo.

REM open browser after server has time to bind
start "" /b cmd /c "timeout /t 3 >nul & start "" http://127.0.0.1:5173/index.html"

REM -l 5173 alone picks a RANDOM port in newer serve; must use tcp://host:port
call npx --yes serve -l tcp://127.0.0.1:5173 -c serve.json .
if errorlevel 1 (
  echo.
  echo ERROR: server failed to start. Try: npm run serve
  pause
  exit /b 1
)
