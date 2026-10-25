//
//  NetworkTracker.swift
//  Zest
//
//  把 nettop 采样汇总为“每个应用”的实时速率、本次累计、60 分钟历史与当前连接。
//

import Foundation

struct TrafficPoint: Equatable {
    var bytesIn: Double
    var bytesOut: Double
}

struct FlowInfo: Identifiable, Equatable {
    var id: String               // NettopConnectionRow.key
    var appKey: String
    var appName: String
    var pid: pid_t
    var proto: NetProtocol
    var local: Endpoint?
    var remote: Endpoint?
    var state: String
    var scope: AddressScope
    var bytesIn: UInt64
    var bytesOut: UInt64
    var firstSeen: Date
    /// 公网远端的离线归属地（DB-IP Lite）。
    var geo: GeoInfo? = nil

    var isListening: Bool { remote == nil && (state == "Listen" || proto == .udp) }
    var isEstablished: Bool { remote != nil && (proto == .udp || state == "Established") }
    var service: String? { remote.flatMap { AddressClassifier.service(port: $0.port, proto: proto) } }
}

struct AppTraffic: Identifiable, Equatable {
    var key: String
    var name: String
    var bundlePath: String?
    var kind: ProcessKind
    var pids: Set<pid_t>
    var rateIn: Double = 0
    var rateOut: Double = 0
    var sessionIn: UInt64 = 0
    var sessionOut: UInt64 = 0
    /// 每分钟流量（最近 60 分钟）。
    var minutes: [TrafficPoint] = []
    var lastActive: Date?

    var id: String { key }
    var sessionTotal: UInt64 { sessionIn &+ sessionOut }
    var rateTotal: Double { rateIn + rateOut }
}

struct NetworkState: Equatable {
    var apps: [AppTraffic] = []
    var flows: [FlowInfo] = []
    var rateIn: Double = 0
    var rateOut: Double = 0
    var sessionIn: UInt64 = 0
    var sessionOut: UInt64 = 0
    /// 最近约 5 分钟的逐次采样速率。
    var live: [TrafficPoint] = []
    /// 最近 60 分钟的每分钟流量。
    var minutes: [TrafficPoint] = []
    var sampledAt: Date?
    var startedAt = Date()

    var activeFlows: [FlowInfo] { flows.filter(\.isEstablished) }
    var onlineApps: [AppTraffic] {
        let keys = Set(activeFlows.filter { $0.scope != .loopback }.map(\.appKey))
        return apps.filter { keys.contains($0.key) }
    }
}

final class NetworkTracker {
    static let liveCapacity = 150
    static let minuteCapacity = 60

    private let owners = ProcessOwnerResolver()
    private var previousProcess: [pid_t: (UInt64, UInt64)] = [:]
    private var previousTime: UInt64?
    private var apps: [String: AppTraffic] = [:]
    private var appMinuteBucket: [String: TrafficPoint] = [:]
    private var totalMinuteBucket = TrafficPoint(bytesIn: 0, bytesOut: 0)
    private var currentMinute: Int?
    private var live = RingBuffer<TrafficPoint>(capacity: liveCapacity)
    private var minutes = RingBuffer<TrafficPoint>(capacity: minuteCapacity)
    private var firstSeen: [String: Date] = [:]
    private var sessionIn: UInt64 = 0
    private var sessionOut: UInt64 = 0
    private let startedAt = Date()

    /// owner 解析可注入，便于测试。
    var ownerLookup: (pid_t, String) -> ProcessOwner
    /// 每分钟结束时回调：分钟序号、各应用流量、应用信息（用于持久化）。
    var onMinuteCompleted: ((Int, [String: TrafficPoint], [String: AppMeta]) -> Void)?
    var geoLookupEnabled = true

    init() {
        let resolver = owners
        ownerLookup = { pid, fallbackName in
            let o = resolver.owner(of: pid)
            // 无法读取路径（其他用户的进程）时 proc_name 也可能为空，退回 nettop 给出的名字。
            return o.name.hasPrefix("pid ") ? ProcessOwner(key: fallbackName, bundlePath: nil, name: fallbackName, kind: .system) : o
        }
    }

