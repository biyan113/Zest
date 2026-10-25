//
//  AnomalyDetector.swift
//  Zest
//
//  基于流量与连接快照的异常检测。告警类型参考 aixisstudio/snitch（NEW_HOST、SUSPICIOUS_PORT、
//  PORT_SCAN、BEACON、VOLUME_SPIKE 等），规则为独立实现，且只使用连接元数据，不检查数据内容。
//

import Foundation

enum AlertSeverity: Int, Comparable {
    case info, notice, warning
    static func < (a: AlertSeverity, b: AlertSeverity) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .info: return L10n.text("alert.severity.info", defaultValue: "提示")
        case .notice: return L10n.text("alert.severity.notice", defaultValue: "注意")
        case .warning: return L10n.text("alert.severity.warning", defaultValue: "警告")
        }
    }
}

enum AlertKind: String, CaseIterable, Codable {
    case newInternetApp, newLANDevice, plaintext, suspiciousPort, volumeSpike, beacon, inboundScan, exposedListener

    var title: String {
        switch self {
        case .newInternetApp: return L10n.text("新的联网应用")
        case .newLANDevice: return L10n.text("局域网新设备")
        case .plaintext: return L10n.text("明文协议连接")
        case .suspiciousPort: return L10n.text("可疑端口连接")
        case .volumeSpike: return L10n.text("上传流量突增")
        case .beacon: return L10n.text("周期性外连")
        case .inboundScan: return L10n.text("疑似端口扫描")
        case .exposedListener: return L10n.text("对外开放的端口")
        }
    }

    var severity: AlertSeverity {
        switch self {
        case .newInternetApp, .newLANDevice, .exposedListener: return .info
        case .plaintext: return .notice
        case .suspiciousPort, .volumeSpike, .beacon, .inboundScan: return .warning
        }
    }

    var symbol: String {
        switch self {
        case .newInternetApp: return "app.badge"
        case .newLANDevice: return "wifi.router"
        case .plaintext: return "lock.open"
        case .suspiciousPort: return "exclamationmark.shield"
        case .volumeSpike: return "arrow.up.forward.circle"
        case .beacon: return "dot.radiowaves.left.and.right"
        case .inboundScan: return "scope"
        case .exposedListener: return "door.left.hand.open"
        }
    }
}

struct NetworkAlert: Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var kind: AlertKind
    var appKey: String?
    var appName: String?
    var detail: String
    /// 去重键：同一键在冷却期内只告警一次。
    var dedupKey: String
}

/// 忽略规则：某类告警全部忽略，或只忽略某个应用/设备的某类告警。
struct SuppressionRule: Codable, Hashable, Identifiable {
    var kind: AlertKind
    var appKey: String?
    var appName: String?
    var id: String { kind.rawValue + "|" + (appKey ?? "*") }

    func matches(_ a: NetworkAlert) -> Bool { a.kind == kind && (appKey == nil || appKey == a.appKey) }
}

struct LANDevice: Identifiable, Equatable {
    var ip: String
    var mac: String
    var interface: String
    var isGateway: Bool
    var vendor: String?
    var firstSeen: Date

    var id: String { ip }
    /// 本地管理位（第一字节 bit1）置位：多为系统随机化的私有 MAC。
    var isRandomizedMAC: Bool {
        guard let first = UInt8(mac.prefix(2), radix: 16) else { return false }
        return first & 0x02 != 0
    }
}

final class AnomalyDetector {
    /// 启动后的学习期：期间只记录基线，不对“新应用 / 新设备”告警。
    var warmup: TimeInterval = 60
    static let plaintextPorts: Set<UInt16> = [21, 23, 80, 110, 143]
    static let suspiciousPorts: Set<UInt16> = [23, 1337, 3389, 4444, 5555, 5900, 6666, 6667, 6697, 12345, 31337]

    private var start: Date?
    private var knownInternetApps = Set<String>()
    private var knownDevices = Set<String>()
    private var lastFired: [String: Date] = [:]
    private var uploadWindow: [String: [(Date, Double)]] = [:]
    private var newFlowTimes: [String: [Date]] = [:]
    private var seenFlowIDs = Set<String>()
    private var inboundPorts: [String: [(Date, UInt16)]] = [:]

    /// 启动时用已持久化的告警恢复去重状态，避免重启后对同一问题重复告警。
    func restore(from alerts: [NetworkAlert]) {
        for a in alerts {
            if let last = lastFired[a.dedupKey], last >= a.date { continue }
            lastFired[a.dedupKey] = a.date
            if a.kind == .newInternetApp, let key = a.appKey { knownInternetApps.insert(key) }
            if a.kind == .newLANDevice, let key = a.appKey, key.hasPrefix("lan|") { knownDevices.insert(String(key.dropFirst(4))) }
        }
    }

