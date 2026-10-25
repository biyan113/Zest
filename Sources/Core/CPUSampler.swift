//
//  CPUSampler.swift
//  Zest
//
//  逻辑移植自 Lemon Cleaner LemonStat/CmcProcessor（host_processor_info 计算各核心 tick 差值）。
//

import Foundation
import IOKit

struct CPUTicks: Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var total: UInt64 { user &+ system &+ idle &+ nice }
}

struct CoreLoad: Equatable {
    var usage: Double   // 0...1
    var user: Double
    var system: Double
}

enum CoreKind: Equatable { case performance, efficiency, unknown }

struct CPUReading: Equatable {
    var usage: Double
    var user: Double
    var system: Double
    var cores: [CoreLoad]
    var loadAverage: (Double, Double, Double)

    static func == (a: CPUReading, b: CPUReading) -> Bool {
        a.usage == b.usage && a.cores == b.cores
    }
}

enum CPUMath {
    /// 两次采样间的负载。tick 计数器回绕或核心数变化时返回 nil。
    static func load(previous: CPUTicks, current: CPUTicks) -> CoreLoad? {
        guard current.total >= previous.total,
              current.user >= previous.user, current.system >= previous.system,
              current.idle >= previous.idle, current.nice >= previous.nice else { return nil }
        let total = Double(current.total - previous.total)
        guard total > 0 else { return CoreLoad(usage: 0, user: 0, system: 0) }
        let user = Double((current.user - previous.user) + (current.nice - previous.nice)) / total
        let system = Double(current.system - previous.system) / total
        return CoreLoad(usage: min(user + system, 1), user: user, system: system)
    }

    static func aggregate(previous: [CPUTicks], current: [CPUTicks]) -> (CoreLoad, [CoreLoad])? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var cores: [CoreLoad] = []
        cores.reserveCapacity(current.count)
        for (p, c) in zip(previous, current) {
            guard let l = load(previous: p, current: c) else { return nil }
            cores.append(l)
        }
        let sumPrev = previous.reduce(CPUTicks(user: 0, system: 0, idle: 0, nice: 0)) {
            CPUTicks(user: $0.user + $1.user, system: $0.system + $1.system, idle: $0.idle + $1.idle, nice: $0.nice + $1.nice)
        }
        let sumCur = current.reduce(CPUTicks(user: 0, system: 0, idle: 0, nice: 0)) {
            CPUTicks(user: $0.user + $1.user, system: $0.system + $1.system, idle: $0.idle + $1.idle, nice: $0.nice + $1.nice)
        }
        guard let total = load(previous: sumPrev, current: sumCur) else { return nil }
        return (total, cores)
    }
}

final class CPUSampler {
    private var previous: [CPUTicks] = []

    /// 每个逻辑核心的类型（Apple Silicon 读取 IODeviceTree 的 cluster-type；读不到则为 unknown）。
    let coreKinds: [CoreKind]

    init() {
        coreKinds = CPUSampler.readCoreKinds()
        previous = CPUSampler.readTicks() ?? []
    }

    func sample() -> CPUReading? {
        guard let current = CPUSampler.readTicks() else { return nil }
        defer { previous = current }
        guard let (total, cores) = CPUMath.aggregate(previous: previous, current: current) else { return nil }
        var avg = [Double](repeating: 0, count: 3)
        _ = getloadavg(&avg, 3)
        return CPUReading(usage: total.usage, user: total.user, system: total.system,
                          cores: cores, loadAverage: (avg[0], avg[1], avg[2]))
    }

    static func readTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var result: [CPUTicks] = []
        result.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            result.append(CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                                   idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)))
        }
        return result
    }

    private static func readCoreKinds() -> [CoreKind] {
        let count = Sysctl.int32("hw.logicalcpu") ?? 0
        var kinds = [CoreKind](repeating: .unknown, count: count)
        #if arch(arm64)
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return kinds }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return kinds }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let idValue = IORegistryEntryCreateCFProperty(entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(),
                  let typeData = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data,
                  let first = typeData.first else { continue }
            // 不同系统版本中 logical-cpu-id 可能是 CFNumber 或 4 字节 Data。
            let id: Int
            if let number = idValue as? NSNumber {
                id = number.intValue
            } else if let data = idValue as? Data, data.count >= 4 {
                id = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            } else {
                continue
            }
            guard id < kinds.count else { continue }
            // M 是较新 Apple Silicon 的中端性能核，设备树 p-core-count 把它和 P 算在一起。
            switch UnicodeScalar(first) {
            case "P", "M": kinds[id] = .performance
            case "E": kinds[id] = .efficiency
            default: break
            }
        }
        #endif
        return kinds
    }
}
