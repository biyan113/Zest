//
//  LANScanner.swift
//  Zest
//
//  被动发现局域网设备：读取系统 ARP 表（sysctl NET_RT_FLAGS + RTF_LLINFO），不发送任何广播或探测包。
//  思路与 aixisstudio/snitch 的 ARP 扫描一致，独立实现。
//

import Foundation

final class LANScanner {
    private var firstSeen: [String: Date] = [:]
    private let oui = OUIDatabase.shared

    func scan(now: Date = Date()) -> [LANDevice] {
        let gateway = LANScanner.defaultGateway()
        let entries = LANScanner.arpEntries()
        var devices: [LANDevice] = []
        for e in entries {
            let seen = firstSeen[e.mac] ?? now
            firstSeen[e.mac] = seen
            devices.append(LANDevice(ip: e.ip, mac: e.mac, interface: e.interface, isGateway: e.ip == gateway,
                                     vendor: oui.vendor(for: e.mac), firstSeen: seen))
        }
        return devices.sorted { ($0.isGateway ? 0 : 1, LANScanner.ipSortKey($0.ip)) < ($1.isGateway ? 0 : 1, LANScanner.ipSortKey($1.ip)) }
    }

    static func ipSortKey(_ ip: String) -> UInt32 {
        var a = in_addr()
        return inet_pton(AF_INET, ip, &a) == 1 ? UInt32(bigEndian: a.s_addr) : .max
    }

    struct ARPEntry: Equatable {
        var ip: String
        var mac: String
        var interface: String
    }

    private static func routeDump(flags: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, flags]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        return Array(buf.prefix(len))
    }

    /// 路由消息后的 sockaddr 按 4 字节对齐（macOS 的 ROUNDUP 规则）。
    private static func roundup(_ n: Int) -> Int { n > 0 ? 1 + ((n - 1) | 3) : 4 }

    /// 新版 macOS 不再向普通进程的路由 sysctl 返回 ARP（RTF_LLINFO）条目，
    /// 因此读取系统自带 /usr/sbin/arp -an 的输出（只读系统已有的表，不发包，单次约 8ms）。
    static func arpEntries() -> [ARPEntry] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-an"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parseARP(String(decoding: data, as: UTF8.self))
    }

    /// 解析 “? (192.168.1.1) at a0:36:bc:71:70:d8 on en0 ifscope [ethernet]”。
    static func parseARP(_ text: String) -> [ARPEntry] {
        text.split(separator: "\n").compactMap { line -> ARPEntry? in
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { return nil }
            let ip = String(line[line.index(after: open)..<close])
            let words = line[close...].split(separator: " ")
            guard let atIdx = words.firstIndex(of: "at"), atIdx + 1 < words.count else { return nil }
            let rawMAC = words[atIdx + 1]
            let parts = rawMAC.split(separator: ":")
            guard parts.count == 6, parts.allSatisfy({ UInt8($0, radix: 16) != nil }) else { return nil }   // 跳过 (incomplete)
            let mac = parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").lowercased()
            if mac == "ff:ff:ff:ff:ff:ff" || mac.hasPrefix("01:00:5e") || mac.hasPrefix("33:33") { return nil }
            var a = in_addr()
            guard inet_pton(AF_INET, ip, &a) == 1 else { return nil }
            if UInt32(bigEndian: a.s_addr) >> 24 >= 224 || ip.hasSuffix(".255") { return nil }
            let iface = words.firstIndex(of: "on").flatMap { $0 + 1 < words.count ? String(words[$0 + 1]) : nil } ?? "?"
            return ARPEntry(ip: ip, mac: mac, interface: iface)
        }
    }

    /// 默认网关（0.0.0.0/0 路由的网关地址）。
    static func defaultGateway() -> String? {
        guard let buf = routeDump(flags: RTF_GATEWAY) else { return nil }
        var gateway: String?
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= raw.count, gateway == nil {
                let rtm = base.advanced(by: offset).loadUnaligned(as: rt_msghdr.self)
                guard rtm.rtm_msglen > 0 else { break }
                defer { offset += Int(rtm.rtm_msglen) }
                guard rtm.rtm_addrs & RTA_DST != 0, rtm.rtm_addrs & RTA_GATEWAY != 0 else { continue }
                var p = offset + MemoryLayout<rt_msghdr>.size
                let dst = base.advanced(by: p).loadUnaligned(as: sockaddr_in.self)
                guard dst.sin_family == AF_INET, dst.sin_addr.s_addr == 0 else { continue }
                p += roundup(Int(dst.sin_len))
                let gw = base.advanced(by: p).loadUnaligned(as: sockaddr_in.self)
                guard gw.sin_family == AF_INET else { continue }
                var addr = gw.sin_addr
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &ipBuf, socklen_t(ipBuf.count))
                gateway = String(cString: ipBuf)
            }
        }
        return gateway
    }
}

/// MAC 前缀 → 厂商。数据来自 IEEE 公开的 MA-L 注册表（打包为 deflate 压缩的 TSV，首次查询时加载）。
final class OUIDatabase {
    static let shared = OUIDatabase()
    private var table: [String: String]?
    private let lock = NSLock()

    func vendor(for mac: String) -> String? {
        let parts = mac.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        let prefix = parts.prefix(3).map { $0.count == 1 ? "0" + $0 : String($0) }.joined().uppercased()
        lock.lock(); defer { lock.unlock() }
        if table == nil { table = OUIDatabase.load() }
        return table?[prefix]
    }

    private static func load() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "deflate"),
              let data = try? (NSData(contentsOf: url)).decompressed(using: .zlib) as Data,
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        map.reserveCapacity(41_000)
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            map[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return map
    }
}
