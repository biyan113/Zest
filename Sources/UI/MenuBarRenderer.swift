//
//  MenuBarRenderer.swift
//  Zest
//
//  按参考菜单栏的 2× 像素尺寸绘制：11pt 常规数值、7pt 标签、37pt 指标中心间距。
//  网速为上下两行箭头 + 数值，单位字号缩小。整体绘制为模板图，自动适配浅色/深色菜单栏。
//  每项宽度按最坏情况预先固定，数值变化时菜单栏不会左右抖动。
//

import AppKit

enum MenuBarSegment: Equatable {
    /// 数值 + 下方小标签，如 “58%” / “CPU”。
    case metric(item: MenuBarItem, value: String, label: String)
    /// 网速：上传、下载两行，各自拆成数字与单位以便单位用小字号。
    case rates(up: SpeedText, down: SpeedText)

    var item: MenuBarItem {
        switch self {
        case .metric(let item, _, _): return item
        case .rates: return .network
        }
    }

    var accessibilityText: String {
        switch self {
        case .metric(let item, let value, _):
            return String(format: L10n.text("%@：%@"), item.title, value)
        case .rates(let up, let down):
            return String(format: L10n.text("上传 %@%@，下载 %@%@"), up.number, up.unit, down.number, down.unit)
        }
    }
}

struct SpeedText: Equatable {
    var number: String
    var unit: String
}

enum MenuBarContent {
    static func segments(for items: [MenuBarItem], snapshot: Snapshot?, unit: TemperatureUnit) -> [MenuBarSegment] {
        items.map { item in
            switch item {
            case .cpu:
                return .metric(item: item, value: snapshot?.cpu.map { Fmt.percent($0.usage) } ?? "--", label: "CPU")
            case .memory:
                return .metric(item: item, value: snapshot?.memory.map { Fmt.percent($0.usedFraction) } ?? "--", label: "MEM")
            case .disk:
                return .metric(item: item, value: snapshot?.disk?.usedFraction.map { Fmt.percent($0) } ?? "--", label: "SSD")
            case .temperature:
                let t = snapshot?.sensors?.cpuTemperature
                return .metric(item: item, value: t.map { Fmt.temperature($0, unit: unit) } ?? "N/A", label: "TEMP")
            case .fan:
                let fans = snapshot?.sensors?.fans ?? []
                let rpm = fans.map(\.rpm).max()
                return .metric(item: item, value: rpm.map { "\(Int($0.rounded()))" } ?? "N/A", label: "RPM")
            case .network:
                let n = snapshot?.network
                return .rates(up: n.map { speed($0.uploadRate) } ?? SpeedText(number: "--", unit: " K/s"),
                              down: n.map { speed($0.downloadRate) } ?? SpeedText(number: "--", unit: " K/s"))
            }
        }
    }

    /// 与 Lemon 一致：以 KB 为基准，超过 1000K 换算为 M；不足 100 保留一位小数。
    static func speed(_ bytesPerSecond: Double) -> SpeedText {
        var value = max(bytesPerSecond, 0) / 1024
        var unit = " K/s"
        if value > 1000 {
            value /= 1024
            unit = " M/s"
        }
        let number = value > 100 ? "\(Int(value))" : String(format: "%.1f", value)
        return SpeedText(number: number, unit: unit)
    }
}

final class MenuBarRenderer {
    private let valueFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private let labelFont = NSFont.systemFont(ofSize: 7, weight: .regular)
    private let speedFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let speedUnitFont = NSFont.systemFont(ofSize: 8, weight: .regular)

    private let dividerGap: CGFloat = 3
    private let dividerHeight: CGFloat = 16
    private let edgePadding: CGFloat = 2

    private var widthCache: [MenuBarItem: CGFloat] = [:]