    /// - Parameter interval: nettop 的采样间隔。nettop 经管道输出时是块缓冲的，多份采样可能同时到达，
    ///   按到达时间算出的间隔会严重偏小（速率被放大上百倍）；因此优先使用 nettop 自身的采样间隔。
    ///   重启 nettop 后的第一份采样传 nil，按实际间隔计算。
    func ingest(_ sample: NettopSample, now: UInt64 = DispatchTime.now().uptimeNanoseconds, date: Date = Date(),
                interval: TimeInterval? = nil) -> NetworkState {
        let measured = previousTime.map { now > $0 ? Double(now - $0) / 1e9 : 0 } ?? 0
        let elapsed = previousTime == nil ? 0 : (interval ?? measured)
        var currentProcess: [pid_t: (UInt64, UInt64)] = [:]
        var rates: [String: (Double, Double)] = [:]
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var pidOwner: [pid_t: ProcessOwner] = [:]
        var seenKeys = Set<String>()

        for p in sample.processes {
            currentProcess[p.pid] = (p.bytesIn, p.bytesOut)
            let owner = ownerLookup(p.pid, p.name)
            pidOwner[p.pid] = owner
            seenKeys.insert(owner.key)
            if apps[owner.key] == nil {
                apps[owner.key] = AppTraffic(key: owner.key, name: owner.name, bundlePath: owner.bundlePath,
                                             kind: owner.kind, pids: [])
            }
            apps[owner.key]?.pids.insert(p.pid)
            guard previousTime != nil else { continue }
            // 新出现的进程：其已有计数发生在 Zest 观察之前，不计入本次。
            guard let prev = previousProcess[p.pid] else { continue }
            let dIn = p.bytesIn >= prev.0 ? p.bytesIn - prev.0 : p.bytesIn
            let dOut = p.bytesOut >= prev.1 ? p.bytesOut - prev.1 : p.bytesOut
            guard dIn > 0 || dOut > 0 else { continue }
            totalIn &+= dIn
            totalOut &+= dOut
            apps[owner.key]?.sessionIn &+= dIn
            apps[owner.key]?.sessionOut &+= dOut
            apps[owner.key]?.lastActive = date
            var r = rates[owner.key] ?? (0, 0)
            r.0 += Double(dIn); r.1 += Double(dOut)
            rates[owner.key] = r
            appMinuteBucket[owner.key, default: TrafficPoint(bytesIn: 0, bytesOut: 0)].bytesIn += Double(dIn)
            appMinuteBucket[owner.key, default: TrafficPoint(bytesIn: 0, bytesOut: 0)].bytesOut += Double(dOut)
        }

        for key in apps.keys {
            let r = rates[key] ?? (0, 0)
            apps[key]?.rateIn = elapsed > 0 ? r.0 / elapsed : 0
            apps[key]?.rateOut = elapsed > 0 ? r.1 / elapsed : 0
        }
        // 已退出的应用保留流量历史，但清理 pid 集合；从未产生流量的直接移除。
        for key in apps.keys where !seenKeys.contains(key) {
            apps[key]?.pids.removeAll()
            if apps[key]?.sessionTotal == 0 { apps[key] = nil; appMinutes[key] = nil }
        }

        sessionIn &+= totalIn
        sessionOut &+= totalOut
        totalMinuteBucket.bytesIn += Double(totalIn)
        totalMinuteBucket.bytesOut += Double(totalOut)
        if previousTime != nil, elapsed > 0 {
            live.append(TrafficPoint(bytesIn: Double(totalIn) / elapsed, bytesOut: Double(totalOut) / elapsed))
        }
        rollMinute(date)

        // 连接
        var flows: [FlowInfo] = []
        var aliveFlowKeys = Set<String>()
        flows.reserveCapacity(sample.connections.count)
        for c in sample.connections {
            let owner = pidOwner[c.pid] ?? ownerLookup(c.pid, "pid \(c.pid)")
            let key = c.key
            aliveFlowKeys.insert(key)
            let seen = firstSeen[key] ?? date
            firstSeen[key] = seen
            let scope = c.remote.map { AddressScopes.scope(of: $0.address) } ?? .loopback
            let geo = (scope == .internet && geoLookupEnabled) ? c.remote.flatMap { GeoIP.lookup($0.address) } : nil
            flows.append(FlowInfo(id: key, appKey: owner.key, appName: owner.name, pid: c.pid, proto: c.proto,
                                  local: c.local, remote: c.remote, state: c.state, scope: scope,
                                  bytesIn: c.bytesIn, bytesOut: c.bytesOut, firstSeen: seen, geo: geo))
        }
        firstSeen = firstSeen.filter { aliveFlowKeys.contains($0.key) }

        let alivePIDs = Set(currentProcess.keys)
        owners.prune(alive: alivePIDs)
        previousProcess = currentProcess
        previousTime = now

        var state = NetworkState()
        state.apps = apps.values.sorted { ($0.rateTotal, $0.sessionTotal) > ($1.rateTotal, $1.sessionTotal) }
        state.flows = flows
        state.rateIn = live.last?.bytesIn ?? 0
        state.rateOut = live.last?.bytesOut ?? 0
        state.sessionIn = sessionIn
        state.sessionOut = sessionOut
        state.live = live.elements
        state.minutes = minutes.elements + [totalMinuteBucket]
        state.sampledAt = date
        state.startedAt = startedAt
        return state
    }

