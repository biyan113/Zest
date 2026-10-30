# Zest 快捷工具

新增的“工具”页包含 11 项操作。设置中的“快捷工具”可启用、排序和录制全局快捷键，工具页右上角的管理按钮会直接打开该设置页。

## 启动

先从旧版 Zest 面板退出应用，再执行：

```sh
open build/Zest.app
```

点击菜单栏 Zest → **工具**。这仍是菜单栏应用，没有常驻主窗口。验收时建议暂停其他管理相同系统开关或快捷键的工具。

## 功能和权限

| 工具 | 行为 | 权限与恢复 |
| --- | --- | --- |
| 深色模式 | 切换系统外观 | 首次允许自动化控制 System Events；系统设置保留 |
| 锁屏 | 发送系统锁屏组合键 Control–Command–Q | 辅助功能；执行后需要自行解锁 |
| 保持亮屏 | 建立 IOKit 显示保持唤醒会话 | 无管理员权限；默认 30 分钟，可选持续；关闭、到期或退出即释放 |
| 进入屏保 | 打开系统 ScreenSaverEngine | 使用已有屏保配置 |
| 清洁屏幕 | 所有显示器覆盖黑色清洁窗口 | 点击退出或 Esc；默认 60 秒自动退出 |
| 清洁键盘 | 全屏提示，并暂时拦截普通键盘事件 | 辅助功能；鼠标退出、倒计时或 Control–Option–Command–Esc 退出；不能屏蔽电源键、Touch ID 或系统安全输入路径 |
| 自动隐藏菜单栏 | 切换 System Events 的菜单栏自动隐藏设置 | 自动化；系统设置保留 |
| 清倒废纸篓 | 经确认后由 Finder 清空废纸篓 | Finder 自动化；永久删除，不能撤销 |
| 合盖不休眠 | 临时启用 `pmset disablesleep`，会阻止系统睡眠 | 仅有合盖功能的 Mac；管理员授权；关闭、到期或宿主退出，由独立 watcher 恢复原设置，通常约 1 秒 |
| 锁定 Dock | 阻止非目标显示器外边缘触发 Dock | 辅助功能；其他屏幕对应外边缘预留 4 点，正常跨屏不受影响；建议开启后将 Dock 移回所选屏幕；显示器配置变化自动关闭 |
| 省电模式 | 同时设置电池及接通电源的低电量模式 | 管理员授权；退出后保留；系统或机型不支持时显示错误 |

权限请按使用时的系统提示授予。也可从快捷工具设置进入“辅助功能权限”和“自动化权限”。拒绝授权时工具会显示错误；授权后重新点击即可。

“启用”仅控制工具是否显示和快捷键是否生效。关闭临时工具的启用选项，也会结束该工具的当前临时会话。更改时长影响下次启动的会话。

## 快捷键

点“设置快捷键”后按下组合键，至少包含 Command、Option 或 Control。Esc 取消，Delete 清除。录制期间暂停 Zest 的全局快捷键，离开设置后恢复；重复或被其他应用占用的组合键会提示。

清倒废纸篓即使由快捷键触发，也需要确认。

## 合盖模式的恢复机制

该功能使用管理员授权启动临时 `/bin/sh` watcher，不安装 LaunchDaemon，不储存管理员密码。原始电源设置保存在 root 所有的 `/var/run/app.zest.monitor.awake/previous`，退出、计时结束或主进程退出后恢复。重叠会话会拒绝；上次 watcher 被意外终止后，下次启用会尝试先恢复旧设置。

如果整个 watcher 也被强行终止，可先查看原设置，再手动恢复（执行时需要管理员密码）：

```sh
zest_previous=$(sudo cat /var/run/app.zest.monitor.awake/previous)
case "$zest_previous" in
  0|1) sudo pmset -a disablesleep "$zest_previous" ;;
  *) echo "未读到有效的原设置，请勿猜测" ;;
esac
```

首次使用合盖模式，请在桌面上验证合盖后运行和重新打开后的恢复行为。

## 构建与检查

仅依赖 macOS Command Line Tools 和 Python 3。脚本复用并校验项目锁定的 Sparkle 2.10.0；本机默认用 macOS 26.5 SDK，避开 27.2 命令行工具缺少 SwiftUI 宏插件的问题。

```sh
python3 Tools/check_quick_tools.py
python3 Tools/build_local.py
```

可通过 `ZEST_MACOS_SDK` 指定另一个兼容 SDK。构建完成后生成 `build/Zest.app`，前一份应用保存在 `build/Zest-previous-*.app`。构建不自动退出正在使用的应用，也不自动启动新版本。

正常 Xcode 构建保留原有 Sparkle 更新行为和项目版本号。命令行本地构建会写入 `ZestCustomBuild` 标志并停用官方更新，避免官方安装包覆盖本地改动；版本号读取项目设置。
