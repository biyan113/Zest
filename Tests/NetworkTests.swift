//
//  NetworkTests.swift
//  ZestTests
//

import XCTest
@testable import Zest

final class NettopParserTests: XCTestCase {
    static let csv = """
    ,state,bytes_in,bytes_out,
    Google Chrome H.812,,1000,200,
    tcp4 192.168.1.5:50000<->142.250.1.1:443,Established,900,150,
    udp6 *.5353<->*.*,,100,50,
    my.dotted.app.42,,10,20,
    tcp6 fe80::1%en0.60000<->fe80::2%en0.7000,Established,10,20,
    tcp4 *:22<->*:*,Listen,,,
    ,state,bytes_in,bytes_out,
    """

    func testParsesProcessesAndConnections() throws {
        let p = NettopParser()
        var samples: [NettopSample] = []
        for line in NettopParserTests.csv.split(separator: "\n") { if let s = p.feed(line) { samples.append(s) } }
        XCTAssertEqual(samples.count, 1)   // 第二个表头到来时产出第一份完整采样
        let s = try XCTUnwrap(samples.last)
        XCTAssertEqual(s.processes.map(\.name), ["Google Chrome H", "my.dotted.app"])
        XCTAssertEqual(s.processes.map(\.pid), [812, 42])
        XCTAssertEqual(s.connections.count, 4)
        let tcp = s.connections[0]
        XCTAssertEqual(tcp.pid, 812)
        XCTAssertEqual(tcp.remote, Endpoint(address: "142.250.1.1", port: 443))
        XCTAssertEqual(tcp.state, "Established")
        XCTAssertEqual(tcp.bytesIn, 900)
        XCTAssertNil(s.connections[1].remote)                    // UDP 监听
        XCTAssertEqual(s.connections[1].local, Endpoint(address: "*", port: 5353))
        XCTAssertEqual(s.connections[2].remote, Endpoint(address: "fe80::2%en0", port: 7000))
        XCTAssertEqual(s.connections[2].pid, 42)
        XCTAssertEqual(s.connections[3].local, Endpoint(address: "*", port: 22))   // 所有接口
        XCTAssertNil(s.connections[3].remote)
        XCTAssertEqual(s.connections[3].state, "Listen")
    }

    func testStringScopes() {
        XCTAssertEqual(AddressScopes.scope(of: "8.8.8.8"), .internet)
        XCTAssertEqual(AddressScopes.scope(of: "192.168.1.1"), .lan)
        XCTAssertEqual(AddressScopes.scope(of: "198.18.0.5"), .reserved)
        XCTAssertEqual(AddressScopes.scope(of: "fe80::2%en0"), .lan)
        XCTAssertEqual(AddressScopes.scope(of: "::1"), .loopback)
        XCTAssertEqual(AddressScopes.scope(of: "2606:4700::1111"), .internet)
    }
}

final class NetworkTrackerTests: XCTestCase {
    private func tracker() -> NetworkTracker {
        let t = NetworkTracker()
        t.ownerLookup = { pid, name in
            let key = pid < 100 ? "AppA" : name
            return ProcessOwner(key: key, bundlePath: nil, name: key, kind: .app)
        }
        return t
    }

    private func sample(_ rows: [(String, pid_t, UInt64, UInt64)]) -> NettopSample {
        NettopSample(processes: rows.map { NettopProcessRow(name: $0.0, pid: $0.1, bytesIn: $0.2, bytesOut: $0.3) })
    }

    func testRatesAndSessionTotalsAggregatePerApp() {
        let t = tracker()
        let s0: UInt64 = 1_000_000_000
        _ = t.ingest(sample([("a", 1, 1000, 100), ("b", 2, 500, 50)]), now: s0)
        // 两秒后：pid1 +2000/+200，pid2 +1000/+0（同属 AppA）
        let st = t.ingest(sample([("a", 1, 3000, 300), ("b", 2, 1500, 50)]), now: s0 + 2_000_000_000)
        let app = try! XCTUnwrap(st.apps.first { $0.key == "AppA" })
        XCTAssertEqual(app.sessionIn, 3000)
        XCTAssertEqual(app.sessionOut, 200)
        XCTAssertEqual(app.rateIn, 1500, accuracy: 0.001)
        XCTAssertEqual(app.rateOut, 100, accuracy: 0.001)
        XCTAssertEqual(st.sessionIn, 3000)
        XCTAssertEqual(st.rateIn, 1500, accuracy: 0.001)
    }

    func testBurstArrivalUsesNettopInterval() {
        let t = tracker()
        let s0: UInt64 = 1_000_000_000
        _ = t.ingest(sample([("a", 1, 0, 0)]), now: s0)
        // 两份采样因管道缓冲在 1ms 内先后到达：速率应按 2 秒采样间隔计算，而不是 1ms。
        let st = t.ingest(sample([("a", 1, 4000, 0)]), now: s0 + 1_000_000, interval: 2)
        XCTAssertEqual(st.rateIn, 2000, accuracy: 0.001)
    }

