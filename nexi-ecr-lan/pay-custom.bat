@echo off
setlocal
cd /d "%~dp0"
set /p AMOUNT_CENTS=Importo in centesimi, es. 1 per 0,01 EUR: 
if "%AMOUNT_CENTS%"=="" exit /b 1
echo.
echo ATTENZIONE: questa richiesta avvia un pagamento reale da %AMOUNT_CENTS% centesimi.
choice /C SN /M "Vuoi continuare"
if errorlevel 2 exit /b 1
node .\bin\nexi-ecr-lan.js pay - - - - %AMOUNT_CENTS%
echo.
pause
