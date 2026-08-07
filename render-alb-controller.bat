@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0render-alb-controller.ps1" > "%~dp0render-alb-controller.log" 2>&1
echo.
echo Script finished. Press any key to close this window.
pause >nul
