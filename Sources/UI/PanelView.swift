//
//  PanelView.swift
//  Zest
//

import SwiftUI

struct PanelView: View {
    var store: MonitorStore
    @ObservedObject var settings: AppSettings
    var network: NetworkMonitor
    var processes: ProcessMonitor
    /// 内容区（概览/连接）的固定高度，由弹出前的测量决定；面板显示期间不变，
    /// 避免弹窗变高时以底边为基准向上生长而超出屏幕。nil 表示按内容自然高度（仅用于测量）。
    var contentHeight: CGFloat?
    var openSettings: () -> Void
    var openNetworkWindow: () -> Void = {}
    var quit: () -> Void
    var onTabChange: (PanelTab) -> Void = { _ in }

    @AppStorage("panelTab") private var tab = PanelTab.overview

    enum PanelTab: String, CaseIterable { case overview, processes, network }

    static let width: CGFloat = 372
    static let padding: CGFloat = 12
    static var contentWidth: CGFloat { width - padding * 2 }
    static let isPerformanceRun: Bool = {
        #if PERFORMANCE_TEST
        return CommandLine.arguments.contains("--performance-panel")
        #else
        return false
        #endif
    }()

    var body: some View {
        VStack(spacing: 8) {
            PanelHeader(store: store)
            PanelTabBar(selection: $tab)
                .disabled(Self.isPerformanceRun)
            content
            PanelFooter(openSettings: openSettings, quit: quit)
        }
        .padding(PanelView.padding)
        .frame(width: PanelView.width)
        .background(Palette.panelBackground)
        .onAppear { onTabChange(tab) }
        .onChange(of: tab) { onTabChange($0) }
        .id(settings.appLanguage)
    }

    @ViewBuilder private var content: some View {
        if let contentHeight {
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch tab {
                    case .overview: overview
                    case .processes: ProcessesView(monitor: processes, availableHeight: contentHeight)
                    case .network: NetworkSummaryView(monitor: network, settings: settings,
                                                     openWindow: openNetworkWindow, openSettings: openSettings)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(height: contentHeight)
            .overlay(alignment: .bottom) {
                ForceQuitBanner(monitor: processes)
                    .animation(.easeOut(duration: 0.18), value: processes.pendingForceQuit)
            }
        } else {
            overview
        }
    }

    private var overview: some View {
        OverviewContent(store: store, settings: settings, processes: processes) { tab = .processes }
    }

}

// 把每秒变化的信息限制在各自子树中，避免带着整个进程列表重新求值。
private struct PanelHeader: View {
    @ObservedObject var store: MonitorStore
    private let info = SystemInfo.current

    var body: some View {
        let s = store.snapshot
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.chip).font(.system(size: 13, weight: .semibold))
                Text(String(format: L10n.text("%@ · %@ · 已运行 %@"),
                            info.model,
                            Fmt.bytes(Double(info.physicalMemory)),
                            Fmt.duration(SystemInfo.uptime)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let thermal = s?.thermalState {
                ThermalBadge(state: thermal)
            }
        }
        .padding(.horizontal, 2)
    }

}

private struct PanelFooter: View {
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .help(Text(L10n.text("设置")))
            Button(action: quit) { Image(systemName: "power") }
                .help(Text(L10n.text("退出 Zest")))
        }
        .buttonStyle(FooterButtonStyle())
        .padding(.horizontal, 2)
    }
}

struct OverviewContent: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var settings: AppSettings
    var processes: ProcessMonitor
    var showProcesses: () -> Void = {}

    var body: some View {
        let s = store.snapshot
        VStack(spacing: 8) {
            CPUCard(cpu: s?.cpu, sensors: s?.sensors, history: store.cpuHistory.elements,
                    kinds: store.coreKinds, unit: settings.temperatureUnit)
            TopProcessesCard(monitor: processes, showAll: showProcesses)
            HStack(alignment: .top, spacing: 8) {
                MemoryCard(memory: s?.memory, history: store.memoryHistory.elements)
                NetworkCard(network: s?.network, down: store.downloadHistory.elements, up: store.uploadHistory.elements)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                DiskCard(disk: s?.disk, read: store.diskReadHistory.elements, write: store.diskWriteHistory.elements)
                SensorsCard(sensors: s?.sensors, unit: settings.temperatureUnit)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .id(settings.appLanguage)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06)))
            .contentShape(Rectangle())
    }
}

