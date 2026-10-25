//
//  MemorySampler.swift
//  Zest
//
//  逻辑参考 Lemon Cleaner LemonStat/CmcMemory（host_statistics64 + vm_statistics64）。
//

import Foundation

enum MemoryPressureLevel: Int {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return L10n.text("正常")
        case .warning: return L10n.text("memory.pressure.warning", defaultValue: "警告")
        case .critical: return L10n.text("严重")
        }
    }
}

struct MemoryReading: Equatable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64          // 文件缓存（可回收）
    var free: UInt64
    var pressureLevel: MemoryPressureLevel?
    /// 内存压力百分比（100 - kern.memorystatus_level）。系统未提供时为 nil。
    var pressure: Double?
    var swapUsed: UInt64
    var swapTotal: UInt64

    /// 与“活动监视器”一致：App 内存 + 联动内存 + 被压缩内存。
    var used: UInt64 { app + wired + compressed }
    var available: UInt64 { total > used ? total - used : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MemoryMath {
    static func reading(stats s: vm_statistics64, pageSize: UInt64, total: UInt64) -> MemoryReading {
        let internalPages = UInt64(s.internal_page_count)
        let purgeable = UInt64(s.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
        let wired = UInt64(s.wire_count) * pageSize
        let compressed = UInt64(s.compressor_page_count) * pageSize
        let cached = (UInt64(s.external_page_count) + purgeable) * pageSize
        let free = UInt64(s.free_count) * pageSize
        return MemoryReading(total: total, app: app, wired: wired, compressed: compressed, cached: cached,
                             free: free, pressureLevel: nil, pressure: nil, swapUsed: 0, swapTotal: 0)
    }
}

final class MemorySampler {
    private let total = Sysctl.uint64("hw.memsize") ?? 0
    private let pageSize = UInt64(vm_kernel_page_size)

    func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var reading = MemoryMath.reading(stats: stats, pageSize: pageSize, total: total)

        if let level = Sysctl.int32("kern.memorystatus_vm_pressure_level") {
            reading.pressureLevel = MemoryPressureLevel(rawValue: level)
        }
        if let freePercent = Sysctl.int32("kern.memorystatus_level"), (0...100).contains(freePercent) {
            reading.pressure = Double(100 - freePercent) / 100
        }
        if let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self) {
            reading.swapUsed = swap.xsu_used
            reading.swapTotal = swap.xsu_total
        }
        return reading
    }
}
