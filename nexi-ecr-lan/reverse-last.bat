@echo off
setlocal
cd /d "%~dp0"
echo ATTENZIONE: questa richiesta invia uno storno/reversal.
echo Di default usa STAN 000000, cioe' storno ultima operazione se supportato dal POS.
echo.
choice /C SN /M "Vuoi continuare"
if errorlevel 2 exit /b 1
node .\bin\nexi-ecr-lan.js reverse-last
echo.
pause
