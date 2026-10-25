//
//  HistoryGeoTests.swift
//  ZestTests
//

import XCTest
@testable import Zest

final class HistoryStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-test-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: url.path + $0) }
    }

    private let meta = ["A": AppMeta(key: "A", name: "Alpha", bundlePath: "/Applications/Alpha.app", kind: .app),
                        "B": AppMeta(key: "B", name: "beta", bundlePath: nil, kind: .commandLine)]

    func testMinutesAccumulateAndAggregate() throws {
        let store = try XCTUnwrap(HistoryStore(url: url))
        store.addMinute(100, traffic: ["A": TrafficPoint(bytesIn: 10, bytesOut: 1)], meta: meta)
        // 同一分钟再次写入（例如退出前补写）应累加
        store.addMinute(100, traffic: ["A": TrafficPoint(bytesIn: 5, bytesOut: 1), "B": TrafficPoint(bytesIn: 100, bytesOut: 0)], meta: meta)
        store.addMinute(105, traffic: ["A": TrafficPoint(bytesIn: 1, bytesOut: 2)], meta: meta)

        let buckets = store.totals(sinceMinute: 100, untilMinute: 109, bucket: 5)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0], TrafficPoint(bytesIn: 115, bytesOut: 2))
        XCTAssertEqual(buckets[1], TrafficPoint(bytesIn: 1, bytesOut: 2))
        XCTAssertEqual(store.totals(sinceMinute: 100, untilMinute: 109, bucket: 5, appKey: "B")[0].bytesIn, 100)

        let apps = store.appTotals(sinceMinute: 0)
        XCTAssertEqual(apps.map(\.key), ["B", "A"])
        XCTAssertEqual(apps[1].name, "Alpha")
        XCTAssertEqual(apps[1].bundlePath, "/Applications/Alpha.app")
        XCTAssertEqual(apps[1].bytesIn, 16)
        XCTAssertEqual(apps[0].kind, .commandLine)
        XCTAssertEqual(store.appMinutes(sinceMinute: 101)["A"]?[105], TrafficPoint(bytesIn: 1, bytesOut: 2))
    }

    func testPersistsAcrossReopenAndPrunes() throws {
        let now = 10_000
        do {
            let store = try XCTUnwrap(HistoryStore(url: url))
            store.addMinute(now - 2000, traffic: ["A": TrafficPoint(bytesIn: 1, bytesOut: 1)], meta: meta)  // 超过 24 小时
            store.addMinute(now - 10, traffic: ["A": TrafficPoint(bytesIn: 7, bytesOut: 0)], meta: meta)
            store.addAlerts([NetworkAlert(date: Date(), kind: .beacon, appKey: "A", appName: "Alpha", detail: "d", dedupKey: "k"),
                             NetworkAlert(date: Date().addingTimeInterval(-200_000), kind: .plaintext, appKey: "A",
                                          appName: "Alpha", detail: "old", dedupKey: "o")])
        }
        let store = try XCTUnwrap(HistoryStore(url: url))
        store.prune(nowMinute: now)
        XCTAssertEqual(store.appTotals(sinceMinute: 0).first?.bytesIn, 7)
        let alerts = store.alerts(since: .distantPast)
        XCTAssertEqual(alerts.map(\.kind), [.beacon])
        XCTAssertEqual(alerts.first?.detail, "d")
        store.deleteAlerts(kind: .beacon, appKey: "B")
        XCTAssertEqual(store.alerts(since: .distantPast).count, 1)
        store.deleteAlerts(kind: .beacon, appKey: "A")
        XCTAssertTrue(store.alerts(since: .distantPast).isEmpty)
        store.clearAll()
        XCTAssertTrue(store.appTotals(sinceMinute: 0).isEmpty)
    }

    func testTrackerReportsCompletedMinutes() {
        let t = NetworkTracker()
        t.ownerLookup = { _, name in ProcessOwner(key: name, bundlePath: nil, name: name, kind: .app) }
        var reported: [(Int, [String: TrafficPoint])] = []
        t.onMinuteCompleted = { m, traffic, meta in
            reported.append((m, traffic))
            XCTAssertEqual(meta["a"]?.name, "a")
        }
        let base = Date(timeIntervalSince1970: 60 * 1000 + 5)
        func sample(_ v: UInt64) -> NettopSample {
            NettopSample(processes: [NettopProcessRow(name: "a", pid: 1, bytesIn: v, bytesOut: 0)])
        }
        _ = t.ingest(sample(0), now: 1_000_000_000, date: base)
        _ = t.ingest(sample(100), now: 3_000_000_000, date: base.addingTimeInterval(2))
        _ = t.ingest(sample(150), now: 63_000_000_000, date: base.addingTimeInterval(62))   // 跨入下一分钟
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.0, 1000)
        // 第 1000 分钟包含两次增量：100（首个增量）+ 50（跨分钟那次采样计入新分钟之前的桶）
        XCTAssertEqual(reported.first?.1["a"]?.bytesIn, 150)
        XCTAssertNil(t.takePartialMinute())
    }
}

final class GeoIPTests: XCTestCase {
    func testOfflineLookups() {
        // 国家名是界面语言下的可见文案。断言仍是「美国」，所以固定走 zh-Hans，不随系统语言变。
        let defaults = UserDefaults.standard
        let languageKey = "appLanguage"
        let previousLanguage = defaults.object(forKey: languageKey)
        defaults.set(AppLanguage.zhHans.rawValue, forKey: languageKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: languageKey)
            } else {
                defaults.removeObject(forKey: languageKey)
            }
        }

        let google = GeoIP.lookup("8.8.8.8")
        XCTAssertEqual(google?.countryCode, "US")
        XCTAssertEqual(google?.asn, 15169)
        XCTAssertEqual(google?.organization?.contains("Google"), true)
        XCTAssertEqual(google?.flag, "🇺🇸")
        XCTAssertEqual(google?.countryName, "美国")
        XCTAssertEqual(GeoIP.lookup("2400:3200::1")?.countryCode, "CN")
        XCTAssertEqual(GeoIP.lookup("::ffff:8.8.4.4")?.asn, 15169)
        // 非公网地址不查询
        XCTAssertNil(GeoIP.lookup("192.168.1.1"))
        XCTAssertNil(GeoIP.lookup("198.18.0.5"))
        XCTAssertNil(GeoIP.lookup("not an ip"))
        XCTAssertEqual(GeoIP.dataMonth?.count, 7)
    }
}