private struct ThermalBadge: View {
    var state: ProcessInfo.ThermalState

    var body: some View {
        let color: Color = {
            switch state {
            case .nominal: return Palette.memory
            case .fair: return Color(red: 1.0, green: 0.75, blue: 0.2)
            default: return Palette.heat
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(String(format: L10n.text("热状态 %@"), state.label)).font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .help(Text(L10n.text("系统热状态（ProcessInfo.thermalState，公开 API）")))
    }
}

// MARK: - CPU

private struct CPUCard: View {
    var cpu: CPUReading?
    var sensors: SensorReading?
    var history: [Double]
    var kinds: [CoreKind]
    var unit: TemperatureUnit

    var body: some View {
        Card {
            CardHeader(symbol: "cpu", title: "CPU", tint: Palette.cpu,
                       trailing: cpu.map { String(format: L10n.text("负载 %.2f  %.2f  %.2f"), $0.loadAverage.0, $0.loadAverage.1, $0.loadAverage.2) })
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    BigValue(value: cpu.map { Fmt.percent($0.usage) } ?? "--", tint: Palette.load(cpu?.usage ?? 0))
                    StatRow(label: L10n.text("用户"), value: cpu.map { Fmt.percent($0.user) } ?? "--", dot: Palette.cpu)
                    StatRow(label: L10n.text("cpu.system", defaultValue: "系统"), value: cpu.map { Fmt.percent($0.system) } ?? "--", dot: Palette.cpuSystem)
                }
                .frame(width: 96)
                Sparkline(values: history, maxValue: 1, color: Palette.cpu)
                    .frame(height: 54)
            }
            if let cores = cpu?.cores, !cores.isEmpty {
                CoreBars(cores: cores, kinds: kinds).frame(height: 22)
                coreLegend
            }
            Divider().opacity(0.5)
            temperatureRow
        }
    }

    @ViewBuilder private var coreLegend: some View {
        let p = kinds.filter { $0 == .performance }.count
        let e = kinds.filter { $0 == .efficiency }.count
        HStack(spacing: 10) {
            if p > 0 || e > 0 {
                legend(color: Palette.cpu, text: String(format: L10n.text("性能核 ×%lld"), Int64(p)))
                legend(color: Palette.cpu.opacity(0.55), text: String(format: L10n.text("能效核 ×%lld"), Int64(e)))
            } else {
                Text(String(format: L10n.text("%lld 个逻辑核心"), Int64(cpu?.cores.count ?? 0)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var temperatureRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 11))
                .foregroundStyle(Palette.heat)
            if let t = sensors?.cpuTemperature {
                Text(L10n.text("CPU 温度")).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(Fmt.temperature(t, unit: unit, decimals: true))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.temperature(t))
                if let max = sensors?.cpuTemperatureMax {
                    Text(String(format: L10n.text("最高 %@"), Fmt.temperature(max, unit: unit)))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer()
                if let g = sensors?.gpuTemperature {
                    Text("GPU").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(Fmt.temperature(g, unit: unit, decimals: true))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Palette.temperature(g))
                }
            } else {
                Text(L10n.text("CPU 温度")).font(.system(size: 11)).foregroundStyle(.secondary)
                Unavailable(text: sensors == nil ? L10n.text("读取中…") : L10n.text("不可用（未找到可读传感器）"))
                Spacer()
            }
        }
    }
}

// MARK: - 内存

private struct MemoryCard: View {
    var memory: MemoryReading?
    var history: [Double]