    func evaluate(state: NetworkState, devices: [LANDevice], now: Date = Date()) -> [NetworkAlert] {
        if start == nil { start = now }
        let learning = now.timeIntervalSince(start!) < warmup
        var alerts: [NetworkAlert] = []

        func fire(_ kind: AlertKind, key: String, app: AppTraffic? = nil, appKey: String? = nil, appName: String? = nil,
                  detail: String, cooldown: TimeInterval) {
            let dedup = kind.rawValue + "|" + key
            if let last = lastFired[dedup], now.timeIntervalSince(last) < cooldown { return }
            lastFired[dedup] = now
            alerts.append(NetworkAlert(date: now, kind: kind, appKey: app?.key ?? appKey, appName: app?.name ?? appName,
                                       detail: detail, dedupKey: dedup))
        }

        let appsByKey = Dictionary(state.apps.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let listeningPorts = Set(state.flows.filter(\.isListening).compactMap { $0.local?.port })

        for flow in state.flows {
            let isNew = seenFlowIDs.insert(flow.id).inserted
            guard let remote = flow.remote else {
                // 监听在通配地址上的 TCP 端口：局域网内其他设备可访问。
                if flow.proto == .tcp, flow.state == "Listen", let local = flow.local,
                   local.address == "*" || local.address == "0.0.0.0" || local.address == "::",
                   let app = appsByKey[flow.appKey], app.kind != .system {
                    fire(.exposedListener, key: "\(app.key)|\(local.port)", app: app,
                         detail: String(format: L10n.text("%@ 在所有网络接口上监听 TCP %lld 端口，同一网络中的设备可以连接。"),
                                        app.name, Int64(local.port)),
                         cooldown: .infinity)
                }
                continue
            }
            let app = appsByKey[flow.appKey]
            let name = app?.name ?? flow.appName

            if flow.isEstablished && flow.scope == .internet {
                if !knownInternetApps.contains(flow.appKey) {
                    knownInternetApps.insert(flow.appKey)
                    if !learning {
                        fire(.newInternetApp, key: flow.appKey, app: app, appKey: flow.appKey, appName: name,
                             detail: String(format: L10n.text("%@ 首次连接公网：%@"), name, remote.display),
                             cooldown: .infinity)
                    }
                }
                if flow.proto == .tcp && AnomalyDetector.plaintextPorts.contains(remote.port) {
                    fire(.plaintext, key: "\(flow.appKey)|\(remote.address)|\(remote.port)", app: app, appKey: flow.appKey,
                         appName: name,
                         detail: String(format: L10n.text("%1$@ 通过未加密的 %2$@ 连接 %3$@，内容可能被他人读取。"),
                                        name, flow.service ?? "TCP \(remote.port)", remote.display),
                         cooldown: 3600)
                }
                if AnomalyDetector.suspiciousPorts.contains(remote.port) {
                    fire(.suspiciousPort, key: "\(flow.appKey)|\(remote.address)|\(remote.port)", app: app,
                         appKey: flow.appKey, appName: name,
                         detail: String(format: L10n.text("%@ 连接到 %@。端口 %lld 常见于远程控制或恶意软件。"),
                                        name, remote.display, Int64(remote.port)),
                         cooldown: 3600)
                }
            }

            // 周期性外连：同一应用不断新建到同一远端的连接，且间隔高度规律。
            if isNew && flow.scope == .internet {
                let k = "\(flow.appKey)|\(remote.address)"
                var times = newFlowTimes[k, default: []]
                times.append(now)
                if times.count > 12 { times.removeFirst(times.count - 12) }
                newFlowTimes[k] = times
                if let period = AnomalyDetector.regularPeriod(times) {
                    fire(.beacon, key: k, app: app, appKey: flow.appKey, appName: name,
                         detail: String(format: L10n.text("%1$@ 约每 %2$.0f 秒新建一次到 %3$@ 的连接（共 %4$lld 次），节奏非常规律，可能是心跳或信标。"),
                                        name, period, remote.address, Int64(times.count)),
                         cooldown: 1800)
                }
            }

            // 入站扫描：同一远端在短时间内连接本机多个监听端口。
            if let local = flow.local, listeningPorts.contains(local.port), flow.scope != .loopback, isNew {
                var hits = inboundPorts[remote.address, default: []].filter { now.timeIntervalSince($0.0) < 60 }
                hits.append((now, local.port))
                inboundPorts[remote.address] = hits
                let distinct = Set(hits.map(\.1)).count
                if distinct >= 6 {
                    fire(.inboundScan, key: remote.address, appKey: nil, appName: remote.address,
                         detail: String(format: L10n.text("%@ 在 1 分钟内连接了本机 %lld 个不同端口。"),
                                        remote.address, Int64(distinct)),
                         cooldown: 600)
                }
            }
        }
        if seenFlowIDs.count > 20_000 { seenFlowIDs = Set(state.flows.map(\.id)) }
        if newFlowTimes.count > 2_000 { newFlowTimes.removeAll() }
        inboundPorts = inboundPorts.filter { !$0.value.isEmpty && now.timeIntervalSince($0.value.last!.0) < 60 }

        // 上传突增：最近 30 秒平均上传速率远高于该应用 10 分钟基线，且总量可观。
        for app in state.apps {
            var w = uploadWindow[app.key, default: []].filter { now.timeIntervalSince($0.0) < 600 }
            w.append((now, app.rateOut))
            uploadWindow[app.key] = w
            let recent = w.filter { now.timeIntervalSince($0.0) < 30 }
            let older = w.filter { now.timeIntervalSince($0.0) >= 30 }
            guard recent.count >= 3, older.count >= 6 else { continue }
            let recentAvg = recent.map(\.1).reduce(0, +) / Double(recent.count)
            let baseline = older.map(\.1).reduce(0, +) / Double(older.count)
            if AnomalyDetector.isSpike(recent: recentAvg, baseline: baseline) {
                fire(.volumeSpike, key: app.key, app: app,
                     detail: String(format: L10n.text("%1$@ 最近 30 秒平均上传 %2$@，是此前基线（%3$@）的 %4$lld× 以上。"),
                                    app.name, Fmt.rate(recentAvg), Fmt.rate(baseline), Int64(recentAvg / max(baseline, 1))),
                     cooldown: 900)
            }
        }
        if uploadWindow.count > 600 { uploadWindow = uploadWindow.filter { appsByKey[$0.key] != nil } }

        for d in devices {
            if knownDevices.insert(d.mac).inserted && !learning {
                fire(.newLANDevice, key: d.mac, appKey: "lan|\(d.mac)", appName: d.ip,
                     detail: String(format: L10n.text("%@（%@，%@）出现在局域网中。"),
                                    d.ip,
                                    d.vendor ?? (d.isRandomizedMAC ? L10n.text("私有 MAC 地址") : L10n.text("未知厂商")),
                                    d.mac),
                     cooldown: .infinity)
            }
        }
        return alerts
    }

    /// 平均上传 ≥ 1 MB/s，且至少为基线的 8 倍。
    static func isSpike(recent: Double, baseline: Double) -> Bool {
        recent >= 1_048_576 && recent >= baseline * 8
    }

    /// 至少 6 次、间隔 10 秒～10 分钟、变异系数 < 0.2 视为规律。返回平均间隔。
    static func regularPeriod(_ times: [Date]) -> Double? {
        guard times.count >= 6 else { return nil }
        let intervals = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean >= 10, mean <= 600 else { return nil }
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
        return sqrt(variance) / mean < 0.2 ? mean : nil
    }
}

/// 隐私与安全评分：从 100 分扣分，每一项扣分都列出原因，不做无法解释的估算。
struct PrivacyScore: Equatable {
    struct Factor: Equatable, Identifiable {
        var label: String
        var penalty: Int
        var id: String { label }
    }