    private var appMinutes: [String: RingBuffer<TrafficPoint>] = [:]

    private func meta(for keys: [String]) -> [String: AppMeta] {
        var m: [String: AppMeta] = [:]
        for k in keys {
            if let a = apps[k] { m[k] = AppMeta(key: k, name: a.name, bundlePath: a.bundlePath, kind: a.kind) }
        }
        return m
    }

    /// 取出当前未满一分钟的流量（退出前写入持久化存储），并清空该桶以免重复计入。
    func takePartialMinute() -> (Int, [String: TrafficPoint], [String: AppMeta])? {
        guard let current = currentMinute, !appMinuteBucket.isEmpty else { return nil }
        let result = (current, appMinuteBucket, meta(for: Array(appMinuteBucket.keys)))
        appMinuteBucket.removeAll()
        totalMinuteBucket = TrafficPoint(bytesIn: 0, bytesOut: 0)
        return result
    }

    /// 启动时用持久化数据恢复最近 60 分钟（按分钟对齐，缺失补 0）。
    /// 当前分钟的已有流量放入当前桶，后续写入时会与之累加。
    func preload(perApp: [String: [Int: TrafficPoint]], nowMinute: Int) {
        let first = nowMinute - NetworkTracker.minuteCapacity
        var totals = [TrafficPoint](repeating: TrafficPoint(bytesIn: 0, bytesOut: 0), count: NetworkTracker.minuteCapacity)
        for (key, minutes) in perApp {
            var ring = RingBuffer<TrafficPoint>(capacity: NetworkTracker.minuteCapacity)
            for m in first..<nowMinute {
                let p = minutes[m] ?? TrafficPoint(bytesIn: 0, bytesOut: 0)
                ring.append(p)
                totals[m - first].bytesIn += p.bytesIn
                totals[m - first].bytesOut += p.bytesOut
            }
            appMinutes[key] = ring
        }
        minutes.removeAll()
        totals.forEach { minutes.append($0) }
        currentMinute = nowMinute
        // 当前分钟已持久化的部分不放入内存桶（否则退出时会重复写入），图表会在下一分钟补齐。
    }

    private func rollMinute(_ date: Date) {
        let minute = Int(date.timeIntervalSince1970 / 60)
        if currentMinute == nil { currentMinute = minute }
        guard let current = currentMinute, minute > current else {
            for key in apps.keys {
                apps[key]?.minutes = (appMinutes[key]?.elements ?? []) + [appMinuteBucket[key] ?? TrafficPoint(bytesIn: 0, bytesOut: 0)]
            }
            return
        }
        // 跨分钟：把当前桶写入历史；中间空缺的分钟补 0。
        onMinuteCompleted?(current, appMinuteBucket, meta(for: Array(appMinuteBucket.keys)))
        let gap = min(minute - current, NetworkTracker.minuteCapacity)
        for i in 0..<gap {
            let zero = TrafficPoint(bytesIn: 0, bytesOut: 0)
            minutes.append(i == 0 ? totalMinuteBucket : zero)
            for key in apps.keys {
                appMinutes[key, default: RingBuffer(capacity: NetworkTracker.minuteCapacity)]
                    .append(i == 0 ? (appMinuteBucket[key] ?? zero) : zero)
            }
        }
        totalMinuteBucket = TrafficPoint(bytesIn: 0, bytesOut: 0)
        appMinuteBucket.removeAll()
        currentMinute = minute
        for key in apps.keys { apps[key]?.minutes = (appMinutes[key]?.elements ?? []) + [TrafficPoint(bytesIn: 0, bytesOut: 0)] }
    }
}
