# 反物质维度 HoldKeys Mod

这是一个适用于 Steam Windows 版《反物质维度》的内置自动长按 Mod。它会向游戏原有的快捷键系统发送合成的 `keydown / keyup`，让游戏自己的重复购买逻辑持续运行，不需要粘滞键，也不要求游戏窗口始终置顶。

## 支持版本

- Steam App ID：`1399720`
- 游戏版本：`11.5`
- Steam Build ID：`16370635`
- 简体中文补丁：`0.3.2`
- 安装前 `resources/app.asar` SHA-256：`C7380379E1D0B1FA6352BE2316BC2828EC46CCAA606C791399D0449E85C7BEEB`

游戏、Steam Build 或中文补丁不匹配时，安装器会停止，不会强行修改文件。

## 安装

1. 完全退出《反物质维度》。
2. 双击 `Install-HoldKeys.cmd`。
3. 如果游戏目录没有写入权限，请右键 `Install-HoldKeys.cmd`，选择“以管理员身份运行”。
4. 安装成功后从 Steam 正常启动游戏。

安装器会先校验当前 `app.asar`，把原文件备份到：

```text
%LOCALAPPDATA%\AntimatterDimensionsHoldKeysMod\pre-holdkeys-app.asar
```

然后才生成并替换新的 `app.asar`。

## 使用

游戏右下角会出现“自动长按”面板。点击 `D`、`M`、`C`、`G` 对应按钮即可开始，再点一次停止。

快捷键：

| 快捷键 | 功能 |
| --- | --- |
| `F6` | 开关 D：维度提升 |
| `F7` | 开关 M：全部最大 |
| `F8` | 开关 C：大坍缩 |
| `F9` | 开关 G：反物质星系 |
| `F4` | 停止全部长按 |

面板可以拖动，也可以折叠。切换游戏窗口后，已启用的长按仍会继续；不需要把游戏置顶。

## 检查与卸载

- 双击 `Check-HoldKeys.cmd`：只读检查当前状态，不修改文件。
- 双击 `Uninstall-HoldKeys.cmd`：校验当前文件确实是本 Mod 安装的版本后，恢复安装前的 `app.asar`。

卸载前同样需要完全退出游戏。不要手动删除游戏目录中的 `AD-HoldKeys-Mod` 文件夹后再尝试卸载，因为安装状态和备份位于 `%LOCALAPPDATA%`，但卸载脚本需要本文件夹中的校验清单。

## 更新游戏或中文补丁

建议顺序：

1. 先运行 `Uninstall-HoldKeys.cmd` 卸载本 Mod。
2. 再更新游戏或安装新的中文补丁。
3. 等待 HoldKeys Mod 发布对应版本后重新安装。

Steam 更新、验证文件或重新安装中文补丁后，当前 `app.asar` 可能与安装记录不匹配。此时不要强行卸载或覆盖；请先运行 `Check-HoldKeys.cmd` 查看状态。

## 说明

- Mod 不读取或修改游戏存档。
- Mod 不直接修改玩家数据，只触发游戏原有的可重复快捷键。
- 游戏内弹窗、进度条、快捷键关闭和文本输入框等限制仍由游戏原逻辑处理。
- 合成事件不会进入 Windows 全局键盘状态，因此不会影响其他程序，也不会触发粘滞键。