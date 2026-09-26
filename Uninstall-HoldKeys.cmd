@echo off
setlocal
chcp 65001 >nul
title Antimatter Dimensions HoldKeys - Uninstall

if not exist "%~dp0Manage-HoldKeys.ps1" goto incomplete
if not exist "%~dp0mod-manifest.json" goto incomplete

echo 卸载前请完全退出《反物质维度》。
echo 卸载器按 mod 注入痕迹做外科式清理，不依赖整包备份。
echo.

if "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-HoldKeys.ps1" -Action Uninstall
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-HoldKeys.ps1" -Action Uninstall -GameRoot "%~1"
)
set "exitCode=%errorlevel%"
echo.
if not "%exitCode%"=="0" echo 卸载失败，请查看上方错误信息。
if "%exitCode%"=="0" echo 卸载完成，已移除本 Mod 注入的全部内容。
pause
exit /b %exitCode%

:incomplete
echo HoldKeys Mod 文件不完整，请保留完整文件夹结构。
pause
exit /b 2
