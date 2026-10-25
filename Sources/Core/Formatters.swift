//
//  Formatters.swift
//  Zest
//

import Foundation

enum Fmt {
    private static let units = ["B", "K", "M", "G", "T", "P"]

    /// 紧凑字节数：0B、512B、12K、1.2M、234G。适合菜单栏。
    static func compactBytes(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes > 0 else { return "0B" }
        var value = bytes
        var idx = 0
        while value >= 1000, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return "\(Int(value))B" }
        return value < 10 ? String(format: "%.1f%@", value, units[idx]) : String(format: "%.0f%@", value, units[idx])
    }

    /// 完整字节数：1.23 GB。适合面板。
    static func bytes(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes > 0 else { return "0 B" }
        var value = bytes
        var idx = 0
        while value >= 1000, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return "\(Int(value)) B" }
        let fmt = value < 10 ? "%.2f %@B" : (value < 100 ? "%.1f %@B" : "%.0f %@B")
        return String(format: fmt, value, units[idx])
    }

    static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }
    static func compactRate(_ bytesPerSecond: Double) -> String { compactBytes(bytesPerSecond) + "/s" }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "--" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func temperature(_ celsius: Double, unit: TemperatureUnit, decimals: Bool = false) -> String {
        let v = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        return decimals ? String(format: "%.1f°", v) : "\(Int(v.rounded()))°"
    }

    static func rpm(_ value: Double) -> String { "\(Int(value.rounded())) RPM" }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let days = s / 86_400, hours = (s % 86_400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return String(format: L10n.text("%lld天 %lld小时"), Int64(days), Int64(hours)) }
        if hours > 0 { return String(format: L10n.text("%lld小时 %lld分"), Int64(hours), Int64(minutes)) }
        return String(format: L10n.text("%lld分钟"), Int64(minutes))
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var label: String { self == .celsius ? L10n.text("摄氏度 (°C)") : L10n.text("华氏度 (°F)") }
}
