@echo off
rem Runs vless-proxy.ps1 without changing PowerShell's script policy (no admin needed).
rem   vless-proxy.cmd up "vless://..."   |   down   |   status   (see vless-proxy.ps1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vless-proxy.ps1" %*
