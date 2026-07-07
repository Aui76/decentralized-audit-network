@echo off
REM Fast start — skip Base Sepolia indexer (uses existing view-model.*)
set SKIP_INDEX=1
call "%~dp0start.bat"
