//
//  SystemInfo.swift
//  Zest
//

import Foundation

struct SystemInfo {
    /// 已去掉商标符号。nil 表示读不到品牌，展示时再按当前语言取文案。
    private let chipBrand: String?
    let model: String
    let physicalMemory: UInt64
    let performanceCores: Int?
    let efficiencyCores: Int?
    let logicalCores: Int

    var chip: String { chipBrand ?? L10n.text("未知处理器") }

    static let current: SystemInfo = {
        let brand = Sysctl.string("machdep.cpu.brand_string").map {
            $0.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
                .replacingOccurrences(of: "  ", with: " ")
        }
        let levels = Sysctl.int32("hw.nperflevels") ?? 1
        return SystemInfo(
            chipBrand: brand,
            model: Sysctl.string("hw.model") ?? "Mac",
            physicalMemory: Sysctl.uint64("hw.memsize") ?? 0,
            performanceCores: levels > 1 ? Sysctl.int32("hw.perflevel0.logicalcpu") : nil,
            efficiencyCores: levels > 1 ? Sysctl.int32("hw.perflevel1.logicalcpu") : nil,
            logicalCores: Sysctl.int32("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount)
    }()

    static var uptime: TimeInterval {
        guard let boot = Sysctl.value("kern.boottime", as: timeval.self) else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return L10n.text("正常")
        case .fair: return L10n.text("略高")
        case .serious: return L10n.text("偏高")
        case .critical: return L10n.text("过热")
        @unknown default: return L10n.text("未知")
        }
    }
}

/// 监控程序自身的资源占用，用于在面板中自证轻量。
struct SelfUsage: Equatable {
    var cpu: Double        // 单核百分比，0...1
    var memory: UInt64     // phys_footprint
    var processCPU: Double? = nil
    var childCPU: Double? = nil
}

final class SelfUsageSampler {
    private var previousCPU: Double?
    private var previousOwnCPU: Double?
    private var previousChildCPU: Double?
    private var previousTime: UInt64 = 0
    /// 由采样队列维护。长寿命子进程必须在运行中计入，避免 wait/reap 时一次记入全部历史 CPU。
    var childPIDs: [pid_t] = []
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func sample(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> SelfUsage {
        // 同时计入已结束的子进程（定时运行的 nettop、arp），如实反映总开销。
        func seconds(_ who: Int32) -> Double {
            var u = rusage()
            getrusage(who, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        let ownSeconds = seconds(RUSAGE_SELF)
        var childSeconds = 0.0
        // 若读取期间发生 reap，重读一次，避免同时包含 live 和 reaped 两份时间。
        for _ in 0..<3 {
            let before = seconds(RUSAGE_CHILDREN)
            var live = 0.0
            for pid in childPIDs {
                var info = rusage_info_v4()
                let ok = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                    }
                }
                guard ok, info.ri_proc_exit_abstime == 0 else { continue }
                let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
                    + Double(info.ri_child_user_time) + Double(info.ri_child_system_time)
                live += ticks * Double(timebase.numer) / Double(max(timebase.denom, 1)) / 1e9
            }
            let after = seconds(RUSAGE_CHILDREN)
            childSeconds = before == after ? after + live : after
            if before == after { break }
        }
        // 退出到 reap 之间的短暂空档不允许累计值倒退，否则下一拍会再次计入历史量。
        childSeconds = max(childSeconds, previousChildCPU ?? 0)
        previousChildCPU = childSeconds
        let cpuSeconds = ownSeconds + childSeconds
        var fraction = 0.0
        var ownFraction = 0.0
        if let previousCPU, now > previousTime {
            let elapsed = Double(now - previousTime) / 1e9
            fraction = (cpuSeconds - previousCPU) / elapsed
            ownFraction = max(0, ownSeconds - (previousOwnCPU ?? ownSeconds)) / elapsed
        }
        previousCPU = cpuSeconds
        previousOwnCPU = ownSeconds
        previousTime = now

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return SelfUsage(cpu: max(fraction, 0), memory: kr == KERN_SUCCESS ? info.phys_footprint : 0,
                         processCPU: ownFraction, childCPU: max(0, fraction - ownFraction))
    }
}

enum MemoryRelief {
    /// 界面关闭后把分配器中已释放的空闲页归还给系统（公开接口 malloc_zone_pressure_relief）。
    /// SwiftUI、图表等释放后，分配器默认会保留这些页，导致常驻内存长时间偏高。
    static func releaseFreePages(after delay: TimeInterval = 1.5) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
