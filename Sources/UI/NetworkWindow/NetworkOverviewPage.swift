//
//  NetworkOverviewPage.swift
//  Zest
//

import Charts
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour, day
    var id: String { rawValue }
    var title: String { self == .hour ? L10n.text("1 小时") : L10n.text("24 小时") }
}

/// 流量排行的通用行数据（本次 / 24 小时）。
struct TrafficRow: Identifiable {
    var key: String
    var name: String
    var bundlePath: String?
    var bytesIn: UInt64
    var bytesOut: UInt64
    var id: String { key }
    var total: UInt64 { bytesIn &+ bytesOut }
}

struct NetworkOverviewPage: View {
    @ObservedObject var monitor: NetworkMonitor
    var showApp: (String) -> Void
    @AppStorage("overviewRange") private var range = HistoryRange.hour

    var body: some View {
        let s = monitor.state
        let h = monitor.history
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: L10n.text("总览"), subtitle: L10n.text("所有进程的实时流量、连接与告警（数据来自系统 nettop，不抓包、不联网）")) {
                    HStack(spacing: 4) {
                        ForEach(HistoryRange.allCases) { r in
                            ChipButton(title: r.title, count: nil, selected: range == r) { range = r }
                        }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    KPI(title: L10n.text("traffic.download", defaultValue: "下载"), value: Fmt.rate(s.rateIn), tint: Palette.download)
                    KPI(title: L10n.text("traffic.upload", defaultValue: "上传"), value: Fmt.rate(s.rateOut), tint: Palette.upload)
                    if range == .hour {
                        KPI(title: L10n.text("本次流量"), value: Fmt.bytes(Double(s.sessionIn + s.sessionOut)),
                            sub: "↓\(Fmt.bytes(Double(s.sessionIn))) ↑\(Fmt.bytes(Double(s.sessionOut)))")
                    } else {
                        KPI(title: L10n.text("24 小时流量"), value: Fmt.bytes(Double(h.bytesIn + h.bytesOut)),
                            sub: "↓\(Fmt.bytes(Double(h.bytesIn))) ↑\(Fmt.bytes(Double(h.bytesOut)))")
                    }
                    KPI(title: L10n.text("活跃连接"), value: "\(s.activeFlows.filter { $0.scope != .loopback }.count)",
                        sub: String(format: L10n.text("监听 %lld"), Int64(s.flows.filter(\.isListening).count)))
                    KPI(title: L10n.text("联网应用"), value: "\(s.onlineApps.count)")
                    KPI(title: L10n.text("隐私评分"), value: "\(monitor.score.score)", tint: ScoreRing.color(monitor.score.score))
                }
                HStack(alignment: .top, spacing: 12) {
                    Card {
                        CardHeader(symbol: "waveform.path.ecg", title: L10n.text("实时（最近 5 分钟）"), tint: Palette.download)
                        LiveChart(points: s.live).frame(height: 170)
                    }
                    Card {
                        if range == .hour {
                            CardHeader(symbol: "chart.bar", title: L10n.text("最近 60 分钟（每分钟）"), tint: Palette.cpu)
                            MinuteChart(points: s.minutes).frame(height: 170)
                        } else {
                            CardHeader(symbol: "chart.bar", title: L10n.text("最近 24 小时（每 10 分钟）"), tint: Palette.cpu,
                                       trailing: String(format: L10n.text("已保存 %@"), Fmt.bytes(Double(h.storeSize))))
                            DayChart(points: h.day).frame(height: 170)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Card {
                        CardHeader(symbol: "list.number", title: range == .hour ? L10n.text("流量最多的应用（本次）") : L10n.text("流量最多的应用（24 小时）"),
                                   tint: Palette.cpu)
                        TopTrafficList(rows: topRows(s, h), showApp: showApp)
                    }
                    VStack(spacing: 12) {
                        Card {
                            CardHeader(symbol: "lock.shield", title: L10n.text("隐私评分"), tint: ScoreRing.color(monitor.score.score))
                            HStack(spacing: 14) {
                                ScoreRing(score: monitor.score.score, color: ScoreRing.color(monitor.score.score), lineWidth: 7)
                                    .frame(width: 70, height: 70)
                                VStack(alignment: .leading, spacing: 3) {
                                    if monitor.score.factors.isEmpty {
                                        Text(L10n.text("没有扣分项：未发现明文连接、可疑告警或对外开放的端口。"))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    ForEach(monitor.score.factors) { f in
                                        HStack {
                                            Text(f.label).font(.system(size: 11))
                                            Spacer()
                                            Text("−\(f.penalty)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                                .foregroundStyle(Palette.heat)
                                        }
                                    }
                                }
                            }
                        }
                        Card {
                            CardHeader(symbol: "bell.badge", title: L10n.text("最近告警"), tint: Palette.heat)
                            if monitor.alerts.isEmpty {
                                Label(L10n.text("未发现异常"), systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Palette.memory)
                            }
                            ForEach(monitor.alerts.prefix(4)) { AlertLine(alert: $0, compact: true) }
                        }
                    }
                    .frame(width: 330)
                }
                HStack(alignment: .top, spacing: 12) {
                    Card {
                        CardHeader(symbol: "globe.asia.australia", title: L10n.text("连接的国家 / 地区"), tint: Palette.download,
                                   trailing: L10n.text("按当前公网连接统计"))
                        GeoBreakdown(items: GeoAggregate.countries(s.activeFlows))
                    }
                    Card {
                        CardHeader(symbol: "building.2", title: L10n.text("主要网络服务商（ASN）"), tint: Palette.compressed)
                        GeoBreakdown(items: GeoAggregate.organizations(s.activeFlows))
                    }
                }
                Text(GeoAggregate.footnote(s.activeFlows))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
    }

    private func topRows(_ s: NetworkState, _ h: HistorySummary) -> [TrafficRow] {
        if range == .hour {
            return s.apps.filter { $0.sessionTotal > 0 }.sorted { $0.sessionTotal > $1.sessionTotal }.prefix(8)
                .map { TrafficRow(key: $0.key, name: $0.name, bundlePath: $0.bundlePath, bytesIn: $0.sessionIn, bytesOut: $0.sessionOut) }
        }
        return h.apps.prefix(8).map { TrafficRow(key: $0.key, name: $0.name, bundlePath: $0.bundlePath, bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) }
    }
}

/// 按国家 / 服务商汇总当前公网连接。
enum GeoAggregate {
    struct Item: Identifiable {
        var id: String
        var label: String
        var connections: Int
        var bytes: UInt64
    }

    static func countries(_ flows: [FlowInfo]) -> [Item] {
        group(flows) { g in
            guard let cc = g.countryCode else { return nil }
            return (cc, "\(g.flag) \(g.countryName ?? cc)")
        }
    }

    static func organizations(_ flows: [FlowInfo]) -> [Item] {
        group(flows) { g in
            guard let org = g.organization else { return nil }
            return ("\(g.asn ?? 0)", "\(org)  AS\(g.asn ?? 0)")
        }
    }

    private static func group(_ flows: [FlowInfo], key: (GeoInfo) -> (String, String)?) -> [Item] {
        var map: [String: Item] = [:]
        for f in flows where f.scope == .internet {
            guard let g = f.geo, let (id, label) = key(g) else { continue }
            map[id, default: Item(id: id, label: label, connections: 0, bytes: 0)].connections += 1
            map[id]?.bytes &+= f.bytesIn &+ f.bytesOut
        }
        return map.values.sorted { ($0.bytes, $0.connections) > ($1.bytes, $1.connections) }.prefix(8).map { $0 }
    }

    static func footnote(_ flows: [FlowInfo]) -> String {
        let reserved = flows.filter { $0.scope == .reserved }.count
        let edition = GeoIP.dataMonth.map { String(format: L10n.text("，%@ 版"), $0) } ?? ""
        var text = String(format: L10n.text("IP 归属地离线查询，数据来自 DB-IP Lite（CC BY 4.0，db-ip.com）%@；为国家级与 ASN 级精度。"), edition)
        if reserved > 0 {
            text += String(format: L10n.text("另有 %lld 条连接指向 198.18.0.0/15 等保留地址（通常是代理软件的 Fake IP），真实目的地无法从本机得知。"), Int64(reserved))
        }
        return text
    }
}

struct GeoBreakdown: View {
    var items: [GeoAggregate.Item]

    var body: some View {
        let top = Double(items.first?.bytes ?? 1)
        if items.isEmpty { Unavailable(text: L10n.text("暂无公网连接")) }
        ForEach(items) { item in
            HStack(spacing: 8) {
                Text(item.label).font(.system(size: 11.5)).lineLimit(1).frame(width: 220, alignment: .leading)
                GeometryReader { g in
                    Capsule().fill(Palette.download.opacity(0.75))
                        .frame(width: max(g.size.width * CGFloat(Double(item.bytes) / max(top, 1)), 3))
                }
                .frame(height: 6)
                Text(String(format: L10n.text("%lld 条"), Int64(item.connections))).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Text(Fmt.bytes(Double(item.bytes))).font(.system(size: 10.5).monospacedDigit())
                    .frame(width: 66, alignment: .trailing)
            }
            .frame(height: 20)
        }
    }
}

/// 24 小时柱状图（每 10 分钟一个桶）。
struct DayChart: View {
    var points: [TrafficPoint]
    var language: AppLanguage = .system

    var body: some View {
        let _ = language
        let n = points.count
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                BarMark(x: .value(L10n.text("时间"), i), y: .value(L10n.text("流量"), p.bytesIn), width: .fixed(2.5))
                    .foregroundStyle(Palette.download)
                BarMark(x: .value(L10n.text("时间"), i), y: .value(L10n.text("流量"), p.bytesOut), width: .fixed(2.5))
                    .foregroundStyle(Palette.upload)
            }
        }
        .chartXScale(domain: 0...max(n, 1))
        .chartXAxis {
            AxisMarks(values: stride(from: 0, through: max(n, 1), by: 36).map { $0 }) { v in
                AxisValueLabel {
                    if let i = v.as(Int.self) {
                        let hoursAgo = Int((Double(n - 1 - i) * Double(HistorySummary.bucketMinutes) / 60).rounded())
                        Text(hoursAgo <= 0 ? L10n.text("现在") : String(format: L10n.text("−%lld 小时"), Int64(hoursAgo))).font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compactBytes(d)).font(.system(size: 9)) } }
            }
        }
        .overlay {
            if points.allSatisfy({ $0.bytesIn + $0.bytesOut == 0 }) {
                Text(L10n.text("历史数据从首次运行开始累积，每分钟保存一次")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct LiveChart: View {
    var points: [TrafficPoint]
    var language: AppLanguage = .system

    var body: some View {
        let _ = language
        let indexed = Array(points.enumerated())
        Chart {
            ForEach(indexed, id: \.offset) { i, p in
                AreaMark(x: .value("t", i), y: .value(L10n.text("traffic.download", defaultValue: "下载"), p.bytesIn), series: .value(L10n.text("方向"), L10n.text("traffic.download", defaultValue: "下载")))
                    .foregroundStyle(LinearGradient(colors: [Palette.download.opacity(0.35), Palette.download.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", i), y: .value(L10n.text("traffic.download", defaultValue: "下载"), p.bytesIn), series: .value(L10n.text("方向"), L10n.text("traffic.download", defaultValue: "下载")))
                    .foregroundStyle(Palette.download)
                LineMark(x: .value("t", i), y: .value(L10n.text("traffic.upload", defaultValue: "上传"), p.bytesOut), series: .value(L10n.text("方向"), L10n.text("traffic.upload", defaultValue: "上传")))
                    .foregroundStyle(Palette.upload)
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...max(NetworkTracker.liveCapacity - 1, indexed.count))
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compactRate(d)).font(.system(size: 9)) } }
            }
        }
        .overlay(alignment: .topTrailing) { ChartLegend(language: language) }
    }
}

struct MinuteChart: View {
    var points: [TrafficPoint]
    var language: AppLanguage = .system

    var body: some View {
        let _ = language
        let indexed = Array(points.enumerated())
        let offset = max(NetworkTracker.minuteCapacity + 1 - points.count, 0)
        Chart {
            ForEach(indexed, id: \.offset) { i, p in
                BarMark(x: .value(L10n.text("分钟"), i + offset), y: .value(L10n.text("流量"), p.bytesIn), width: .fixed(5))
                    .foregroundStyle(Palette.download)
                BarMark(x: .value(L10n.text("分钟"), i + offset), y: .value(L10n.text("流量"), p.bytesOut), width: .fixed(5))
                    .foregroundStyle(Palette.upload)
            }
        }
        .chartXScale(domain: 0...NetworkTracker.minuteCapacity + 1)
        .chartXAxis {
            AxisMarks(values: [0, 15, 30, 45, 60]) { v in
                AxisValueLabel {
                    if let m = v.as(Int.self) { Text(m == 60 ? L10n.text("现在") : String(format: L10n.text("−%lld 分"), Int64(60 - m))).font(.system(size: 9)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compactBytes(d)).font(.system(size: 9)) } }
            }
        }
        .overlay(alignment: .topTrailing) { ChartLegend(language: language) }
    }
}

private struct ChartLegend: View {
    var language: AppLanguage = .system

    var body: some View {
        let _ = language
        HStack(spacing: 8) {
            Label { Text(L10n.text("traffic.download", defaultValue: "下载")) } icon: { Circle().fill(Palette.download).frame(width: 6, height: 6) }
            Label { Text(L10n.text("traffic.upload", defaultValue: "上传")) } icon: { Circle().fill(Palette.upload).frame(width: 6, height: 6) }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(4)
    }
}

private struct TopTrafficList: View {
    var rows: [TrafficRow]
    var showApp: (String) -> Void

    var body: some View {
        let top = Double(rows.first?.total ?? 1)
        if rows.isEmpty { Unavailable(text: L10n.text("开始监控后将在这里列出流量最多的应用")) }
        ForEach(rows) { app in
            Button { showApp(app.key) } label: {
                HStack(spacing: 8) {
                    AppIcon(bundlePath: app.bundlePath, size: 18)
                    Text(app.name).font(.system(size: 12)).lineLimit(1).frame(width: 150, alignment: .leading)
                    GeometryReader { g in
                        HStack(spacing: 0) {
                            Rectangle().fill(Palette.download)
                                .frame(width: g.size.width * CGFloat(Double(app.bytesIn) / max(top, 1)))
                            Rectangle().fill(Palette.upload)
                                .frame(width: g.size.width * CGFloat(Double(app.bytesOut) / max(top, 1)))
                            Spacer(minLength: 0)
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 6)
                    Text(Fmt.bytes(Double(app.total))).font(.system(size: 11).monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 22)
        }
    }
}
