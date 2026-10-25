//
//  NetworkAppsPage.swift
//  Zest
//

import Charts
import SwiftUI

struct NetworkAppsPage: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var settings: AppSettings
    @Binding var selection: String?
    @State private var search = ""
    @State private var showSystem = true
    @AppStorage("appsRange") private var range = HistoryRange.hour

    var body: some View {
        let _ = settings.appLanguage
        let apps = filteredApps
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField(L10n.text("搜索应用"), text: $search).textFieldStyle(.plain)
                    Toggle(L10n.text("kind.system", defaultValue: "系统"), isOn: $showSystem).toggleStyle(.checkbox).font(.system(size: 11))
                }
                .padding(8)
                HStack(spacing: 4) {
                    ForEach(HistoryRange.allCases) { r in
                        ChipButton(title: r == .hour ? L10n.text("range.session", defaultValue: "本次") : L10n.text("24 小时"), count: nil, selected: range == r) { range = r }
                    }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
                Divider()
                List(apps, selection: $selection) { app in
                    HStack(spacing: 8) {
                        AppIcon(bundlePath: app.bundlePath, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(app.name).font(.system(size: 12)).lineLimit(1)
                                if app.kind == .system { KindTag(kind: .system) }
                            }
                            Text("↓\(Fmt.compactRate(app.rateIn))  ↑\(Fmt.compactRate(app.rateOut))")
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.bytes(Double(listTotal(app)))).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(app.key)
                }
            }
            .frame(minWidth: 230, idealWidth: 250, maxWidth: 340)

            Group {
                if let key = selection, let app = detailApp(key) {
                    AppDetail(app: app, day: monitor.history.apps.first { $0.key == key }, daySeries: monitor.appDay[key],
                              range: range, flows: monitor.state.flows.filter { $0.appKey == key }, hostnames: monitor.hostnames,
                              resolve: settings.resolveHostnames, language: settings.appLanguage)
                        .onAppear { monitor.loadAppHistory(key) }
                        .onChange(of: key) { monitor.loadAppHistory($0) }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text(L10n.text("选择一个应用，查看它连接了哪里、用了多少流量")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = apps.first?.key } }
    }

    private var filteredApps: [AppTraffic] {
        let base: [AppTraffic]
        if range == .hour {
            let flowKeys = Set(monitor.state.flows.map(\.appKey))
            base = monitor.state.apps.filter { $0.sessionTotal > 0 || flowKeys.contains($0.key) }
        } else {
            // 24 小时：以持久化数据为准，包含已退出的应用；仍在运行的附带实时速率。
            base = monitor.history.apps.map { d in detailApp(d.key) ?? placeholder(d) }
        }
        return base
            .filter { showSystem || $0.kind != .system }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func listTotal(_ app: AppTraffic) -> UInt64 {
        range == .hour ? app.sessionTotal : (monitor.history.apps.first { $0.key == app.key }?.total ?? 0)
    }

    private func detailApp(_ key: String) -> AppTraffic? {
        monitor.state.apps.first { $0.key == key } ?? monitor.history.apps.first { $0.key == key }.map(placeholder)
    }

    private func placeholder(_ d: AppDayTotal) -> AppTraffic {
        AppTraffic(key: d.key, name: d.name, bundlePath: d.bundlePath, kind: d.kind, pids: [])
    }
}

private struct AppDetail: View {
    var app: AppTraffic
    var day: AppDayTotal?
    var daySeries: [TrafficPoint]?
    var range: HistoryRange
    var flows: [FlowInfo]
    var hostnames: [String: String]
    var resolve: Bool
    var language: AppLanguage

