@echo off
setlocal
chcp 65001 >nul
title Antimatter Dimensions HoldKeys - Check

if not exist "%~dp0Manage-HoldKeys.ps1" goto incomplete
if not exist "%~dp0mod-manifest.json" goto incomplete

if "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-HoldKeys.ps1" -Action Check
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-HoldKeys.ps1" -Action Check -GameRoot "%~1"
)
set "exitCode=%errorlevel%"
echo.
pause
exit /b %exitCode%

:incomplete
echo HoldKeys Mod 文件不完整，请保留完整文件夹结构。
pause
exit /b 2