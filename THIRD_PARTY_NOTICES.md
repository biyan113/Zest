# 第三方声明 / Third-Party Notices

Zest 以 **GNU General Public License v3.0 或更高版本** 发布（见 `LICENSE`）。

## Tencent Lemon Cleaner

- 项目：https://github.com/Tencent/lemon-cleaner
- 版权：Copyright (C) 2022 Tencent. All rights reserved.
- 许可：Lemon Monitor / Lemon Cleaner 模块为 GPL-3.0；`localPod/LemonStat`、`LemonHardware`、`LemonNetSpeed` 各自附带 MIT 许可（Copyright (c) 2021–2022 lemon <lemon@tencent.com>）；`LemonDaemon` 为 GPL-2.0。

Zest 中移植（以 Swift 重写）的逻辑及其来源：

| Zest 文件 | 来源 | 内容 |
|---|---|---|
| `Sources/Core/CPUSampler.swift` | LemonStat `CmcProcessor.m` | `host_processor_info` 逐核 tick 差值 |
| `Sources/Core/MemorySampler.swift` | LemonStat `CmcMemory.m` | `host_statistics64` 内存分类 |
| `Sources/Core/NetworkSampler.swift` | LemonStat `CmcNetSysctl.m` | `NET_RT_IFLIST2` 计数器、物理网卡白名单与兜底统计 |
| `Sources/Core/DiskSampler.swift` | LemonStat `CmcDisk.m` | 缓存 `IOBlockStorageDriver` 并汇总读写字节 |
| `Sources/UI/MenuBarRenderer.swift` | LemonMonitor `QMStatusMonitorView.m` | 菜单栏“数值/标签”双行布局、竖线分隔、网速格式 |

**未使用** LemonDaemon（GPL-2.0-only，与 GPL-3.0 不兼容）中的任何代码。温度与风扇读取
（`Sources/SMC/SMCBridge.c`、`Sources/Core/SMCSensors.swift`）为独立实现，仅依据 AppleSMC 用户客户端的公开结构布局。

Zest 不包含 Lemon Cleaner 的清理、卸载、重复文件、隐私清理等功能，不依赖其主程序、守护进程或任何 Pod，
也不使用其商标与图标。Zest 与腾讯公司无关。

## Snitch

- 项目：https://github.com/aixisstudio/snitch （AGPL-3.0）
- Zest 的“网络监控”功能（按应用的流量与目的地、连接表、局域网设备、拓扑图、隐私评分、异常告警及忽略规则）
  在功能设计与告警分类（NEW_HOST、SUSPICIOUS_PORT、PORT_SCAN、BEACON、VOLUME_SPIKE 等）上参考了 Snitch。
- 实现完全独立（`Sources/Network/`、`Sources/UI/NetworkWindow/` 等），**未复制 Snitch 的任何代码、数据文件或资源**。
  Snitch 使用 libpcap 抓包 + Python 后端 + Electron 界面；Zest 改用系统自带的 `/usr/bin/nettop`（NetworkStatistics）
  与 `/usr/sbin/arp` 读取连接元数据，不抓包、不需要 root、不运行服务器，也不包含其地理定位、TLS SNI / DNS 解析等组件。

## IEEE OUI 注册表

- `Resources/Data/oui.deflate` 由 IEEE 公开发布的 MA-L 注册表（https://standards-oui.ieee.org/oui/oui.csv）转换而来，
  仅保留“MAC 前缀 → 组织名称”两列，用于离线显示局域网设备厂商。

## DB-IP Lite（IP 归属地）

- `Resources/Data/geoip.deflate` 由 DB-IP 的 “IP to Country Lite” 与 “IP to ASN Lite” 数据库转换而来。
- 许可：Creative Commons Attribution 4.0 International（CC BY 4.0），https://db-ip.com/db/lite.php
- 署名：**IP Geolocation by DB-IP**（https://db-ip.com）。应用内网络监控总览页显示此署名。
- 转换脚本：`Tools/build_geoip.py`（仅做格式转换：合并相邻同值区间、IPv6 取前 64 位，不改变归属信息）。
