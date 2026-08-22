@echo off
setlocal
cd /d "%~dp0"
echo ATTENZIONE: questa richiesta avvia un pagamento reale da 0,01 EUR.
echo Usa il POS a portata di mano per completare o annullare.
echo.
choice /C SN /M "Vuoi continuare"
if errorlevel 2 exit /b 1
node .\bin\nexi-ecr-lan.js pay
echo.
pause
