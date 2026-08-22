@echo off
setlocal
cd /d "%~dp0"
node .\bin\nexi-ecr-lan.js pending
echo.
pause