    func render(_ segments: [MenuBarSegment], height: CGFloat, scale: CGFloat = 2) -> NSImage? {
        guard !segments.isEmpty, height > 0, scale > 0 else { return nil }
        let widths = segments.map { width(for: $0.item) }
        let total = widths.reduce(0, +) + CGFloat(segments.count - 1) * (dividerGap * 2 + 1) + edgePadding * 2
        let size = NSSize(width: ceil(total), height: height)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(ceil(size.width * scale)),
                                            pixelsHigh: Int(ceil(size.height * scale)),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        // 一次排版成当前屏幕分辨率的位图。绘制闭包图片会被 AppKit 的模板、
        // 高亮和阴影等多个通道重复执行，导致每次更新反复排版相同文字。
        NSGraphicsContext.saveGraphicsState()
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        var x = edgePadding
        for (i, (segment, w)) in zip(segments, widths).enumerated() {
            if i > 0 {
                x += dividerGap
                NSColor.black.setFill()
                NSRect(x: x, y: (height - dividerHeight) / 2 - 1, width: 1, height: dividerHeight).fill()
                x += 1 + dividerGap
            }
            draw(segment, in: NSRect(x: x, y: 0, width: w, height: height))
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    // MARK: 布局

    /// 每类数值的最宽样例，用于固定宽度。
    private func width(for item: MenuBarItem) -> CGFloat {
        if let cached = widthCache[item] { return cached }
        let w: CGFloat
        switch item {
        case .network:
            w = max(40, arrowWidth + 2 + textWidth("999", speedFont) + textWidth(" M/s", speedUnitFont))
        case .fan:
            w = max(textWidth("8888", valueFont), textWidth("RPM", labelFont))
        case .temperature:
            w = max(textWidth("188°", valueFont), textWidth("TEMP", labelFont))
        case .cpu, .memory, .disk:
            w = max(30, textWidth("100%", valueFont))
        }
        widthCache[item] = ceil(w)
        return ceil(w)
    }

    private var arrowWidth: CGFloat { 5 }

    // MARK: 绘制（flipped 坐标，y 向下）

    private func draw(_ segment: MenuBarSegment, in rect: NSRect) {
        // 以固定的 22pt 画布居中；文字行距不受字体 ascender / descender 的取整影响。
        let top = (rect.height - 22) / 2
        switch segment {
        case .metric(_, let value, let label):
            draw(value, font: valueFont, in: NSRect(x: rect.minX, y: top, width: rect.width, height: 14), align: .center)
            draw(label, font: labelFont,
                 in: NSRect(x: rect.minX, y: top + 12, width: rect.width, height: 9), align: .center)
        case .rates(let up, let down):
            drawRate(up, upward: true, x: rect.minX, y: top - 0.5)
            drawRate(down, upward: false, x: rect.minX, y: top + 9)
        }
    }

    private func drawRate(_ text: SpeedText, upward: Bool, x: CGFloat, y: CGFloat) {
        // 参考箭头是独立的 5×6pt 图形，不跟随字体 capHeight 拉长。
        drawArrow(upward: upward, in: NSRect(x: x, y: y + 3.5, width: arrowWidth, height: 4))
        let s = NSMutableAttributedString(string: text.number, attributes: [.font: speedFont, .foregroundColor: NSColor.white])
        s.append(NSAttributedString(string: text.unit, attributes: [.font: speedUnitFont, .foregroundColor: NSColor.white]))
        s.draw(at: NSPoint(x: x + arrowWidth + 2, y: y))
    }

    /// 细线箭头（对应 Lemon 的 lemon_status_net_upload/download 图标）。
    private func drawArrow(upward: Bool, in r: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let midX = r.midX
        let (tip, tail) = upward ? (r.minY, r.maxY) : (r.maxY, r.minY)
        let head: CGFloat = upward ? 2 : -2
        path.move(to: NSPoint(x: midX, y: tail))
        path.line(to: NSPoint(x: midX, y: tip))
        path.move(to: NSPoint(x: midX - 2, y: tip + head))
        path.line(to: NSPoint(x: midX, y: tip))
        path.line(to: NSPoint(x: midX + 2, y: tip + head))
        NSColor.black.setStroke()
        path.stroke()
    }

    private func draw(_ s: String, font: NSFont, in rect: NSRect, align: NSTextAlignment) {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byClipping
        // 模板只使用 alpha；以白字栅格化，保留参考图的浅色笔画抗锯齿。
        // 补偿参考图中文字相对分隔线的 1/4 像素光学偏移（2×）。
        (s as NSString).draw(in: rect.offsetBy(dx: 0.125, dy: 0), withAttributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: p])
    }

    private func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }
}
