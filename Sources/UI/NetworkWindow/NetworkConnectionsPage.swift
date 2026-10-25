//
//  NetworkConnectionsPage.swift
//  Zest
//

import SwiftUI

enum ScopeFilter: String, CaseIterable, Identifiable {
    case all, internet, lan, reserved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L10n.text("filter.all", defaultValue: "全部")
        case .internet: return L10n.text("公网")
        case .lan: return L10n.text("局域网")
        case .reserved: return L10n.text("保留")
        }
    }
}

extension FlowInfo {
    /// 连接状态短名。UDP 无远端与 TCP Listen 同一词。
    var stateLabel: String {
        if proto == .udp { return remote == nil ? L10n.text("监听") : "UDP" }
        switch state {
        case "Established": return L10n.text("已建立")
        case "Listen": return L10n.text("监听")
        case "SynSent": return L10n.text("连接中")
        case "SynReceived": return L10n.text("握手中")
        case "CloseWait": return L10n.text("等待关闭")
        case "FinWait1", "FinWait2", "Closing", "LastAck": return L10n.text("关闭中")
        case "TimeWait": return L10n.text("已关闭")
        case "Closed": return L10n.text("已关闭")
        default: return state.isEmpty ? "—" : state
        }
    }

    var sortRemote: String { remote?.address ?? "~" }
    var sortGeo: String { geo.map { "\($0.countryCode ?? "~")\($0.organization ?? "")" } ?? "~" }
    var sortTotal: UInt64 { bytesIn &+ bytesOut }
    var sortScope: Int { scope.rawValue }
    var sortProto: String { proto.rawValue }
    var sortFirstSeen: Date { firstSeen }
}

