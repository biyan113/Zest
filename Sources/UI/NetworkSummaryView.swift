//
//  NetworkSummaryView.swift
//  Zest
//
//  弹出面板中的“网络”页：谁在占带宽、用了多少。完整功能在“网络监控”窗口。
//  入口收在“应用流量”卡片末尾的“详细连接”链接，不再单独占用一整行按钮。
//

import SwiftUI

struct NetworkSummaryView: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var settings: AppSettings
    var openWindow: () -> Void
    var openSettings: () -> Void

    /// 面板内的排行范围：本次启动 / 最近 24 小时（来自持久化历史，含已退出的应用）。
    private enum Range: String { case session, day }

    @AppStorage("panelNetworkRange") private var range = Range.session

    private static let rows = 5

    var body: some View {
        let s = monitor.state
        VStack(spacing: 12) {
            if case .failed(let message) = monitor.status {
                Card { Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange) }
            }
            if !monitorRunning {
                stoppedCard
            } else {
                rateCard(s)
                appCard(s)
                statsCard(s)
            }
        }
        .onAppear { monitor.setVisible(true) }
        .onDisappear { monitor.setVisible(false) }
        .id(settings.appLanguage)
    }

    private var monitorRunning: Bool {
        if case .running = monitor.status { return true }
        if case .starting = monitor.status { return true }
        return false
    }

    /// 监控关闭时的空状态：说明原因并直接给出开启入口，而不是显示一排 0。
    @ViewBuilder private var stoppedCard: some View {
        Card {
            CardHeader(symbol: "pause.circle", title: L10n.text("网络监控未开启"), tint: Palette.wired)
            Text(L10n.text("Zest 不会在后台读取任何网络数据。开启后可看到各应用占用的带宽、本次与 24 小时的流量。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.networkMonitoring {
                Unavailable(text: L10n.text("正在启动网络监控…"))
            } else {
                HStack(spacing: 10) {
                    Toggle(L10n.text("开启后台网络监控"), isOn: $settings.networkMonitoring)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                    Spacer(minLength: 4)
                    LinkButton(title: L10n.text("设置"), symbol: "gearshape", action: openSettings)
                }
            }
        }
    }

    private func rateCard(_ s: NetworkState) -> some View {
        Card {
            CardHeader(symbol: "arrow.up.arrow.down", title: L10n.text("实时流量"), tint: Palette.download,
                       trailing: String(format: L10n.text("本次 ↓%@  ↑%@"),
                                        Fmt.bytes(Double(s.sessionIn)), Fmt.bytes(Double(s.sessionOut))))
            HStack(spacing: 14) {
                rate("arrow.down", Palette.download, s.rateIn)
                rate("arrow.up", Palette.upload, s.rateOut)
                Spacer()
            }
            DualSparkline(primary: s.live.map(\.bytesIn), secondary: s.live.map(\.bytesOut),
                          primaryColor: Palette.download, secondaryColor: Palette.upload, capacity: NetworkTracker.liveCapacity)
                .frame(height: 40)
        }
    }

    private func appCard(_ s: NetworkState) -> some View {
        Card {
            CardHeader(symbol: "app.connected.to.app.below.fill", title: L10n.text("应用流量"), tint: Palette.cpu)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 6) {
                        rangeChip(L10n.text("range.session", defaultValue: "本次"), .session)
                        rangeChip(L10n.text("24 小时"), .day)
                    }
                }
            let rows = ranking(s)
            if rows.isEmpty {
                Unavailable(text: monitor.status == .running ? L10n.text("暂无流量") : L10n.text("正在启动网络监控…"))
            }
            ForEach(rows) { row in
                appRow(row)
            }
            if !rows.isEmpty {
                footLink
            }
        }
    }

    private var footLink: some View {
        HStack {
            Spacer()
            Button(action: openWindow) {
                HStack(spacing: 2) {
                    Text(L10n.text("详细连接"))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.cpu)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
    }

    private func rangeChip(_ title: String, _ value: Range) -> some View {
        Button { range = value } label: {
            Text(title)
                .font(.system(size: 10, weight: range == value ? .semibold : .regular))
                .foregroundStyle(range == value ? Palette.cpu : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(range == value ? Palette.cpu.opacity(0.14) : Color.primary.opacity(0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func appRow(_ row: TrafficRow) -> some View {
        HStack(spacing: 6) {
            AppIcon(bundlePath: row.bundlePath, size: 16)
            Text(row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text("↓\(Fmt.compactBytes(Double(row.bytesIn)))").foregroundStyle(Palette.download)
                .frame(width: 58, alignment: .trailing)
            Text("↑\(Fmt.compactBytes(Double(row.bytesOut)))").foregroundStyle(Palette.upload)
                .frame(width: 58, alignment: .trailing)
            Text(Fmt.compactBytes(Double(row.total)))
                .foregroundStyle(.primary)
                .frame(width: 52, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .frame(height: 18)
    }

    /// 本次：实时速率排序；24 小时：持久化历史排序（含已退出的应用）。
    private func ranking(_ s: NetworkState) -> [TrafficRow] {
        switch range {
        case .session:
            let active = s.apps.filter { $0.sessionTotal > 0 }
            return active.prefix(Self.rows).map {
                TrafficRow(key: $0.key, name: $0.name, bundlePath: $0.bundlePath,
                           bytesIn: $0.sessionIn, bytesOut: $0.sessionOut)
            }
        case .day:
            return monitor.history.apps.prefix(Self.rows).map {
                TrafficRow(key: $0.key, name: $0.name, bundlePath: $0.bundlePath,
                           bytesIn: $0.bytesIn, bytesOut: $0.bytesOut)
            }
        }
    }

    private func statsCard(_ s: NetworkState) -> some View {
        Card {
            CardHeader(symbol: "chart.bar.doc.horizontal", title: L10n.text("统计"), tint: Palette.wired)
            let day = monitor.history
            StatRow(label: range == .session ? L10n.text("本次合计") : L10n.text("24 小时合计"),
                    value: range == .session
                        ? Fmt.bytes(Double(s.sessionIn + s.sessionOut))
                        : Fmt.bytes(Double(day.bytesIn + day.bytesOut)))
            StatRow(label: L10n.text("network.download", defaultValue: "下载"), value: Fmt.bytes(Double(range == .session ? s.sessionIn : day.bytesIn)), dot: Palette.download)
            StatRow(label: L10n.text("network.upload", defaultValue: "上传"), value: Fmt.bytes(Double(range == .session ? s.sessionOut : day.bytesOut)), dot: Palette.upload)
            Divider().opacity(0.5)
            StatRow(label: L10n.text("联网应用"), value: "\(s.onlineApps.count)")
            StatRow(label: L10n.text("活跃连接"), value: "\(s.activeFlows.filter { $0.scope != .loopback }.count)")
            StatRow(label: L10n.text("监听端口"), value: "\(s.flows.filter(\.isListening).count)")
            StatRow(label: L10n.text("局域网设备"), value: monitor.lanAccess == .denied ? L10n.text("需授权") : "\(monitor.devices.count)")
        }
    }

    private func rate(_ symbol: String, _ color: Color, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            Text(Fmt.rate(value)).font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

/// 卡片内的轻量链接按钮，比整行实心按钮更克制。
struct LinkButton: View {
    var title: String
    var symbol: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.cpu)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct ScoreRing: View {
    var score: Int
    var color: Color
    var lineWidth: CGFloat = 5

    static func color(_ s: Int) -> Color { s >= 85 ? Palette.memory : (s >= 60 ? Palette.wired : Palette.heat) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)").font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
        }
    }
}

struct AlertLine: View {
    var alert: NetworkAlert
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: alert.kind.symbol)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .foregroundStyle(AlertLine.color(alert.kind.severity))
                .frame(width: compact ? 14 : 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(alert.kind.title).font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                    if let name = alert.appName { Text(name).font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    Text(alert.date, style: .time).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(alert.detail)
                    .font(.system(size: compact ? 9.5 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 3)
                    .fixedSize(horizontal: false, vertical: !compact)
            }
        }
    }

    static func color(_ s: AlertSeverity) -> Color {
        switch s {
        case .info: return Palette.cpu
        case .notice: return Palette.wired
        case .warning: return Palette.heat
        }
    }
}
