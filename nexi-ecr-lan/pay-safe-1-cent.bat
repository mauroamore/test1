@echo off
setlocal
cd /d "%~dp0"
set ORDER_ID=TEST-%RANDOM%-%RANDOM%
echo ATTENZIONE: questa richiesta avvia un pagamento reale da 0,01 EUR con recovery log.
echo Order ID: %ORDER_ID%
echo.
choice /C SN /M "Vuoi continuare"
if errorlevel 2 exit /b 1
node .\bin\nexi-ecr-lan.js pay-safe %ORDER_ID% 1
echo.
pause
