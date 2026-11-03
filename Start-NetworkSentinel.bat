@echo off
title Launching Network Sentinel...
cd /d "%~dp0"
start "" powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0NetworkSentinel.ps1"
exit
