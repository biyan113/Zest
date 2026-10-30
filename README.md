# Zest

轻量的 macOS 菜单栏系统监控。Swift + SwiftUI。

下载：https://zest.bytenote.net/Zest-1.0.0.zip

macOS 13 及以上。

## 构建

```bash
open Zest.xcodeproj
```

也可使用命令行工具构建本地版本：

```bash
python3 Tools/check_quick_tools.py
python3 Tools/build_local.py
open build/Zest.app
```

新增工具页支持 11 项快捷操作及启用、排序、全局快捷键设置。权限、恢复机制和手动验收说明见 [快捷工具说明](docs/quick-tools.md)。

## 许可

GPL-3.0-or-later，见 [LICENSE](LICENSE)。

[@字节笔记本](https://www.bytenote.net)
