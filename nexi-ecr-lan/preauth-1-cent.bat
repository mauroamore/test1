@echo off
setlocal
cd /d "%~dp0"
echo ATTENZIONE: questa richiesta avvia una preautorizzazione reale da 0,01 EUR.
echo.
choice /C SN /M "Vuoi continuare"
if errorlevel 2 exit /b 1
node .\bin\nexi-ecr-lan.js preauth - - - - 1
echo.
pause
