@echo off
setlocal
cd /d "%~dp0"
node .\bin\nexi-ecr-lan.js last-result
echo.
pause
