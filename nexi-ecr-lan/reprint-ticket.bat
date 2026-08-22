@echo off
setlocal
cd /d "%~dp0"
echo Questa richiesta chiede al POS la ristampa dell'ultima ricevuta finanziaria.
echo.
choice /C SN /M "Vuoi continuare"
if errorlevel 2 exit /b 1
node .\bin\nexi-ecr-lan.js reprint
echo.
pause
