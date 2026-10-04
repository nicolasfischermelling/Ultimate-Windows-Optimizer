@echo off
rem Double-click launcher: elevates and runs Optimize.ps1 in Windows PowerShell 5.1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"%~dp0Optimize.ps1\"'"
