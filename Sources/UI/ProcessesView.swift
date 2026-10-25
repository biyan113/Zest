//
//  ProcessesView.swift
//  Zest
//
//  “占用最高”卡片与“进程”页：查看哪个应用占用 CPU / 内存，并可退出或强制退出。
//  鼠标在列表上时冻结排序（数值照常刷新），避免点击时行被刷新挤走。
//

import SwiftUI

enum ProcessFmt {
    static func cpu(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }
    static func memory(_ bytes: UInt64) -> String { Fmt.bytes(Double(bytes)) }
}

/// 鼠标悬停期间保持行顺序不变：已有行按冻结时的顺序，新出现的排在最后。
struct FrozenOrder {
    private var order: [String: Int]?

    var isFrozen: Bool { order != nil }

    mutating func freeze(_ ids: [String]) {
        order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    mutating func release() { order = nil }

    func apply(_ apps: [AppUsage]) -> [AppUsage] {
        guard let order else { return apps }
        return apps.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }
}

// MARK: - 概览页卡片

struct TopProcessesCard: View {
    @ObservedObject var monitor: ProcessMonitor
    var showAll: () -> Void
    @State private var frozen: [ProcessMetric: FrozenOrder] = [:]

    static let rows = 3

    var body: some View {
        Card {
            CardHeader(symbol: "list.bullet.rectangle", title: L10n.text("占用最高"), tint: Palette.upload)
                .overlay(alignment: .trailing) {
                    Button(action: showAll) {
                        HStack(spacing: 2) {
                            Text(L10n.text("全部进程"))
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.cpu)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            HStack(alignment: .top, spacing: 12) {
                column(.cpu)
                column(.memory)
            }
        }
    }

    private func column(_ metric: ProcessMetric) -> some View {
        let live = monitor.reading?.top(by: metric, limit: TopProcessesCard.rows) ?? []
        let apps = frozen[metric]?.apply(live) ?? live
        return VStack(alignment: .leading, spacing: 1) {
            Text(metric == .cpu ? "CPU" : L10n.text("内存"))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            ForEach(0..<TopProcessesCard.rows, id: \.self) { i in
                if i < apps.count {
                    TopRow(app: apps[i], metric: metric, hasCPU: monitor.reading?.hasCPU ?? false, monitor: monitor)
                } else {
                    Text(monitor.reading == nil ? L10n.text("读取中…") : " ")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(height: 22).padding(.leading, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { inside in
            if inside { frozen[metric, default: FrozenOrder()].freeze(apps.map(\.id)) } else { frozen[metric]?.release() }
        }
    }
}

private struct TopRow: View {
    var app: AppUsage
    var metric: ProcessMetric
    var hasCPU: Bool
    var monitor: ProcessMonitor
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            AppIcon(bundlePath: app.bundlePath, size: 14)
            Text(app.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            if app.kind == .system { KindTag(kind: .system) }
            Spacer(minLength: 2)
            Text(metric == .cpu ? (hasCPU ? ProcessFmt.cpu(app.cpu) : "…") : ProcessFmt.memory(app.memory))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(metric == .cpu ? Palette.load(min(app.cpu, 1)) : .primary)
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { ProcessActionMenu.shared.show(for: app, monitor: monitor) }
        .help(String(format: L10n.text("%@：CPU %@ · 内存 %@ · %lld 个进程，点击可退出"),
                     app.name, ProcessFmt.cpu(app.cpu), ProcessFmt.memory(app.memory), Int64(app.processes.count)))
    }
}

// MARK: - 进程页

enum ProcessFilter: String, CaseIterable, Identifiable {
    case apps, commandLine, system, all
    var id: String { rawValue }

    var kinds: Set<ProcessKind> {
        switch self {
        case .apps: return [.app]
        case .commandLine: return [.commandLine]
        case .system: return [.system]
        case .all: return Set(ProcessKind.allCases)
        }
    }

    var title: String {
        switch self {
        case .apps: return L10n.text("process.kind.app", defaultValue: "应用")
        case .commandLine: return L10n.text("命令行")
        case .system: return L10n.text("process.kind.system", defaultValue: "系统")
        case .all: return L10n.text("filter.all", defaultValue: "全部")
        }
    }
}

struct ProcessesView: View {
    @ObservedObject var monitor: ProcessMonitor
    var availableHeight: CGFloat = 480
    @AppStorage("processSort") private var sort = ProcessMetric.cpu
    @AppStorage("processFilter") private var filter = ProcessFilter.apps
    @State private var frozen = FrozenOrder()

    static let listLimit = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = monitor.reading {
                filterBar(r)
                let live = Array(r.sorted(by: sort, kinds: filter.kinds).prefix(ProcessesView.listLimit))
                let apps = frozen.apply(live)
                Card {
                    columnHeader
                    NativeProcessTable(apps: apps, metric: sort, hasCPU: r.hasCPU,
                                       showKind: filter == .all, monitor: monitor)
                        .frame(height: max(120, availableHeight - 70))
                    if apps.isEmpty {
                        Unavailable(text: emptyText).frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
                .onHover { inside in
                    if inside { frozen.freeze(apps.map(\.id)) } else { frozen.release() }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 400)
            }
        }
    }

    private func filterBar(_ r: ProcessesReading) -> some View {
        HStack(spacing: 4) {
            ForEach(ProcessFilter.allCases) { f in
                let count = f == .all ? r.apps.count : f.kinds.reduce(0) { $0 + r.count(of: $1) }
                ChipButton(title: f.title, count: count, selected: filter == f) {
                    filter = f
                    frozen.release()
                }
            }
            Spacer()
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.text("名称")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            sortHeader(.cpu, width: ProcessTableLayout.cpuWidth)
            sortHeader(.memory, width: ProcessTableLayout.memoryWidth)
            Color.clear.frame(width: ProcessTableLayout.trailingWidth)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }

    private func sortHeader(_ metric: ProcessMetric, width: CGFloat) -> some View {
        Button {
            sort = metric
            frozen.release()
        } label: {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                Text(metric.title)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(sort == metric ? 1 : 0)
            }
            .foregroundStyle(sort == metric ? Palette.cpu : Color.secondary)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(metric == .cpu ? L10n.text("按CPU排序") : L10n.text("按内存排序"))
    }

    private var emptyText: String {
        switch filter {
        case .apps: return L10n.text("没有应用进程")
        case .commandLine: return L10n.text("没有命令行进程")
        case .system: return L10n.text("没有系统进程")
        case .all: return L10n.text("没有全部进程")
        }
    }
}

private enum ProcessTableLayout {
    static let cpuWidth: CGFloat = 52
    static let memoryWidth: CGFloat = 64
    static let trailingWidth: CGFloat = 22
}

struct KindTag: View {
    var kind: ProcessKind

    var body: some View {
        Text(kind.title)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(kind == .system ? Color.secondary : Palette.cpu)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill((kind == .system ? Color.secondary : Palette.cpu).opacity(0.14)))
    }
}

struct ChipButton: View {
    var title: String
    var count: Int?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if let count { Text("\(count)").monospacedDigit().opacity(0.6) }
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Palette.cpu : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? Palette.cpu.opacity(0.14) : Color.primary.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 强制退出确认条，浮在面板内容区底部，不改变面板尺寸。
struct ForceQuitBanner: View {
    @ObservedObject var monitor: ProcessMonitor

    var body: some View {
        if let target = monitor.pendingForceQuit {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.heat)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
                    Text(L10n.text("未保存的内容将会丢失")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(L10n.text("取消")) { monitor.pendingForceQuit = nil }
                    .buttonStyle(BannerButtonStyle(prominent: false))
                Button(L10n.text("强制退出")) { monitor.confirmForceQuit() }
                    .buttonStyle(BannerButtonStyle(prominent: true))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.panelBackground))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.heat.opacity(0.5)))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            .padding(4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct BannerButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(prominent ? Palette.heat : Color.primary.opacity(0.08)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
