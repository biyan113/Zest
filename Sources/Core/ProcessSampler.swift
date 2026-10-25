//
//  ProcessSampler.swift
//  Zest
//
//  各应用的 CPU 与内存占用（对应 Lemon Monitor 的进程占用排行）。
//  CPU：两次采样间 proc_pid_rusage 的用户态+内核态时间差；内存：phys_footprint（与“活动监视器”的“内存”列一致）。
//  普通权限下只能读取当前用户的进程。
//

import Foundation

struct ProcessUsage: Identifiable, Equatable {
    var pid: pid_t
    var name: String
    var cpu: Double        // 单核占比，多线程进程可超过 1（与活动监视器一致）
    var memory: UInt64

    var id: pid_t { pid }
}

struct AppUsage: Identifiable, Equatable {
    var key: String
    var bundlePath: String?
    var name: String
    var kind: ProcessKind
    var processes: [ProcessUsage]
    /// 系统关键进程或 Zest 自身：不提供结束操作。
    var isProtected: Bool

    var id: String { key }
    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
}

struct ProcessesReading: Equatable {
    var apps: [AppUsage]
    var inaccessibleProcesses: Int
    /// 首次采样没有时间差，CPU 尚不可用。
    var hasCPU: Bool

    func top(by metric: ProcessMetric, limit: Int) -> [AppUsage] {
        Array(sorted(by: metric).prefix(limit))
    }

    func sorted(by metric: ProcessMetric, kinds: Set<ProcessKind> = Set(ProcessKind.allCases)) -> [AppUsage] {
        let list = apps.filter { kinds.contains($0.kind) }
        switch metric {
        case .cpu: return list.sorted { ($0.cpu, $0.memory, $1.name) > ($1.cpu, $1.memory, $0.name) }
        case .memory: return list.sorted { ($0.memory, $1.name) > ($1.memory, $0.name) }
        }
    }

    func count(of kind: ProcessKind) -> Int { apps.filter { $0.kind == kind }.count }
}

enum ProcessMetric: String, CaseIterable, Identifiable {
    case cpu, memory
    var id: String { rawValue }
    var title: String { self == .cpu ? "CPU" : L10n.text("内存") }
}

enum ProcessMath {
    /// 两次累计 CPU 时间（纳秒）之差除以墙钟时间差。进程重启（计数变小）时返回 0。
    static func cpuFraction(previous: UInt64?, current: UInt64, elapsedNanos: UInt64) -> Double {
        guard let previous, current >= previous, elapsedNanos > 0 else { return 0 }
        return Double(current - previous) / Double(elapsedNanos)
    }

    /// 结束这些进程会导致注销、桌面消失等后果，界面上不提供结束按钮。
    static let protectedNames: Set<String> = [
        "loginwindow", "WindowServer", "Dock", "SystemUIServer", "ControlCenter", "launchd", "kernel_task",
        "UserEventAgent", "NotificationCenter", "WindowManager", "coreaudiod",
    ]
}

final class ProcessSampler {
    private var pidBuffer = [pid_t](repeating: 0, count: 4096)
    private let owners = ProcessOwnerResolver()
    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousTime: UInt64?
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private let ownPID = getpid()

    func sample(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> ProcessesReading {
        var grouped: [String: AppUsage] = [:]
        var currentCPU: [pid_t: UInt64] = [:]
        var alive = Set<pid_t>()
        var inaccessible = 0
        let elapsed = previousTime.map { now > $0 ? now - $0 : 0 } ?? 0

        for pid in ProcessOwners.allPIDs(buffer: &pidBuffer) {
            alive.insert(pid)
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0
                }
            }
            guard ok else { inaccessible += 1; continue }
            // ri_user_time/ri_system_time 以 mach 时基计数（Apple Silicon 上 1 tick ≠ 1ns）。
            let ticks = info.ri_user_time &+ info.ri_system_time
            let cpuNanos = ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
            currentCPU[pid] = cpuNanos

            let owner = owners.owner(of: pid)
            let usage = ProcessUsage(
                pid: pid, name: ProcessOwners.name(pid),
                cpu: ProcessMath.cpuFraction(previous: previousCPU[pid], current: cpuNanos, elapsedNanos: elapsed),
                memory: info.ri_phys_footprint)
            let protected = pid == ownPID || ProcessMath.protectedNames.contains(usage.name)
            grouped[owner.key, default: AppUsage(key: owner.key, bundlePath: owner.bundlePath, name: owner.name,
                                                 kind: owner.kind, processes: [], isProtected: false)].processes.append(usage)
            if protected { grouped[owner.key]?.isProtected = true }
        }

        owners.prune(alive: alive)
        let hasCPU = previousTime != nil
        previousCPU = currentCPU
        previousTime = now
        var apps = Array(grouped.values)
        for i in apps.indices { apps[i].processes.sort { ($0.cpu, $0.memory) > ($1.cpu, $1.memory) } }
        return ProcessesReading(apps: apps, inaccessibleProcesses: inaccessible, hasCPU: hasCPU)
    }
}
