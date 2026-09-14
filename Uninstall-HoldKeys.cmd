@echo off
setlocal
chcp 65001 >nul
title Antimatter Dimensions HoldKeys - Uninstall

if not exist "%~dp0Manage-HoldKeys.ps1" goto incomplete
if not exist "%~dp0mod-manifest.json" goto incomplete

echo 卸载前请完全退出《反物质维度》。
echo 卸载器只会恢复它亲自备份的 app.asar。
echo.

if "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-HoldKeys.ps1" -Action Uninstall
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-HoldKeys.ps1" -Action Uninstall -GameRoot "%~1"
)
set "exitCode=%errorlevel%"
echo.
if not "%exitCode%"=="0" echo 卸载失败，请查看上方错误信息。
if "%exitCode%"=="0" echo 卸载完成，已恢复安装前的 app.asar。
pause
exit /b %exitCode%

:incomplete
echo HoldKeys Mod 文件不完整，请保留完整文件夹结构。
pause
exit /b 2