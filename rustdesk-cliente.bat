@echo off
title RustDesk cliente - Gas+ Soporte
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
echo Instalando RustDesk (cliente) apuntando a soporte.gas.hn ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://gas.hn/rustdesk-cliente.ps1 | iex"
echo.
pause
