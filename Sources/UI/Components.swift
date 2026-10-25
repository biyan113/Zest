//
//  Components.swift
//  Zest
//

import AppKit
import SwiftUI

enum Palette {
    static let cpu = Color(red: 0.30, green: 0.56, blue: 1.00)
    static let cpuSystem = Color(red: 0.98, green: 0.42, blue: 0.40)
    static let memory = Color(red: 0.36, green: 0.80, blue: 0.52)
    static let wired = Color(red: 0.98, green: 0.70, blue: 0.27)
    static let compressed = Color(red: 0.72, green: 0.52, blue: 0.98)
    static let download = Color(red: 0.20, green: 0.74, blue: 0.86)
    static let upload = Color(red: 1.00, green: 0.55, blue: 0.30)
    static let disk = Color(red: 0.55, green: 0.50, blue: 1.00)
    static let fan = Color(red: 0.45, green: 0.72, blue: 0.95)
    static let heat = Color(red: 1.00, green: 0.45, blue: 0.35)

    /// 面板使用不透明背景，避免后方窗口与壁纸透出造成“遮挡感”。
    static let panelBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.9)
    })

    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return cpu
        case ..<0.85: return Color(red: 1.0, green: 0.68, blue: 0.20)
        default: return Color(red: 1.0, green: 0.36, blue: 0.33)
        }
    }

    static func temperature(_ c: Double) -> Color {
        switch c {
        case ..<60: return memory
        case ..<80: return Color(red: 1.0, green: 0.68, blue: 0.20)
        default: return heat
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct CardHeader: View {
    var symbol: String
    var title: String
    var tint: Color
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct BigValue: View {
    var value: String
    var unit: String? = nil
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            if let unit {
                Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var dot: Color? = nil
    var valueStyle: HierarchicalShapeStyle = .primary

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(valueStyle).monospacedDigit()
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

struct Unavailable: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}

/// 迷你趋势图：一条折线加渐变填充。
struct Sparkline: View {
    var values: [Double]
    var maxValue: Double?
    var color: Color
    var filled = true
    var capacity: Int = MonitorStore.historyLength

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? (values.max() ?? 0), 0.000_001)
            let points = Sparkline.points(Array(values.suffix(capacity)), top: top, size: geo.size, capacity: capacity)
            ZStack {
                if filled, points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                }
                if points.count > 1 {
                    Path { p in p.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .drawingGroup()
    }

    /// 右对齐：最新数据在最右侧，历史不足时左侧留空。
    static func points(_ values: [Double], top: Double, size: CGSize, capacity: Int) -> [CGPoint] {
        guard capacity > 1 else { return [] }
        let step = size.width / CGFloat(capacity - 1)
        let offset = capacity - values.count
        return values.enumerated().map { i, v in
            let y = size.height - CGFloat(min(max(v / top, 0), 1)) * (size.height - 1.5) - 0.75
            return CGPoint(x: CGFloat(i + offset) * step, y: y)
        }
    }
}

/// 上下行双曲线，共享同一纵轴。
struct DualSparkline: View {
    var primary: [Double]
    var secondary: [Double]
    var primaryColor: Color
    var secondaryColor: Color
    var capacity: Int = MonitorStore.historyLength

    var body: some View {
        let top = max(primary.max() ?? 0, secondary.max() ?? 0, 1024)
        ZStack {
            Sparkline(values: primary, maxValue: top, color: primaryColor, capacity: capacity)
            Sparkline(values: secondary, maxValue: top, color: secondaryColor, filled: false, capacity: capacity)
        }
    }
}

struct CapsuleBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(geo.size.width * CGFloat(min(max(fraction, 0), 1)), height))
            }
        }
        .frame(height: height)
    }
}

struct SegmentedBar: View {
    struct Segment: Identifiable {
        var id: String
        var fraction: Double
        var color: Color
    }

    var segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { s in
                    Rectangle().fill(s.color).frame(width: max(geo.size.width * CGFloat(min(max(s.fraction, 0), 1)) - 1, 0))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// 各核心负载柱状图。Apple Silicon 上性能核与能效核用不同深浅区分。
struct CoreBars: View {
    var cores: [CoreLoad]
    var kinds: [CoreKind]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, core in
                let kind = index < kinds.count ? kinds[index] : .unknown
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(kind == .efficiency ? Palette.cpu.opacity(0.55) : Palette.load(core.usage))
                            .frame(height: max(geo.size.height * CGFloat(core.usage), 1.5))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Color.primary.opacity(0.07)))
                .help(coreHelp(index: index, kind: kind, percent: Fmt.percent(core.usage)))
            }
        }
    }

    private func coreHelp(index: Int, kind: CoreKind, percent: String) -> String {
        switch kind {
        case .efficiency:
            return String(format: L10n.text("核心 %lld（能效）：%@"), Int64(index + 1), percent)
        case .performance:
            return String(format: L10n.text("核心 %lld（性能）：%@"), Int64(index + 1), percent)
        case .unknown:
            return String(format: L10n.text("核心 %lld：%@"), Int64(index + 1), percent)
        }
    }
}

struct AppIcon: View {
    var bundlePath: String?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let bundlePath {
                Image(nsImage: AppIcon.icon(for: bundlePath)).resizable()
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
        }
        .frame(width: size, height: size)
    }

    private static var cache: [String: NSImage] = [:]

    /// 系统图标包含最高 1024px 的多套尺寸；只缓存缩小到 64px 的位图，避免常驻大量图像数据。
    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let source = NSWorkspace.shared.icon(forFile: path)
        let side = 64
        let image: NSImage
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            image = NSImage(size: NSSize(width: 32, height: 32))
            image.addRepresentation(rep)
        } else {
            image = source
        }
        if cache.count > 300 { cache.removeAll() }
        cache[path] = image
        return image
    }
}
