@echo off
setlocal
cd /d "%~dp0"
echo ATTENZIONE: questa richiesta invia la chiusura sessione al POS.
echo.
choice /C SN /M "Vuoi continuare"
if errorlevel 2 exit /b 1
node .\bin\nexi-ecr-lan.js close
echo.
pause
