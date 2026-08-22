@echo off
setlocal
cd /d "%~dp0"
echo Questa procedura chiama last-result sul POS e aggiorna il log locale se ci sono pending/uncertain.
echo.
choice /C SN /M "Vuoi continuare"
if errorlevel 2 exit /b 1
node .\bin\nexi-ecr-lan.js reconcile
echo.
pause