    var score: Int
    var factors: [Factor]

    static func compute(state: NetworkState, alerts: [NetworkAlert]) -> PrivacyScore {
        var factors: [Factor] = []
        let active = state.activeFlows
        let plaintext = Set(active.filter { $0.scope == .internet && $0.proto == .tcp && $0.remote.map { AnomalyDetector.plaintextPorts.contains($0.port) } == true }
            .map { "\($0.appKey)|\($0.remote!.address)" }).count
        if plaintext > 0 { factors.append(Factor(label: String(format: L10n.text("%lld 条未加密的公网连接"), Int64(plaintext)), penalty: min(plaintext * 6, 24))) }

        let recent = alerts.filter { Date().timeIntervalSince($0.date) < 3600 }
        let recentWarnings = recent.filter { $0.kind.severity == .warning }.count
        if recentWarnings > 0 { factors.append(Factor(label: String(format: L10n.text("最近 1 小时 %lld 条警告"), Int64(recentWarnings)), penalty: min(recentWarnings * 10, 30))) }
        // 连接可能已关闭，但最近出现过的明文等“注意”级告警同样反映隐私暴露。
        let recentNotices = recent.filter { $0.kind.severity == .notice }.count
        if recentNotices > 0 { factors.append(Factor(label: String(format: L10n.text("最近 1 小时 %lld 条注意级告警"), Int64(recentNotices)), penalty: min(recentNotices * 3, 12))) }

        let exposed = Set(state.flows.filter { $0.proto == .tcp && $0.state == "Listen" && ["*", "0.0.0.0", "::"].contains($0.local?.address ?? "") }
            .compactMap { $0.local?.port }).count
        if exposed > 0 { factors.append(Factor(label: String(format: L10n.text("%lld 个端口对局域网开放"), Int64(exposed)), penalty: min(exposed * 2, 16))) }

        let internetApps = Set(active.filter { $0.scope == .internet }.map(\.appKey)).count
        if internetApps > 15 { factors.append(Factor(label: String(format: L10n.text("%lld 个应用正在连接公网"), Int64(internetApps)), penalty: min(internetApps - 15, 10))) }

        let penalty = factors.reduce(0) { $0 + $1.penalty }
        return PrivacyScore(score: max(0, 100 - penalty), factors: factors)
    }
}
