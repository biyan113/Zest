//
//  DiskSampler.swift
//  Zest
//
//  读写速度逻辑移植自 Lemon Cleaner LemonStat/CmcDisk：
//  缓存 IOBlockStorageDriver 服务对象，汇总其 Statistics 中的读写字节数。
//

import Foundation
import IOKit
import IOKit.storage

struct DiskReading: Equatable {
    var total: UInt64?
    var available: UInt64?
    var readRate: Double
    var writeRate: Double

    var used: UInt64? {
        guard let total, let available else { return nil }
        return total > available ? total - available : 0
    }
    var usedFraction: Double? {
        guard let total, let used, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
}

final class DiskSampler {
    private var drivers: [io_object_t] = []
    private var driversRefreshedAt: UInt64 = 0
    private var previous: (read: UInt64, write: UInt64)?
    private var previousTime: UInt64 = 0
    private var capacity: (total: UInt64, available: UInt64)?
    private var capacityRefreshedAt: UInt64 = 0

    /// 查询“可用空间（含可清除）”需经 CacheDelete 服务，单次约 60ms；容量变化又很慢，
    /// 因此每 2 分钟查询一次，打开面板时另行刷新（invalidateCapacity）。
    var capacityInterval: TimeInterval = 120
    private let driverRefreshInterval: TimeInterval = 30

    deinit { releaseDrivers() }

    func invalidateCapacity() { capacityRefreshedAt = 0 }

    func sample(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> DiskReading {
        if capacity == nil || Double(now &- capacityRefreshedAt) / 1e9 >= capacityInterval {
            capacity = DiskSampler.readCapacity()
            capacityRefreshedAt = now
        }
        if drivers.isEmpty || Double(now &- driversRefreshedAt) / 1e9 >= driverRefreshInterval {
            refreshDrivers()
            driversRefreshedAt = now
        }

        let current = readIOBytes()
        var readRate = 0.0, writeRate = 0.0
        if let previous, now > previousTime {
            let seconds = Double(now - previousTime) / 1e9
            readRate = Double(NetworkMath.delta(previous: previous.read, current: current.read)) / seconds
            writeRate = Double(NetworkMath.delta(previous: previous.write, current: current.write)) / seconds
        }
        previous = current
        previousTime = now
        return DiskReading(total: capacity?.total, available: capacity?.available, readRate: readRate, writeRate: writeRate)
    }

    static func readCapacity() -> (total: UInt64, available: UInt64)? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else { return nil }
        // “重要用途可用空间”包含可清除空间，与访达显示一致。
        let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
            ?? UInt64(max(values.volumeAvailableCapacity ?? 0, 0))
        return (UInt64(total), available)
    }

    private func refreshDrivers() {
        let oldCount = drivers.count
        releaseDrivers()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            drivers.append(driver)
        }
        // 设备集合变化（挂载/推出磁盘）时计数基线不可比，重新建立基线。
        if drivers.count != oldCount { previous = nil }
    }

    private func releaseDrivers() {
        drivers.forEach { IOObjectRelease($0) }
        drivers.removeAll()
    }

    private func readIOBytes() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        for driver in drivers {
            guard let stats = IORegistryEntryCreateCFProperty(driver, kIOBlockStorageDriverStatisticsKey as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            else { continue }
            read &+= (stats[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}
