//
//  SMCSensors.swift
//  Zest
//
//  温度与风扇。通过只读 AppleSMC 用户客户端获取，无需 root、无需后台守护进程。
//  读不到的传感器一律返回 nil，界面显示“不可用”，绝不填充估算值。
//

import Foundation

enum SensorAvailability: Equatable {
    case available
    case noSensor          // 硬件上不存在（例如无风扇机型）
    case unavailable       // 无法读取（SMC 打开失败等）
}

struct FanReading: Equatable, Identifiable {
    var id: Int
    var rpm: Double
    var minRPM: Double?
    var maxRPM: Double?

    var fraction: Double? {
        guard let minRPM, let maxRPM, maxRPM > minRPM else { return nil }
        return min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}

struct SensorReading: Equatable {
    var cpuTemperature: Double?      // 有效 CPU 传感器的平均值
    var cpuTemperatureMax: Double?
    var gpuTemperature: Double?
    var temperatureStatus: SensorAvailability
    var fans: [FanReading]
    var fanStatus: SensorAvailability
}

enum FourCC {
    static func code(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)],
               encoding: .ascii) ?? "????"
    }
}

enum SMCDecoder {
    /// 将 SMC 原始字节解码为数值。未知类型返回 nil。
    static func decode(type: UInt32, size: UInt32, bytes: [UInt8]) -> Double? {
        switch FourCC.string(type) {
        case "flt " where size == 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78" where size == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where size == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 " where size == 1:
            return Double(bytes[0])
        case "ui16" where size == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where size == 4:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    /// 根据 key 名判断是否是 CPU / GPU 温度传感器。
    static func classify(key: String, isAppleSilicon: Bool) -> SensorGroup? {
        guard key.count == 4, key.hasPrefix("T") else { return nil }
        if isAppleSilicon {
            if key.hasPrefix("Tp") || key.hasPrefix("Te") { return .cpu }
            if key.hasPrefix("Tg") { return .gpu }
            return nil
        }
        // Intel：TC0P/TC0D/TC0E/TC0F 封装/核心，TC1C… 各核心；TG0P/TG0D GPU。
        if key.hasPrefix("TC") { return .cpu }
        if key.hasPrefix("TG") { return .gpu }
        return nil
    }

    static func isPlausibleTemperature(_ v: Double) -> Bool { v > 5 && v < 125 }
}

enum SensorGroup { case cpu, gpu }

final class SMCSensors {
    private struct Key {
        let code: UInt32
        let info: ZSMCKeyInfo
    }

    private var cpuKeys: [Key] = []
    private var gpuKeys: [Key] = []
    private var fanCount = 0
    private var fanKeys: [(current: Key, min: Double?, max: Double?)] = []
    private var opened = false
    private var discovered = false

    #if arch(arm64)
    private let isAppleSilicon = true
    #else
    private let isAppleSilicon = false
    #endif

    /// 每次 SMC 读取需等待协处理器（Apple Silicon 上约 0.2ms），只读取均匀分布的一部分传感器。
    static let maxCPUKeys = 12
    static let maxGPUKeys = 4

    deinit { zsmc_close() }

    /// 从列表中等间隔挑选至多 limit 个元素，覆盖不同核心簇。
    static func spread<T>(_ items: [T], limit: Int) -> [T] {
        guard items.count > limit, limit > 0 else { return items }
        let step = Double(items.count) / Double(limit)
        return (0..<limit).map { items[Int(Double($0) * step)] }
    }

    func sample() -> SensorReading {
        if !opened {
            opened = zsmc_open() == 0
        }
        guard opened else {
            return SensorReading(cpuTemperature: nil, cpuTemperatureMax: nil, gpuTemperature: nil,
                                 temperatureStatus: .unavailable, fans: [], fanStatus: .unavailable)
        }
        if !discovered {
            discover()
            discovered = true
        }

        let cpu = cpuKeys.compactMap(read).filter(SMCDecoder.isPlausibleTemperature)
        let gpu = gpuKeys.compactMap(read).filter(SMCDecoder.isPlausibleTemperature)
        let fans: [FanReading] = fanKeys.enumerated().compactMap { index, keys in
            guard let rpm = read(keys.current), rpm >= 0 else { return nil }
            return FanReading(id: index, rpm: rpm, minRPM: keys.min, maxRPM: keys.max)
        }

        let tempStatus: SensorAvailability = cpuKeys.isEmpty ? .noSensor : (cpu.isEmpty ? .unavailable : .available)
        let fanStatus: SensorAvailability
        if fanCount == 0 {
            fanStatus = .noSensor
        } else {
            fanStatus = fans.isEmpty ? .unavailable : .available
        }
        return SensorReading(
            cpuTemperature: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
            cpuTemperatureMax: cpu.max(),
            gpuTemperature: gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count),
            temperatureStatus: tempStatus, fans: fans, fanStatus: fanStatus)
    }

    private func read(_ key: Key) -> Double? {
        var info = key.info
        var bytes = [UInt8](repeating: 0, count: 32)
        guard zsmc_read(key.code, &info, &bytes) else { return nil }
        return SMCDecoder.decode(type: info.dataType, size: info.dataSize, bytes: bytes)
    }

    private func keyIfPresent(_ name: String) -> Key? {
        let code = FourCC.code(name)
        var info = ZSMCKeyInfo()
        guard zsmc_key_info(code, &info) else { return nil }
        return Key(code: code, info: info)
    }

    /// 一次性枚举 SMC key（约 2000 个，耗时 ~15ms），之后每次采样只读取筛选出的少量 key。
    private func discover() {
        let total = zsmc_key_count()
        var cpu: [Key] = [], gpu: [Key] = []
        for index in 0..<total {
            var code: UInt32 = 0
            guard zsmc_key_at_index(index, &code) else { continue }
            let name = FourCC.string(code)
            guard let group = SMCDecoder.classify(key: name, isAppleSilicon: isAppleSilicon) else { continue }
            var info = ZSMCKeyInfo()
            guard zsmc_key_info(code, &info) else { continue }
            let type = FourCC.string(info.dataType)
            guard type == "flt " || type == "sp78" else { continue }
            let key = Key(code: code, info: info)
            // 只保留当前读数合理的传感器（部分 key 恒为 0 或为占位）。
            guard let v = read(key), SMCDecoder.isPlausibleTemperature(v) else { continue }
            switch group {
            case .cpu: cpu.append(key)
            case .gpu: gpu.append(key)
            }
        }
        // Apple Silicon 上若没有 Tp/Te 传感器，退回 TC* 系列。
        if cpu.isEmpty && isAppleSilicon {
            for index in 0..<total {
                var code: UInt32 = 0
                guard zsmc_key_at_index(index, &code), FourCC.string(code).hasPrefix("TC") else { continue }
                var info = ZSMCKeyInfo()
                guard zsmc_key_info(code, &info), FourCC.string(info.dataType) == "flt " else { continue }
                let key = Key(code: code, info: info)
                if let v = read(key), SMCDecoder.isPlausibleTemperature(v) { cpu.append(key) }
            }
        }
        cpuKeys = SMCSensors.spread(cpu, limit: SMCSensors.maxCPUKeys)
        gpuKeys = SMCSensors.spread(gpu, limit: SMCSensors.maxGPUKeys)

        if let numKey = keyIfPresent("FNum"), let n = read(numKey) {
            fanCount = Int(n)
            fanKeys = (0..<fanCount).compactMap { i in
                guard let current = keyIfPresent("F\(i)Ac") else { return nil }
                // 最小/最大转速是固定值，只在发现阶段读取一次。
                return (current, keyIfPresent("F\(i)Mn").flatMap(read), keyIfPresent("F\(i)Mx").flatMap(read))
            }
        } else {
            fanCount = 0
        }
    }
}
