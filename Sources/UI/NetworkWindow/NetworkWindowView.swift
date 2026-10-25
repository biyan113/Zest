//
//  NetworkWindowView.swift
//  Zest
//

import SwiftUI

enum NetworkPage: String, CaseIterable, Identifiable {
    case overview, apps, connections, lan, topology, alerts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L10n.text("总览")
        case .apps: return L10n.text("tab.apps", defaultValue: "应用")
        case .connections: return L10n.text("tab.connections", defaultValue: "连接")
        case .lan: return L10n.text("局域网")
        case .topology: return L10n.text("拓扑")
        case .alerts: return L10n.text("告警")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .apps: return "square.grid.2x2"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .lan: return "wifi.router"
        case .topology: return "circle.hexagongrid"
        case .alerts: return "bell.badge"
        }
    }
}

struct NetworkWindowView: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var settings: AppSettings
    @AppStorage("networkPage") private var page = NetworkPage.overview
    @State private var selectedApp: String?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page, monitor: monitor)
                .frame(width: 196)
            Divider()
            Group {
                switch page {
                case .overview: NetworkOverviewPage(monitor: monitor, showApp: show(app:))
                case .apps: NetworkAppsPage(monitor: monitor, settings: settings, selection: $selectedApp)
                case .connections: NetworkConnectionsPage(monitor: monitor, settings: settings)
                case .lan: NetworkLANPage(monitor: monitor)
                case .topology: NetworkTopologyPage(monitor: monitor, showApp: show(app:))
                case .alerts: NetworkAlertsPage(monitor: monitor, settings: settings)
                }
            }
            .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.panelBackground)
        .onChange(of: page) { p in if p == .alerts { monitor.markAlertsRead() } }
        .id(settings.appLanguage)
    }

    private func show(app key: String) {
        selectedApp = key
        page = .apps
    }
}

/// 自绘侧边栏：与面板风格一致。
private struct Sidebar: View {
    @Binding var page: NetworkPage
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 40)   // 让出标题栏红绿灯
            HStack(spacing: 8) {
                Image(systemName: "network").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.cpu)
                Text(L10n.text("网络监控")).font(.system(size: 15, weight: .bold))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            ForEach(NetworkPage.allCases) { p in
                Button { page = p } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.symbol).font(.system(size: 12, weight: .medium)).frame(width: 18)
                        Text(p.title).font(.system(size: 13, weight: page == p ? .semibold : .regular))
                        Spacer()
                        let n = badge(p)
                        if n > 0 {
                            Text("\(n)").font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Palette.heat))
                        }
                    }
                    .foregroundStyle(page == p ? Palette.cpu : Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(page == p ? Palette.cpu.opacity(0.13) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.horizontal, 8)
            }
            Spacer()
            StatusFooter(monitor: monitor).padding(14)
        }
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    private func badge(_ p: NetworkPage) -> Int {
        p == .alerts ? monitor.alerts.filter { $0.kind.severity == .warning }.count : 0
    }
}

private struct StatusFooter: View {
    @ObservedObject var monitor: NetworkMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).font(.system(size: 11))
            }
            if let t = monitor.state.sampledAt {
                Text(String(format: L10n.text("更新于 %@"), t.formatted(date: .omitted, time: .standard)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text(String(format: L10n.text("运行 %@"), Fmt.duration(Date().timeIntervalSince(monitor.state.startedAt))))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch monitor.status {
        case .running: return Palette.memory
        case .starting: return Palette.wired
        case .stopped: return .gray
        case .failed: return Palette.heat
        }
    }

    private var text: String {
        switch monitor.status {
        case .running: return L10n.text("监控中")
        case .starting: return L10n.text("正在启动")
        case .stopped: return L10n.text("已停止")
        case .failed: return L10n.text("出错")
        }
    }
}

// MARK: - 公共组件

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct KPI: View {
    var title: String
    var value: String
    var sub: String? = nil
    var tint: Color = .primary
    var size: CGFloat = 20

    var body: some View {
        Card {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let sub { Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
        }
    }
}

struct ScopeBadge: View {
    var scope: AddressScope

    static func color(_ scope: AddressScope) -> Color {
        switch scope {
        case .internet: return Palette.upload
        case .reserved: return Palette.compressed
        case .lan: return Palette.memory
        case .loopback: return .gray
        }
    }

    var body: some View {
        Text(scope.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(ScopeBadge.color(scope))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(ScopeBadge.color(scope).opacity(0.14)))
    }
}

extension FlowInfo {
    func remoteDisplay(_ hostnames: [String: String]) -> String {
        guard let remote else { return local.map { String(format: L10n.text("监听 %@"), $0.display) } ?? "—" }
        if let host = hostnames[remote.address] { return "\(host):\(remote.port)" }
        return remote.display
    }

    var duration: TimeInterval { Date().timeIntervalSince(firstSeen) }
}