    func testNewProcessHistoryIsNotCountedAndResetIsSafe() {
        let t = tracker()
        let s0: UInt64 = 1_000_000_000
        _ = t.ingest(sample([("a", 1, 1000, 0)]), now: s0)
        // 新进程 pid 500 带着 9GB 历史出现：不应计入本次流量。
        var st = t.ingest(sample([("a", 1, 1000, 0), ("x", 500, 9_000_000_000, 0)]), now: s0 + 1_000_000_000)
        XCTAssertEqual(st.sessionIn, 0)
        // pid 1 计数被重置（变小）：按新计数值计入，而不是产生回绕的巨大值。
        st = t.ingest(sample([("a", 1, 10, 0), ("x", 500, 9_000_000_000, 0)]), now: s0 + 2_000_000_000)
        XCTAssertEqual(st.sessionIn, 10)
    }
}

final class AnomalyDetectorTests: XCTestCase {
    private func flow(_ app: String, remote: String, port: UInt16, local: UInt16 = 50000, proto: NetProtocol = .tcp,
                      state: String = "Established") -> FlowInfo {
        FlowInfo(id: "\(app)|\(remote)|\(port)|\(local)", appKey: app, appName: app, pid: 1, proto: proto,
                 local: Endpoint(address: "192.168.1.5", port: local), remote: Endpoint(address: remote, port: port),
                 state: state, scope: AddressScopes.scope(of: remote), bytesIn: 0, bytesOut: 0, firstSeen: Date())
    }

    private func state(_ flows: [FlowInfo], apps: [AppTraffic] = []) -> NetworkState {
        var s = NetworkState()
        s.flows = flows
        s.apps = apps
        return s
    }

