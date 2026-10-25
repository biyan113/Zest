//
//  NetworkTopologyPage.swift
//  Zest
//
//  连接拓扑（参考 snitch 的力导向图，改为确定性的放射布局，避免持续物理模拟的开销）：
//  中心为本机，内圈为联网应用，外圈为各应用流量最大的远端；连线颜色表示网络范围。
//

import SwiftUI

struct NetworkTopologyPage: View {
    @ObservedObject var monitor: NetworkMonitor
    var showApp: (String) -> Void
    @State private var hovered: String?

    static let maxApps = 10
    static let maxDestinations = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: L10n.text("拓扑"), subtitle: String(format: L10n.text("本机 → 应用 → 远端（流量最多的 %lld 个应用）。悬停查看远端地址，点击查看详情"), Int64(NetworkTopologyPage.maxApps))) {
                HStack(spacing: 10) {
                    ForEach([AddressScope.internet, .reserved, .lan], id: \.self) { s in
                        HStack(spacing: 4) {
                            Capsule().fill(ScopeBadge.color(s)).frame(width: 14, height: 3)
                            Text(s.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            GeometryReader { geo in
                let layout = TopologyLayout(state: monitor.state, size: geo.size)
                ZStack {
                    Canvas { ctx, _ in
                        for edge in layout.edges {
                            var p = Path()
                            p.move(to: edge.from)
                            p.addQuadCurve(to: edge.to, control: CGPoint(x: (edge.from.x + edge.to.x) / 2 + (edge.to.y - edge.from.y) * 0.08,
                                                                        y: (edge.from.y + edge.to.y) / 2 - (edge.to.x - edge.from.x) * 0.08))
                            let dim = hovered != nil && hovered != edge.appKey
                            ctx.stroke(p, with: .color(edge.color.opacity(dim ? 0.12 : 0.55)), lineWidth: edge.width)
                        }
                        for d in layout.destinations {
                            let dim = hovered != nil && hovered != d.appKey
                            let r: CGFloat = 4
                            ctx.fill(Path(ellipseIn: CGRect(x: d.point.x - r, y: d.point.y - r, width: r * 2, height: r * 2)),
                                     with: .color(ScopeBadge.color(d.scope).opacity(dim ? 0.25 : 1)))
                            if hovered == d.appKey {
                                let label = [d.geo.map { "\($0.flag) \($0.organization ?? $0.countryName ?? "")" }, monitor.hostnames[d.address] ?? d.address]
                                    .compactMap { $0 }.joined(separator: "  ")
                                ctx.draw(Text(label)
                                            .font(.system(size: 9.5, design: .monospaced)).foregroundColor(.secondary),
                                         at: CGPoint(x: d.point.x + (d.point.x >= layout.center.x ? 6 : -6), y: d.point.y),
                                         anchor: d.point.x >= layout.center.x ? .leading : .trailing)
                            }
                        }
                    }
                    Circle().fill(Palette.cpu).frame(width: 46, height: 46)
                        .overlay(Image(systemName: "laptopcomputer").foregroundStyle(.white).font(.system(size: 18)))
                        .position(layout.center)
                    ForEach(layout.apps, id: \.app.key) { node in
                        Button { showApp(node.app.key) } label: {
                            VStack(spacing: 2) {
                                AppIcon(bundlePath: node.app.bundlePath, size: 24)
                                Text(node.app.name).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(maxWidth: 84)
                                if hovered == node.app.key {
                                    Text("↓\(Fmt.compactRate(node.app.rateIn)) ↑\(Fmt.compactRate(node.app.rateOut))")
                                        .font(.system(size: 8.5).monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardBackground)
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1))
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? node.app.key : (hovered == node.app.key ? nil : hovered) }
                        .position(node.point)
                    }
                    if layout.apps.isEmpty {
                        Unavailable(text: L10n.text("暂无外部连接")).position(x: layout.center.x, y: layout.center.y + 50)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        }
        .padding(20)
    }
}

struct TopologyLayout {
    struct AppNode { var app: AppTraffic; var point: CGPoint }
    struct DestNode { var appKey: String; var address: String; var scope: AddressScope; var point: CGPoint; var geo: GeoInfo? }
    struct Edge { var appKey: String; var from: CGPoint; var to: CGPoint; var color: Color; var width: CGFloat }

    var center: CGPoint
    var apps: [AppNode] = []
    var destinations: [DestNode] = []
    var edges: [Edge] = []

    init(state: NetworkState, size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        let external = state.activeFlows.filter { $0.scope != .loopback }
        let byApp = Dictionary(grouping: external, by: \.appKey)
        let chosen = state.apps.filter { byApp[$0.key] != nil }
            .sorted { ($0.rateTotal, $0.sessionTotal) > ($1.rateTotal, $1.sessionTotal) }
            .prefix(NetworkTopologyPage.maxApps)
        guard !chosen.isEmpty else { return }
        let r1 = min(size.width, size.height) * 0.30
        let r2 = min(size.width, size.height) * 0.46
        let maxRate = max(chosen.map(\.rateTotal).max() ?? 1, 1)
        for (i, app) in chosen.enumerated() {
            let angle = Double(i) / Double(chosen.count) * 2 * .pi - .pi / 2
            // 横向拉宽成椭圆，利用窗口的宽度
            let p = CGPoint(x: center.x + CGFloat(cos(angle)) * r1 * 1.35, y: center.y + CGFloat(sin(angle)) * r1)
            apps.append(AppNode(app: app, point: p))
            edges.append(Edge(appKey: app.key, from: center, to: p, color: Palette.cpu,
                              width: 1 + 4 * CGFloat(sqrt(app.rateTotal / maxRate))))
            // 每个应用流量最大的几个远端
            var totals: [String: (UInt64, AddressScope)] = [:]
            var geos: [String: GeoInfo] = [:]
            for f in byApp[app.key] ?? [] {
                guard let addr = f.remote?.address else { continue }
                totals[addr] = ((totals[addr]?.0 ?? 0) &+ f.bytesIn &+ f.bytesOut, f.scope)
                if let g = f.geo { geos[addr] = g }
            }
            let dests = totals.sorted { $0.value.0 > $1.value.0 }.prefix(NetworkTopologyPage.maxDestinations)
            let spread = 2 * .pi / Double(chosen.count) * 0.7
            for (j, d) in dests.enumerated() {
                let offset = dests.count > 1 ? (Double(j) / Double(dests.count - 1) - 0.5) * spread : 0
                let a = angle + offset
                let q = CGPoint(x: center.x + CGFloat(cos(a)) * r2 * 1.45, y: center.y + CGFloat(sin(a)) * r2)
                destinations.append(DestNode(appKey: app.key, address: d.key, scope: d.value.1, point: q, geo: geos[d.key]))
                edges.append(Edge(appKey: app.key, from: p, to: q, color: ScopeBadge.color(d.value.1), width: 1.2))
            }
        }
    }
}
