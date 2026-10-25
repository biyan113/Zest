//
//  NettopParser.swift
//  Zest
//
//  解析系统自带 /usr/bin/nettop 的 CSV 流（`nettop -L 0 -x -n -t external -J state,bytes_in,bytes_out`）。
//  nettop 基于系统 NetworkStatistics，普通权限即可看到所有进程（含系统进程）的连接与收发字节，无需抓包或 root。
//
//  输出格式：每次采样以表头行 “,state,bytes_in,bytes_out,” 开始；
//  进程行为 “名称.pid,,下行字节,上行字节,”，其后是该进程的连接行 “tcp4 本地<->远端,状态,下行,上行,”。
//

import Foundation

struct NettopProcessRow: Equatable {
    var name: String
    var pid: pid_t
    var bytesIn: UInt64
    var bytesOut: UInt64
}

struct NettopConnectionRow: Equatable {
    var pid: pid_t
    var proto: NetProtocol
    var ipv6: Bool
    var local: Endpoint?
    var remote: Endpoint?
    var state: String
    var bytesIn: UInt64
    var bytesOut: UInt64

    /// 用于跨采样识别同一条连接。
    var key: String {
        "\(pid)|\(proto.rawValue)|\(local?.display ?? "*")|\(remote?.display ?? "*")"
    }
}

struct NettopSample: Equatable {
    var processes: [NettopProcessRow] = []
    var connections: [NettopConnectionRow] = []
}

final class NettopParser {
    private var current: NettopSample?
    private var stateIndex = 1, inIndex = 2, outIndex = 3

    /// 逐行输入；遇到下一次采样的表头时返回上一份完整采样。
    func feed(_ line: Substring) -> NettopSample? {
        guard !line.isEmpty else { return nil }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        if line.hasPrefix(",") {
            for (i, f) in fields.enumerated() {
                switch f {
                case "state": stateIndex = i
                case "bytes_in": inIndex = i
                case "bytes_out": outIndex = i
                default: break
                }
            }
            let finished = current
            current = NettopSample()
            return finished
        }
        guard current != nil, let head = fields.first else { return nil }
        let bytesIn = field(fields, inIndex).flatMap { UInt64($0) } ?? 0
        let bytesOut = field(fields, outIndex).flatMap { UInt64($0) } ?? 0

        if let conn = NettopParser.connection(String(head), state: field(fields, stateIndex) ?? "",
                                              bytesIn: bytesIn, bytesOut: bytesOut,
                                              pid: current?.processes.last?.pid ?? -1) {
            current?.connections.append(conn)
        } else if let dot = head.lastIndex(of: "."), let pid = pid_t(head[head.index(after: dot)...]) {
            current?.processes.append(NettopProcessRow(name: String(head[..<dot]), pid: pid,
                                                       bytesIn: bytesIn, bytesOut: bytesOut))
        }
        return nil
    }

    /// 结束时取出尚未完成的最后一份采样（用于单次采样模式）。
    func flush() -> NettopSample? {
        defer { current = nil }
        return current
    }

    private func field(_ fields: [Substring], _ i: Int) -> Substring? {
        i < fields.count && !fields[i].isEmpty ? fields[i] : nil
    }

    static func connection(_ head: String, state: Substring, bytesIn: UInt64, bytesOut: UInt64, pid: pid_t) -> NettopConnectionRow? {
        let protoToken = head.prefix(4)
        let proto: NetProtocol
        switch protoToken {
        case "tcp4", "tcp6": proto = .tcp
        case "udp4", "udp6": proto = .udp
        default: return nil
        }
        let v6 = protoToken.hasSuffix("6")
        let rest = head.dropFirst(5)
        guard let arrow = rest.range(of: "<->") else { return nil }
        let local = endpoint(rest[..<arrow.lowerBound], v6: v6)
        let remote = endpoint(rest[arrow.upperBound...], v6: v6)
        return NettopConnectionRow(pid: pid, proto: proto, ipv6: v6, local: local, remote: remote,
                                   state: String(state), bytesIn: bytesIn, bytesOut: bytesOut)
    }

    /// IPv4 为 “地址:端口”，IPv6 为 “地址.端口”。端口为 “*” 时返回 nil；
    /// 地址为 “*” 而端口确定（如 “*:22”）表示监听在所有接口上，保留为 Endpoint(address: "*")。
    static func endpoint(_ s: Substring, v6: Bool) -> Endpoint? {
        guard let sep = s.lastIndex(of: v6 ? "." : ":") else { return nil }
        let address = String(s[..<sep])
        guard let port = UInt16(s[s.index(after: sep)...]) else { return nil }
        return Endpoint(address: address, port: port)
    }
}

enum AddressScopes {
    /// 对 nettop 输出的文本地址分类（复用 AddressClassifier 的规则）。
    static func scope(of address: String) -> AddressScope {
        var a4 = in_addr()
        if inet_pton(AF_INET, address, &a4) == 1 {
            return AddressClassifier.scope(ipv4: UInt32(bigEndian: a4.s_addr))
        }
        var a6 = in6_addr()
        let bare = address.split(separator: "%").first.map(String.init) ?? address
        if inet_pton(AF_INET6, bare, &a6) == 1 {
            return AddressClassifier.scope(ipv6: withUnsafeBytes(of: a6) { Array($0) })
        }
        return .internet
    }
}
