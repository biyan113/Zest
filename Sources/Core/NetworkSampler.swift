//
//  NetworkSampler.swift
//  Zest
//
//  逻辑移植自 Lemon Cleaner LemonStat/CmcNetSysctl：
//  通过 sysctl(NET_RT_IFLIST2) 读取 64 位网卡计数器，只统计物理/蜂窝/PPP 接口，
//  物理接口无流量时兜底统计除回环、隧道、抓包以外的接口（流量被 VPN 重定向的场景）。
//

import Foundation

struct InterfaceCounters: Equatable {
    var bytesIn: UInt64
    var bytesOut: UInt64
}

struct NetworkReading: Equatable {
    var downloadRate: Double      // 字节/秒
    var uploadRate: Double
    var sessionDownload: UInt64   // 本次启动以来
    var sessionUpload: UInt64
    var bootDownload: UInt64      // 当前接口计数器之和（接口重建后会从 0 重新计数）
    var bootUpload: UInt64
}

enum NetworkMath {
    /// 计数器差值；接口重置导致计数变小时视为 0，而不是产生巨大的负值或回绕值。
    static func delta(previous: UInt64, current: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    /// 逐接口求差再求和：只统计前后两次都存在的接口。
    /// 这样接口出现/消失（VPN 连接、断开，或物理网卡与兜底集合切换）不会被误算成一次巨大的流量。
    static func delta<K: Hashable>(previous: [K: InterfaceCounters], current: [K: InterfaceCounters]) -> InterfaceCounters {
        var result = InterfaceCounters(bytesIn: 0, bytesOut: 0)
        for (key, c) in current {
            guard let p = previous[key] else { continue }
            result.bytesIn &+= delta(previous: p.bytesIn, current: c.bytesIn)
            result.bytesOut &+= delta(previous: p.bytesOut, current: c.bytesOut)
        }
        return result
    }
}

final class NetworkSampler {
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    private var previous: [UInt16: InterfaceCounters]?
    private var previousTime: UInt64 = 0
    private var sessionIn: UInt64 = 0
    private var sessionOut: UInt64 = 0
    private var names: [UInt16: String] = [:]

    func sample(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> NetworkReading? {
        guard let current = readCounters() else { return nil }
        defer { previous = current; previousTime = now }
        let total = current.values.reduce(InterfaceCounters(bytesIn: 0, bytesOut: 0)) {
            InterfaceCounters(bytesIn: $0.bytesIn &+ $1.bytesIn, bytesOut: $0.bytesOut &+ $1.bytesOut)
        }
        guard let previous, now > previousTime else {
            return NetworkReading(downloadRate: 0, uploadRate: 0, sessionDownload: 0, sessionUpload: 0,
                                  bootDownload: total.bytesIn, bootUpload: total.bytesOut)
        }
        let d = NetworkMath.delta(previous: previous, current: current)
        sessionIn &+= d.bytesIn
        sessionOut &+= d.bytesOut
        let seconds = Double(now - previousTime) / 1e9
        return NetworkReading(downloadRate: Double(d.bytesIn) / seconds, uploadRate: Double(d.bytesOut) / seconds,
                              sessionDownload: sessionIn, sessionUpload: sessionOut,
                              bootDownload: total.bytesIn, bootUpload: total.bytesOut)
    }

    /// 返回参与统计的接口（按接口索引）及其计数器。
    func readCounters() -> [UInt16: InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return nil }
        if length > buffer.count { buffer = [UInt8](repeating: 0, count: length + 4096) }
        length = buffer.count
        let ok = buffer.withUnsafeMutableBytes { sysctl(&mib, 6, $0.baseAddress, &length, nil, 0) == 0 }
        guard ok else { return nil }

        var physical: [UInt16: InterfaceCounters] = [:]
        var fallback: [UInt16: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = base.advanced(by: offset).loadUnaligned(as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length else { continue }
                let msg = base.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                let data = msg.ifm_data
                let type = Int32(data.ifi_type)
                let counters = InterfaceCounters(bytesIn: data.ifi_ibytes, bytesOut: data.ifi_obytes)
                switch type {
                case IFT_ETHER, IFT_PPP, IFT_MODEM, IFT_CELLULAR:
                    // awdl/llw 是 AirDrop 等点对点链路，不计入上网流量。
                    let name = interfaceName(index: msg.ifm_index)
                    if !name.hasPrefix("awdl") && !name.hasPrefix("llw") {
                        physical[msg.ifm_index] = counters
                    }
                    fallback[msg.ifm_index] = counters
                case IFT_LOOP, IFT_GIF, IFT_STF, IFT_PKTAP:
                    break
                default:
                    fallback[msg.ifm_index] = counters
                }
            }
        }
        let physicalIn = physical.values.reduce(UInt64(0)) { $0 &+ $1.bytesIn }
        return physicalIn == 0 ? fallback : physical
    }

    private func interfaceName(index: UInt16) -> String {
        if let cached = names[index] { return cached }
        var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let name = if_indextoname(UInt32(index), &buf) != nil ? String(cString: buf) : ""
        names[index] = name
        return name
    }
}
