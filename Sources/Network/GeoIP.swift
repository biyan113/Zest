//
//  GeoIP.swift
//  Zest
//
//  离线 IP 归属地（国家/地区 + ASN 组织）。数据来自 DB-IP Lite（CC BY 4.0，https://db-ip.com），
//  由 Tools/build_geoip.py 转换为紧凑区间表，压缩后随应用分发。
//  首次使用时解压到 ~/Library/Caches/<bundle id>/，之后以内存映射方式读取：
//  每次查询只触及二分查找经过的少量内存页，常驻内存几乎不增加。查询全程离线。
//

import Foundation

struct GeoInfo: Equatable {
    var countryCode: String?
    var asn: UInt32?
    var organization: String?

    var flag: String {
        guard let cc = countryCode, cc.count == 2 else { return "" }
        return cc.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(String.init).joined()
    }

    var countryName: String? {
        countryCode.flatMap { GeoIP.localizedName($0) }
    }

    /// 例如 “🇺🇸 美国 · Google LLC”
    var summary: String {
        [countryCode.map { "\(flag) \(countryName ?? $0)" }, organization].compactMap { $0 }.joined(separator: " · ")
    }
}

final class GeoIPDatabase {
    private let data: Data
    private let month: String
    private var countries: [String] = []
    private var orgOffsets: [Int] = []
    private struct Table { var count: Int; var starts: Int; var values: Int }
    private var v4Country = Table(count: 0, starts: 0, values: 0)
    private var v4Org = Table(count: 0, starts: 0, values: 0)
    private var v6Country = Table(count: 0, starts: 0, values: 0)
    private var v6Org = Table(count: 0, starts: 0, values: 0)

    var dataMonth: String { month }

    init?(data: Data) {
        guard data.count > 16, data.prefix(4) == Data("ZGEO".utf8) else { return nil }
        self.data = data
        month = String(decoding: data[data.startIndex + 6 ..< data.startIndex + 13], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        var ok = true
        data.withUnsafeBytes { raw in
            var o = 14
            func u16() -> Int { defer { o += 2 }; return Int(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
            func u32() -> Int { defer { o += 4 }; return Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            let nc = u16()
            for i in 0..<nc {
                countries.append(String(decoding: raw[o + i * 2 ..< o + i * 2 + 2], as: UTF8.self))
            }
            o += nc * 2
            let nn = u32()
            orgOffsets.reserveCapacity(nn)
            for _ in 0..<nn {
                orgOffsets.append(o)
                let len = Int(raw.loadUnaligned(fromByteOffset: o + 4, as: UInt16.self))
                o += 6 + len
            }
            func table(width: Int, valueWidth: Int) -> Table {
                let n = u32()
                let t = Table(count: n, starts: o, values: o + n * width)
                o += n * (width + valueWidth)
                return t
            }
            v4Country = table(width: 4, valueWidth: 1)
            v4Org = table(width: 4, valueWidth: 4)
            v6Country = table(width: 8, valueWidth: 1)
            v6Org = table(width: 8, valueWidth: 4)
            ok = o == raw.count
        }
        if !ok { return nil }
    }

    func lookup(_ address: String) -> GeoInfo? {
        let bare = address.split(separator: "%").first.map(String.init) ?? address
        var a4 = in_addr()
        if inet_pton(AF_INET, bare, &a4) == 1 {
            let key = UInt64(UInt32(bigEndian: a4.s_addr))
            return info(country: value(v4Country, key: key, wide: false, valueWidth: 1),
                        org: value(v4Org, key: key, wide: false, valueWidth: 4))
        }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, bare, &a6) == 1 {
            let bytes = withUnsafeBytes(of: a6) { Array($0) }
            // IPv4 映射地址按 IPv4 查询
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return lookup("\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")
            }
            let key = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return info(country: value(v6Country, key: key, wide: true, valueWidth: 1),
                        org: value(v6Org, key: key, wide: true, valueWidth: 4))
        }
        return nil
    }

    /// 二分查找最后一个 start ≤ key 的区间，返回其值（0 表示未知）。
    private func value(_ t: Table, key: UInt64, wide: Bool, valueWidth: Int) -> Int {
        guard t.count > 0 else { return 0 }
        return data.withUnsafeBytes { raw -> Int in
            func start(_ i: Int) -> UInt64 {
                wide ? raw.loadUnaligned(fromByteOffset: t.starts + i * 8, as: UInt64.self)
                     : UInt64(raw.loadUnaligned(fromByteOffset: t.starts + i * 4, as: UInt32.self))
            }
            guard start(0) <= key else { return 0 }
            var lo = 0, hi = t.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if start(mid) <= key { lo = mid } else { hi = mid - 1 }
            }
            let at = t.values + lo * valueWidth
            return valueWidth == 1 ? Int(raw[at]) : Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
        }
    }

    private func info(country: Int, org: Int) -> GeoInfo? {
        var result = GeoInfo()
        if country > 0, country < countries.count { result.countryCode = countries[country] }
        if org > 0, org < orgOffsets.count {
            data.withUnsafeBytes { raw in
                let o = orgOffsets[org]
                result.asn = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                let len = Int(raw.loadUnaligned(fromByteOffset: o + 4, as: UInt16.self))
                result.organization = String(decoding: raw[o + 6 ..< o + 6 + len], as: UTF8.self)
            }
        }
        return result.countryCode == nil && result.organization == nil ? nil : result
    }
}

/// 全局入口：懒加载、线程安全、带缓存。只对公网地址查询。
enum GeoIP {
    private static let lock = NSLock()
    private static var database: GeoIPDatabase?
    private static var loadAttempted = false
    private static var cache: [String: GeoInfo?] = [:]

    static var dataMonth: String? {
        lock.lock(); defer { lock.unlock() }
        return database?.dataMonth
    }

    static func lookup(_ address: String) -> GeoInfo? {
        guard AddressScopes.scope(of: address) == .internet else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[address] { return hit }
        if !loadAttempted {
            loadAttempted = true
            database = load()
        }
        let result = database?.lookup(address)
        if cache.count > 20_000 { cache.removeAll() }
        cache[address] = result
        return result
    }

    /// `system` 用 `Locale.current`；指定语言用该语言的 Locale。国家名不是词条。
    static func localizedName(_ code: String) -> String? {
        let language = AppLanguage.stored(UserDefaults.standard.string(forKey: "appLanguage"))
        let locale: Locale = language == .system ? .current : Locale(identifier: language.rawValue)
        return locale.localizedString(forRegionCode: code)
    }

    /// 解压到缓存目录（按数据文件大小与修改时间命名，更新应用后自动重建），再以内存映射方式打开。
    private static func load() -> GeoIPDatabase? {
        guard let src = Bundle.main.url(forResource: "geoip", withExtension: "deflate") else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        let stamp = "\((attrs?[.size] as? Int) ?? 0)"
        let fm = FileManager.default
        let dir = (fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.zest.monitor", isDirectory: true)
        let cached = dir.appendingPathComponent("geoip-\(stamp).bin")
        if !fm.fileExists(atPath: cached.path) {
            guard let raw = try? NSData(contentsOf: src).decompressed(using: .zlib) as Data else { return nil }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // 清理旧版本
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("geoip-") }.forEach { try? fm.removeItem(at: $0) }
            guard (try? raw.write(to: cached, options: .atomic)) != nil else { return GeoIPDatabase(data: raw) }
        }
        guard let mapped = try? Data(contentsOf: cached, options: .alwaysMapped) else { return nil }
        return GeoIPDatabase(data: mapped)
    }
}