    func testWarmupSuppressesNewAppThenFires() {
        let d = AnomalyDetector()
        d.warmup = 60
        let t0 = Date()
        XCTAssertTrue(d.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 443)]), devices: [], now: t0).isEmpty)
        let later = d.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 443), flow("B", remote: "1.1.1.1", port: 443)]),
                               devices: [], now: t0.addingTimeInterval(120))
        XCTAssertEqual(later.map(\.kind), [.newInternetApp])
        XCTAssertEqual(later.first?.appKey, "B")
    }

    func testPlaintextAndSuspiciousPortsDedup() {
        let d = AnomalyDetector()
        d.warmup = 0
        let t0 = Date()
        let s = state([flow("A", remote: "8.8.8.8", port: 80), flow("A", remote: "9.9.9.9", port: 4444)])
        let first = d.evaluate(state: s, devices: [], now: t0).map(\.kind)
        XCTAssertTrue(first.contains(.plaintext))
        XCTAssertTrue(first.contains(.suspiciousPort))
        // 冷却期内不重复
        let again = d.evaluate(state: s, devices: [], now: t0.addingTimeInterval(10)).map(\.kind)
        XCTAssertFalse(again.contains(.plaintext))
        XCTAssertFalse(again.contains(.suspiciousPort))
        // 局域网地址的 80 端口不算明文公网连接
        let d2 = AnomalyDetector(); d2.warmup = 0
        XCTAssertFalse(d2.evaluate(state: state([flow("A", remote: "192.168.1.1", port: 80)]), devices: []).map(\.kind).contains(.plaintext))
    }

    func testRestoredAlertsPreventDuplicatesAfterRestart() {
        let t0 = Date()
        let d = AnomalyDetector()
        d.warmup = 0
        let fired = d.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 80)]), devices: [], now: t0)
        XCTAssertEqual(fired.map(\.kind), [.newInternetApp, .plaintext])
        // 模拟重启：新的检测器从持久化的告警恢复状态
        let restarted = AnomalyDetector()
        restarted.warmup = 0
        restarted.restore(from: fired)
        XCTAssertTrue(restarted.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 80)]), devices: [],
                                         now: t0.addingTimeInterval(600)).isEmpty)
        // 冷却期（明文 1 小时）过后可以再次告警；“新的联网应用”永不重复
        let later = restarted.evaluate(state: state([flow("A", remote: "8.8.8.8", port: 80)]), devices: [],
                                       now: t0.addingTimeInterval(3700)).map(\.kind)
        XCTAssertEqual(later, [.plaintext])
    }

    func testRegularPeriodDetection() {
        let t0 = Date()
        let regular = (0..<7).map { t0.addingTimeInterval(Double($0) * 30 + ($0 % 2 == 0 ? 1 : -1)) }
        XCTAssertEqual(AnomalyDetector.regularPeriod(regular) ?? 0, 30, accuracy: 1)
        let irregular = [0, 5, 70, 80, 200, 210, 400].map { t0.addingTimeInterval(Double($0)) }
        XCTAssertNil(AnomalyDetector.regularPeriod(irregular))
        XCTAssertNil(AnomalyDetector.regularPeriod(Array(regular.prefix(5))))
        let tooFast = (0..<8).map { t0.addingTimeInterval(Double($0) * 2) }
        XCTAssertNil(AnomalyDetector.regularPeriod(tooFast))
    }

    func testBeaconFiresForRegularNewConnections() {
        let d = AnomalyDetector()
        d.warmup = 0
        let t0 = Date()
        var kinds: [AlertKind] = []
        var flows: [FlowInfo] = []
        for i in 0..<7 {
            flows.append(flow("Agent", remote: "5.6.7.8", port: 8443, local: UInt16(50000 + i)))
            kinds += d.evaluate(state: state(flows), devices: [], now: t0.addingTimeInterval(Double(i) * 60)).map(\.kind)
        }
        XCTAssertTrue(kinds.contains(.beacon))
    }

    func testVolumeSpike() {
        XCTAssertTrue(AnomalyDetector.isSpike(recent: 5_000_000, baseline: 10_000))
        XCTAssertFalse(AnomalyDetector.isSpike(recent: 500_000, baseline: 0))        // 低于 1 MB/s
        XCTAssertFalse(AnomalyDetector.isSpike(recent: 5_000_000, baseline: 2_000_000)) // 只有 2.5×
    }

    func testSuppressionRule() {
        let a = NetworkAlert(date: Date(), kind: .plaintext, appKey: "A", appName: "A", detail: "", dedupKey: "x")
        XCTAssertTrue(SuppressionRule(kind: .plaintext).matches(a))
        XCTAssertTrue(SuppressionRule(kind: .plaintext, appKey: "A").matches(a))
        XCTAssertFalse(SuppressionRule(kind: .plaintext, appKey: "B").matches(a))
        XCTAssertFalse(SuppressionRule(kind: .beacon).matches(a))
    }

    func testPrivacyScoreExplainsPenalties() {
        var s = NetworkState()
        s.flows = [flow("A", remote: "8.8.8.8", port: 80),
                   FlowInfo(id: "l", appKey: "B", appName: "B", pid: 2, proto: .tcp, local: Endpoint(address: "*", port: 8080),
                            remote: nil, state: "Listen", scope: .loopback, bytesIn: 0, bytesOut: 0, firstSeen: Date())]
        let score = PrivacyScore.compute(state: s, alerts: [])
        XCTAssertEqual(score.score, 100 - 6 - 2)
        XCTAssertEqual(score.factors.count, 2)
        XCTAssertEqual(PrivacyScore.compute(state: NetworkState(), alerts: []).score, 100)
        // 连接已关闭，但最近的明文告警仍然扣分
        let notice = NetworkAlert(date: Date(), kind: .plaintext, appKey: "A", appName: "A", detail: "", dedupKey: "p")
        XCTAssertEqual(PrivacyScore.compute(state: NetworkState(), alerts: [notice]).score, 97)
    }
}

final class LANTests: XCTestCase {
    func testParseARP() {
        let text = """
        ? (192.168.50.1) at a0:36:bc:71:70:d8 on en7 ifscope [ethernet]
        ? (192.168.50.61) at cc:b8:a8:4:4c:2e on en7 ifscope [ethernet]
        ? (192.168.50.77) at (incomplete) on en7 ifscope [ethernet]
        ? (192.168.50.255) at ff:ff:ff:ff:ff:ff on en7 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en7 ifscope permanent [ethernet]
        """
        let e = LANScanner.parseARP(text)
        XCTAssertEqual(e.map(\.ip), ["192.168.50.1", "192.168.50.61"])
        XCTAssertEqual(e[1].mac, "cc:b8:a8:04:4c:2e")
        XCTAssertEqual(e[0].interface, "en7")
    }

    func testOUIVendorAndRandomizedMAC() {
        // 00:03:93 为 Apple 的注册前缀（IEEE 公开注册表）。
        XCTAssertEqual(OUIDatabase.shared.vendor(for: "00:03:93:12:34:56")?.hasPrefix("Apple"), true)
        XCTAssertNil(OUIDatabase.shared.vendor(for: "56:f7:92:89:1b:50"))
        let d = LANDevice(ip: "1.2.3.4", mac: "56:f7:92:89:1b:50", interface: "en0", isGateway: false, vendor: nil, firstSeen: Date())
        XCTAssertTrue(d.isRandomizedMAC)
        XCTAssertNotNil(LANScanner.defaultGateway())
    }
}