struct NetworkConnectionsPage: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var settings: AppSettings
    @State private var search = ""
    @State private var scope = ScopeFilter.all
    @State private var showListening = false
    @State private var sortOrder = [KeyPathComparator(\FlowInfo.sortTotal, order: .reverse)]

    var body: some View {
        let rows = filtered.sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: L10n.text("tab.connections", defaultValue: "连接"),
                       subtitle: String(format: L10n.text("%lld 条 · 所有进程（含系统进程）的 TCP / UDP 连接"), Int64(rows.count)))
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(ScopeFilter.allCases) { f in
                        ChipButton(title: f.title, count: nil, selected: scope == f) { scope = f }
                    }
                }
                Toggle(L10n.text("显示监听端口"), isOn: $showListening).toggleStyle(.checkbox).font(.system(size: 11.5))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField(L10n.text("搜索应用、地址、国家、服务商"), text: $search).textFieldStyle(.plain).frame(width: 180)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            }
            Table(rows, sortOrder: $sortOrder) {
                TableColumn(L10n.text("connections.column.app", defaultValue: "应用"), value: \.appName) { f in
                    Text(f.appName).lineLimit(1)
                }
                .width(min: 80, ideal: 110)
                TableColumn(L10n.text("协议"), value: \.sortProto) { f in Text(f.proto.rawValue) }
                    .width(40)
                TableColumn(L10n.text("远端"), value: \.sortRemote) { f in
                    Text(f.remoteDisplay(monitor.hostnames)).font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .width(min: 130, ideal: 170)
                TableColumn(L10n.text("归属地"), value: \.sortGeo) { f in
                    Text(f.geo?.summary ?? (f.scope == .internet ? L10n.text("未知") : "—")).lineLimit(1)
                        .foregroundStyle(f.geo == nil ? Color.secondary : Color.primary)
                        .help(f.geo?.summary ?? "")
                }
                .width(min: 110, ideal: 160)
                TableColumn(L10n.text("服务")) { f in Text(f.service ?? "—").foregroundStyle(.secondary) }
                    .width(48)
                TableColumn(L10n.text("范围"), value: \.sortScope) { f in ScopeBadge(scope: f.scope) }
                    .width(62)
                TableColumn(L10n.text("状态"), value: \.state) { f in Text(f.stateLabel).foregroundStyle(.secondary) }
                .width(64)
                TableColumn(L10n.text("traffic.download", defaultValue: "下载"), value: \.bytesIn) { f in
                    Text(Fmt.bytes(Double(f.bytesIn))).monospacedDigit()
                }
                .width(72)
                TableColumn(L10n.text("traffic.upload", defaultValue: "上传"), value: \.bytesOut) { f in
                    Text(Fmt.bytes(Double(f.bytesOut))).monospacedDigit()
                }
                .width(72)
                TableColumn(L10n.text("已持续"), value: \.sortFirstSeen) { f in
                    Text(Fmt.duration(f.duration)).foregroundStyle(.secondary)
                }
                .width(58)
            }
            .font(.system(size: 11.5))
            Text(L10n.text("“已持续”从 Zest 首次观察到该连接时开始计算；字节数为连接建立以来的累计值。"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(20)
        .id(settings.appLanguage)
    }

    private var filtered: [FlowInfo] {
        monitor.state.flows.filter { f in
            if !showListening && f.remote == nil { return false }
            switch scope {
            case .all: break
            case .internet: if f.scope != .internet { return false }
            case .lan: if f.scope != .lan { return false }
            case .reserved: if f.scope != .reserved { return false }
            }
            guard !search.isEmpty else { return true }
            let hay = "\(f.appName) \(f.remote?.display ?? "") \(f.local?.display ?? "") \(monitor.hostnames[f.remote?.address ?? ""] ?? "") \(f.service ?? "") \(f.geo?.summary ?? "") \(f.geo?.countryCode ?? "")"
            return hay.localizedCaseInsensitiveContains(search)
        }
    }
}

struct NetworkLANPage: View {
    @ObservedObject var monitor: NetworkMonitor
    @State private var sortOrder = [KeyPathComparator(\LANDevice.sortIP)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: L10n.text("局域网"), subtitle: L10n.text("读取系统 ARP 表被动发现设备，不发送扫描或探测包")) {
                Button { monitor.rescanLAN() } label: { Label(L10n.text("刷新"), systemImage: "arrow.clockwise") }
            }
            if monitor.devices.isEmpty {
                Card {
                    Label(monitor.lanAccess == .denied ? L10n.text("没有读取到局域网设备") : L10n.text("正在读取局域网设备…"),
                          systemImage: "wifi.router").font(.system(size: 13, weight: .semibold))
                    Text(L10n.text("macOS 会对未获得“本地网络”权限的应用隐藏局域网设备。请允许 Zest 访问本地网络；若之前拒绝过，可在系统设置中重新开启。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.text("请求本地网络权限")) { monitor.requestLANAccess() }
                        Button(L10n.text("打开系统设置")) { NetworkMonitor.openLocalNetworkSettings() }
                    }
                }
            } else {
                Table(monitor.devices.sorted(using: sortOrder), sortOrder: $sortOrder) {
                    TableColumn(L10n.text("IP 地址"), value: \.sortIP) { d in
                        HStack(spacing: 6) {
                            Text(d.ip).font(.system(size: 11.5, design: .monospaced))
                            if d.isGateway { Text(L10n.text("网关")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.cpu)
                                .padding(.horizontal, 4).background(Capsule().fill(Palette.cpu.opacity(0.14))) }
                        }
                    }
                    .width(min: 140, ideal: 170)
                    TableColumn(L10n.text("MAC 地址"), value: \.mac) { d in
                        Text(d.mac).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    }
                    .width(150)
                    TableColumn(L10n.text("厂商"), value: \.sortVendor) { d in
                        Text(d.vendor ?? (d.isRandomizedMAC ? L10n.text("私有地址（随机 MAC）") : L10n.text("未知")))
                            .foregroundStyle(d.vendor == nil ? Color.secondary : Color.primary).lineLimit(1)
                    }
                    .width(min: 160, ideal: 260)
                    TableColumn(L10n.text("接口"), value: \.interface) { d in Text(d.interface).foregroundStyle(.secondary) }
                        .width(60)
                    TableColumn(L10n.text("首次发现"), value: \.firstSeen) { d in
                        Text(d.firstSeen.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                    }
                    .width(80)
                }
                .font(.system(size: 11.5))
                Text(L10n.text("厂商根据 MAC 前缀查询 IEEE 公开注册表（离线）。手机等设备常使用随机 MAC，无法识别厂商。"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
    }
}

extension LANDevice {
    var sortIP: UInt32 { LANScanner.ipSortKey(ip) }
    var sortVendor: String { vendor ?? "~" }
}

struct NetworkAlertsPage: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var settings: AppSettings
    @State private var minSeverity = AlertSeverity.info

    var body: some View {
        let alerts = monitor.alerts.filter { $0.kind.severity >= minSeverity }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: L10n.text("告警"), subtitle: L10n.text("基于连接元数据的规则检测，不检查通信内容")) {
                    Button(L10n.text("清空")) { monitor.clearAlerts() }.disabled(monitor.alerts.isEmpty)
                }
                HStack(spacing: 4) {
                    ChipButton(title: L10n.text("filter.all", defaultValue: "全部"), count: monitor.alerts.count, selected: minSeverity == .info) { minSeverity = .info }
                    ChipButton(title: L10n.text("注意及以上"), count: monitor.alerts.filter { $0.kind.severity >= .notice }.count,
                               selected: minSeverity == .notice) { minSeverity = .notice }
                    ChipButton(title: L10n.text("仅警告"), count: monitor.alerts.filter { $0.kind.severity == .warning }.count,
                               selected: minSeverity == .warning) { minSeverity = .warning }
                }
                if alerts.isEmpty {
                    Card {
                        Label(L10n.text("未发现异常"), systemImage: "checkmark.shield").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.memory)
                        Text(L10n.text("启动后的第 1 分钟用于学习基线，期间不会对“新联网应用”“局域网新设备”告警。"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                ForEach(alerts) { a in
                    Card {
                        HStack(alignment: .top) {
                            AlertLine(alert: a)
                            Menu {
                                Button(a.appName.map { String(format: L10n.text("忽略“%1$@”的此类告警"), $0) } ?? L10n.text("忽略此类告警")) {
                                    monitor.suppress(SuppressionRule(kind: a.kind, appKey: a.appKey, appName: a.appName))
                                }
                                .disabled(a.appKey == nil)
                                Button(String(format: L10n.text("忽略所有“%@”"), a.kind.title)) { monitor.suppress(SuppressionRule(kind: a.kind)) }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                }
                RulesCard(monitor: monitor, settings: settings)
            }
            .padding(20)
        }
        .id(settings.appLanguage)
    }
}

private struct RulesCard: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        Card {
            CardHeader(symbol: "list.bullet.rectangle", title: L10n.text("检测规则"), tint: Palette.cpu)
            ForEach(AlertKind.allCases, id: \.self) { kind in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: kind.symbol).foregroundStyle(AlertLine.color(kind.severity)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(kind.title).font(.system(size: 11.5, weight: .semibold))
                            Text(kind.severity.label).font(.system(size: 9.5)).foregroundStyle(AlertLine.color(kind.severity))
                        }
                        Text(RulesCard.explain(kind)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !settings.suppressions.isEmpty {
                Divider()
                Text(L10n.text("已忽略")).font(.system(size: 11, weight: .semibold))
                ForEach(settings.suppressions) { r in
                    HStack {
                        Text(r.appName.map { String(format: L10n.text("%1$@ · %2$@"), r.kind.title, $0) }
                             ?? String(format: L10n.text("%@（全部）"), r.kind.title))
                            .font(.system(size: 11))
                        Spacer()
                        Button(L10n.text("恢复")) { monitor.unsuppress(r) }.controlSize(.small)
                    }
                }
            }
        }
        .id(settings.appLanguage)
    }

    static func explain(_ kind: AlertKind) -> String {
        switch kind {
        case .newInternetApp: return L10n.text("学习期结束后，某个应用第一次连接公网。")
        case .newLANDevice: return L10n.text("学习期结束后，ARP 表中出现了新的设备。")
        case .plaintext: return L10n.text("通过 HTTP、FTP、Telnet、POP3、IMAP 等未加密协议连接公网。")
        case .suspiciousPort: return L10n.text("连接到常见于远程控制、IRC 或恶意软件的公网端口（如 4444、6667、31337）。")
        case .volumeSpike: return L10n.text("某应用 30 秒平均上传 ≥ 1 MB/s，且为其 10 分钟基线的 8 倍以上。")
        case .beacon: return L10n.text("同一应用反复新建到同一公网地址的连接（≥ 6 次），间隔在 10 秒～10 分钟之间且非常规律。")
        case .inboundScan: return L10n.text("同一远端在 1 分钟内连接本机 6 个以上不同的监听端口。")
        case .exposedListener: return L10n.text("非系统应用在所有网络接口上监听 TCP 端口，局域网内的设备可以访问。")
        }
    }
}