    var body: some View {
        Card {
            CardHeader(symbol: "memorychip", title: L10n.text("内存"), tint: Palette.memory,
                       trailing: memory.map { Fmt.bytes(Double($0.total)) })
            if let m = memory {
                BigValue(value: Fmt.bytes(Double(m.used)).replacingOccurrences(of: " ", with: ""),
                         unit: Fmt.percent(m.usedFraction), tint: .primary)
                SegmentedBar(segments: [
                    .init(id: "app", fraction: Double(m.app) / Double(m.total), color: Palette.memory),
                    .init(id: "wired", fraction: Double(m.wired) / Double(m.total), color: Palette.wired),
                    .init(id: "comp", fraction: Double(m.compressed) / Double(m.total), color: Palette.compressed),
                ])
                StatRow(label: "App", value: Fmt.bytes(Double(m.app)), dot: Palette.memory)
                StatRow(label: L10n.text("联动"), value: Fmt.bytes(Double(m.wired)), dot: Palette.wired)
                StatRow(label: L10n.text("已压缩"), value: Fmt.bytes(Double(m.compressed)), dot: Palette.compressed)
                StatRow(label: L10n.text("可用"), value: Fmt.bytes(Double(m.available)))
                Divider().opacity(0.5)
                pressureRow(m)
                StatRow(label: L10n.text("交换"), value: m.swapTotal > 0 ? "\(Fmt.bytes(Double(m.swapUsed))) / \(Fmt.bytes(Double(m.swapTotal)))" : L10n.text("未使用"))
                Sparkline(values: history, maxValue: 1, color: Palette.memory).frame(height: 24)
            } else {
                Unavailable(text: L10n.text("读取中…"))
            }
        }
    }

    private func pressureRow(_ m: MemoryReading) -> some View {
        let level = m.pressureLevel
        let color: Color = level == .critical ? Palette.heat : (level == .warning ? Palette.wired : Palette.memory)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L10n.text("内存压力")).foregroundStyle(.secondary)
                Spacer()
                Text(level?.label ?? L10n.text("不可用")).foregroundStyle(color).fontWeight(.medium)
                if let p = m.pressure { Text(Fmt.percent(p)).monospacedDigit() }
            }
            .font(.system(size: 11))
            if let p = m.pressure { CapsuleBar(fraction: p, color: color, height: 4) }
        }
    }
}

// MARK: - 网络

private struct NetworkCard: View {
    var network: NetworkReading?
    var down: [Double]
    var up: [Double]

    var body: some View {
        Card {
            CardHeader(symbol: "network", title: L10n.text("网络"), tint: Palette.download)
            if let n = network {
                rate(symbol: "arrow.down", color: Palette.download, value: n.downloadRate)
                rate(symbol: "arrow.up", color: Palette.upload, value: n.uploadRate)
                DualSparkline(primary: down, secondary: up, primaryColor: Palette.download, secondaryColor: Palette.upload)
                    .frame(height: 44)
                Divider().opacity(0.5)
                Text(L10n.text("本次启动")).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                StatRow(label: L10n.text("network.download", defaultValue: "下载"), value: Fmt.bytes(Double(n.sessionDownload)), dot: Palette.download)
                StatRow(label: L10n.text("network.upload", defaultValue: "上传"), value: Fmt.bytes(Double(n.sessionUpload)), dot: Palette.upload)
                Text(L10n.text("网卡累计")).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    .help(Text(L10n.text("当前网络接口的计数器之和。接口被重建（如切换 Wi-Fi、VPN）时系统会从 0 重新计数。")))
                StatRow(label: L10n.text("network.download", defaultValue: "下载"), value: Fmt.bytes(Double(n.bootDownload)), dot: Palette.download)
                StatRow(label: L10n.text("network.upload", defaultValue: "上传"), value: Fmt.bytes(Double(n.bootUpload)), dot: Palette.upload)
            } else {
                Unavailable(text: L10n.text("读取中…"))
            }
        }
    }

