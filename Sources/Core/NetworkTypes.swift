//
//  ConnectionSampler.swift
//  Zest
//
//  网络连接相关的公共类型与地址分类（公网 / 局域网 / 保留 / 本机）。
//

import Foundation

enum NetProtocol: String { case tcp = "TCP", udp = "UDP" }

enum AddressScope: Int, Comparable {
    case internet, reserved, lan, loopback

    static func < (a: AddressScope, b: AddressScope) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .internet: return L10n.text("公网")
        case .reserved: return L10n.text("保留")
        case .lan: return L10n.text("局域网")
        case .loopback: return L10n.text("本机")
        }
    }
}

struct Endpoint: Hashable {
    var address: String
    var port: UInt16

    var display: String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
}

enum AddressClassifier {
    static func scope(ipv4 a: UInt32) -> AddressScope {
        // a 为主机字节序
        let b0 = a >> 24, b1 = (a >> 16) & 0xff
        if b0 == 127 { return .loopback }
        if b0 == 10 || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168)
            || (b0 == 169 && b1 == 254) || (b0 == 100 && (64...127).contains(b1)) { return .lan }
        // 198.18.0.0/15 基准测试网段，常被代理软件用作 Fake IP；0/8、224+/4 为保留或组播。
        if (b0 == 198 && (b1 == 18 || b1 == 19)) || b0 == 0 || b0 >= 224 { return .reserved }
        return .internet
    }

    static func scope(ipv6 bytes: [UInt8]) -> AddressScope {
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
        // IPv4 映射地址 ::ffff:a.b.c.d
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return scope(ipv4: UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15]))
        }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return .lan }   // fe80::/10 链路本地
        if (bytes[0] & 0xfe) == 0xfc { return .lan }                       // fc00::/7 唯一本地
        return .internet
    }

    static let tcpStates = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT",
                            "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]

    static func service(port: UInt16, proto: NetProtocol) -> String? {
        switch port {
        case 22: return "ssh"
        case 53: return "dns"
        case 80: return "http"
        case 443: return proto == .udp ? "quic" : "https"
        case 123: return "ntp"
        case 993: return "imaps"
        case 5223: return "apns"
        case 5353: return "mdns"
        default: return nil
        }
    }
}

