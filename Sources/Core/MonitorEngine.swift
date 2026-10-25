//
//  MonitorEngine.swift
//  Zest
//
//  单一串行队列 + 单个 DispatchSourceTimer 驱动全部采样，带 10% leeway 便于系统合并唤醒。
//

import Foundation

struct Snapshot {
    var cpu: CPUReading?
    var memory: MemoryReading?
    var network: NetworkReading?
    var disk: DiskReading?
    var sensors: SensorReading?
    var selfUsage: SelfUsage?
    var thermalState: ProcessInfo.ThermalState
}

struct SampleOptions: Equatable {
    var sensors = true
}

final class MonitorEngine {
    private let queue = DispatchQueue(label: "app.zest.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    private lazy var cpu = CPUSampler()
    private lazy var memory = MemorySampler()
    private lazy var network = NetworkSampler()
    private lazy var disk = DiskSampler()
    private lazy var sensors = SMCSensors()
    private lazy var selfUsage = SelfUsageSampler()

    private(set) var interval: TimeInterval = 1
    private var options = SampleOptions()

    /// 温度与风扇变化缓慢，最多每 2 秒读取一次 SMC，其余时间复用上次读数。
    private let sensorInterval: UInt64 = 1_900_000_000
    private var lastSensors: SensorReading?
    private var lastSensorTime: UInt64 = 0

    /// 在主线程回调。
    var onSnapshot: ((Snapshot) -> Void)?

    var coreKinds: [CoreKind] { queue.sync { cpu.coreKinds } }

    func start(interval: TimeInterval) {
        self.interval = interval
        queue.async { [self] in
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            let leeway = DispatchTimeInterval.milliseconds(Int(interval * 100))
            t.schedule(deadline: .now(), repeating: interval, leeway: leeway)
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    func setOptions(_ options: SampleOptions) {
        queue.async { self.options = options }
    }

    func setChildProcesses(_ pids: [pid_t]) {
        queue.async { self.selfUsage.childPIDs = pids }
    }

    /// 面板打开时立即刷新磁盘容量。
    func refreshCapacity() {
        queue.async { self.disk.invalidateCapacity() }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { PerformanceLog.shared.timing("system_sample", since: now) }
        var sensorReading: SensorReading?
        if options.sensors {
            if lastSensors == nil || now &- lastSensorTime >= sensorInterval {
                lastSensors = sensors.sample()
                lastSensorTime = now
            }
            sensorReading = lastSensors
        } else {
            lastSensors = nil
        }
        let snapshot = Snapshot(
            cpu: cpu.sample(),
            memory: memory.sample(),
            network: network.sample(),
            disk: disk.sample(),
            sensors: sensorReading,
            selfUsage: selfUsage.sample(),
            thermalState: ProcessInfo.processInfo.thermalState)
        let queuedAt = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            PerformanceLog.shared.timing("main_queue_delay", since: queuedAt, thresholdMS: 100)
            self?.onSnapshot?(snapshot)
        }
    }
}