    private func rate(symbol: String, color: Color, value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            Text(Fmt.rate(value))
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - 磁盘

private struct DiskCard: View {
    var disk: DiskReading?
    var read: [Double]
    var write: [Double]

    var body: some View {
        Card {
            CardHeader(symbol: "internaldrive", title: L10n.text("磁盘"), tint: Palette.disk,
                       trailing: disk?.total.map { Fmt.bytes(Double($0)) })
            if let d = disk {
                if let used = d.used, let available = d.available, let fraction = d.usedFraction {
                    HStack(alignment: .firstTextBaseline) {
                        BigValue(value: Fmt.bytes(Double(available)).replacingOccurrences(of: " ", with: ""), unit: L10n.text("可用"))
                    }
                    CapsuleBar(fraction: fraction, color: fraction > 0.9 ? Palette.heat : Palette.disk, height: 5)
                    StatRow(label: L10n.text("已用"), value: "\(Fmt.bytes(Double(used))) · \(Fmt.percent(fraction))")
                } else {
                    Unavailable(text: L10n.text("容量不可用"))
                }
                Divider().opacity(0.5)
                StatRow(label: L10n.text("读取"), value: Fmt.rate(d.readRate), dot: Palette.disk)
                StatRow(label: L10n.text("写入"), value: Fmt.rate(d.writeRate), dot: Palette.upload)
                DualSparkline(primary: read, secondary: write, primaryColor: Palette.disk, secondaryColor: Palette.upload)
                    .frame(height: 30)
            } else {
                Unavailable(text: L10n.text("读取中…"))
            }
        }
    }
}

// MARK: - 风扇 / 传感器

private struct SensorsCard: View {
    var sensors: SensorReading?
    var unit: TemperatureUnit

    var body: some View {
        Card {
            CardHeader(symbol: "fanblades", title: L10n.text("风扇"), tint: Palette.fan,
                       trailing: sensors?.fanStatus == .available ? String(format: L10n.text("%lld 个"), Int64(sensors?.fans.count ?? 0)) : nil)
            switch sensors?.fanStatus {
            case .available?:
                ForEach(sensors?.fans ?? []) { fan in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(String(format: L10n.text("风扇 %lld"), Int64(fan.id + 1))).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(fan.rpm < 1 ? L10n.text("停转") : Fmt.rpm(fan.rpm))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }
                        if let f = fan.fraction {
                            CapsuleBar(fraction: f, color: Palette.fan, height: 4)
                        }
                        if let min = fan.minRPM, let max = fan.maxRPM {
                            Text(String(format: L10n.text("范围 %lld–%lld RPM"), Int64(min), Int64(max)))
                                .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
            case .noSensor?:
                Label(L10n.text("本机未配备风扇"), systemImage: "wind")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .unavailable?:
                Unavailable(text: L10n.text("不可用（无法读取 SMC）"))
            case nil:
                Unavailable(text: L10n.text("读取中…"))
            }
        }
    }
}

/// 面板顶部标签栏（替代系统分段控件：无焦点环，风格与卡片一致）。
private struct PanelTabBar: View {
    @Binding var selection: PanelView.PanelTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelView.PanelTab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    HStack(spacing: 4) {
                        Image(systemName: symbol(tab)).font(.system(size: 10, weight: .semibold))
                        Text(title(tab)).font(.system(size: 11.5, weight: selection == tab ? .semibold : .medium))
                    }
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == tab ? Palette.cardBackground : Color.clear)
                            .shadow(color: .black.opacity(selection == tab ? 0.08 : 0), radius: 1.5, y: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func title(_ tab: PanelView.PanelTab) -> String {
        switch tab {
        case .overview: return L10n.text("概览")
        case .processes: return L10n.text("进程")
        case .network: return L10n.text("网络")
        }
    }

    private func symbol(_ tab: PanelView.PanelTab) -> String {
        switch tab {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .processes: return "list.bullet"
        case .network: return "network"
        }
    }
}
