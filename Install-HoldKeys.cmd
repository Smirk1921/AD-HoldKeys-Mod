@echo off
setlocal
chcp 65001 >nul
title Antimatter Dimensions HoldKeys - Install

if not exist "%~dp0Manage-HoldKeys.ps1" goto incomplete
if not exist "%~dp0mod-manifest.json" goto incomplete
if not exist "%~dp0payload\hold-keys.js" goto incomplete
if not exist "%~dp0payload\hold-keys.css" goto incomplete

echo 安装前请完全退出《反物质维度》。
echo 安装器会先备份当前 app.asar，并校验游戏版本和哈希。
echo.

if "%~1"=="" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-HoldKeys.ps1" -Action Install
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-HoldKeys.ps1" -Action Install -GameRoot "%~1"
)
set "exitCode=%errorlevel%"
echo.
if not "%exitCode%"=="0" echo 安装失败，请查看上方错误信息。若提示无写入权限，请右键以管理员身份运行。
if "%exitCode%"=="0" echo 安装成功。进入游戏后可使用 F6 / F7 / F8 / F9，F4 全部停止。
pause
exit /b %exitCode%

:incomplete
echo HoldKeys Mod 文件不完整，请保留完整文件夹结构。
pause
exit /b 2