    var body: some View {
        let _ = language
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AppIcon(bundlePath: app.bundlePath, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.system(size: 18, weight: .bold))
                            KindTag(kind: app.kind)
                        }
                        Text(app.bundlePath ?? (app.pids.isEmpty ? L10n.text("已退出") : "PID " + app.pids.sorted().map(String.init).joined(separator: ", ")))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let path = app.bundlePath {
                        Button(L10n.text("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    KPI(title: L10n.text("下载速率"), value: Fmt.compactRate(app.rateIn), tint: Palette.download, size: 16)
                    KPI(title: L10n.text("上传速率"), value: Fmt.compactRate(app.rateOut), tint: Palette.upload, size: 16)
                    if range == .hour {
                        KPI(title: L10n.text("本次下载"), value: Fmt.compactBytes(Double(app.sessionIn)), size: 16)
                        KPI(title: L10n.text("本次上传"), value: Fmt.compactBytes(Double(app.sessionOut)), size: 16)
                    } else {
                        KPI(title: L10n.text("24 小时下载"), value: Fmt.compactBytes(Double(day?.bytesIn ?? 0)), size: 16)
                        KPI(title: L10n.text("24 小时上传"), value: Fmt.compactBytes(Double(day?.bytesOut ?? 0)), size: 16)
                    }
                    KPI(title: L10n.text("活跃连接"), value: "\(flows.filter(\.isEstablished).count)",
                        sub: String(format: L10n.text("监听 %lld"), Int64(flows.filter(\.isListening).count)), size: 16)
                }
                Card {
                    if range == .hour {
                        CardHeader(symbol: "chart.bar", title: L10n.text("最近 60 分钟流量"), tint: Palette.cpu)
                        MinuteChart(points: app.minutes, language: language).frame(height: 130)
                    } else {
                        CardHeader(symbol: "chart.bar", title: L10n.text("最近 24 小时流量（每 10 分钟）"), tint: Palette.cpu)
                        DayChart(points: daySeries ?? [], language: language).frame(height: 130)
                    }
                }
                Card {
                    CardHeader(symbol: "point.3.connected.trianglepath.dotted", title: L10n.text("目的地"), tint: Palette.download,
                               trailing: resolve ? nil : L10n.text("可在设置中开启主机名解析"))
                    DestinationTable(flows: flows.filter { $0.remote != nil }, hostnames: hostnames, language: language)
                }
                let listening = flows.filter(\.isListening)
                if !listening.isEmpty {
                    Card {
                        CardHeader(symbol: "door.left.hand.open", title: L10n.text("监听端口"), tint: Palette.disk)
                        ForEach(listening) { f in
                            HStack {
                                Text("\(f.proto.rawValue) \(f.local?.display ?? "—")").font(.system(size: 11, design: .monospaced))
                                Spacer()
                                if ["*", "0.0.0.0", "::"].contains(f.local?.address ?? "") {
                                    Text(L10n.text("所有接口")).font(.system(size: 10)).foregroundStyle(Palette.wired)
                                } else {
                                    Text(L10n.text("仅本机")).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct DestinationTable: View {
    var flows: [FlowInfo]
    var hostnames: [String: String]
    var language: AppLanguage

    var body: some View {
        let _ = language
        if flows.isEmpty { Unavailable(text: L10n.text("当前没有外部连接")) }
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("远端")).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                Text(L10n.text("服务")).frame(width: 46, alignment: .leading)
                Text(L10n.text("范围")).frame(width: 50, alignment: .leading)
                Text(L10n.text("状态")).frame(width: 50, alignment: .leading)
                Text(L10n.text("traffic.download", defaultValue: "下载")).frame(width: 62, alignment: .trailing)
                Text(L10n.text("traffic.upload", defaultValue: "上传")).frame(width: 62, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(flows.sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.remoteDisplay(hostnames)).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        if let g = f.geo {
                            Text(g.summary).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    Text(f.service ?? f.proto.rawValue).font(.system(size: 10.5)).frame(width: 46, alignment: .leading)
                    ScopeBadge(scope: f.scope).frame(width: 50, alignment: .leading)
                    Text(f.stateLabel).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)
                    Text(Fmt.bytes(Double(f.bytesIn))).frame(width: 62, alignment: .trailing)
                    Text(Fmt.bytes(Double(f.bytesOut))).frame(width: 62, alignment: .trailing)
                }
                .font(.system(size: 10.5).monospacedDigit())
                .frame(minHeight: 22)
                .padding(.vertical, 2)
                Divider().opacity(0.4)
            }
        }
    }
}
