//
//  HistoryStore.swift
//  Zest
//
//  网络历史持久化（SQLite，系统自带 libsqlite3）：每分钟各应用的收发字节与告警，保留 24 小时。
//  每分钟结束时写入一次（单个事务），读写都在网络监控的串行队列上进行。
//  位置：~/Library/Application Support/<bundle id>/network-history.sqlite
//

import Foundation
import SQLite3

struct AppDayTotal: Identifiable, Equatable {
    var key: String
    var name: String
    var bundlePath: String?
    var kind: ProcessKind
    var bytesIn: UInt64
    var bytesOut: UInt64
    var id: String { key }
    var total: UInt64 { bytesIn &+ bytesOut }
}

struct AppMeta: Equatable {
    var key: String
    var name: String
    var bundlePath: String?
    var kind: ProcessKind
}

final class HistoryStore {
    static let retentionMinutes = 24 * 60
    private var db: OpaquePointer?
    let url: URL

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.zest.monitor", isDirectory: true)
            .appendingPathComponent("network-history.sqlite")
    }

    init?(url: URL = HistoryStore.defaultURL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK
        else { return nil }
        // 菜单栏进程写入、网络监控窗口进程读取：遇到短暂的锁冲突时等待而不是直接失败。
        sqlite3_busy_timeout(db, 3000)
        let ok = exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS traffic(
                minute INTEGER NOT NULL, app_key TEXT NOT NULL,
                bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL,
                PRIMARY KEY(minute, app_key)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS apps(
                app_key TEXT PRIMARY KEY, name TEXT NOT NULL, bundle TEXT, kind INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS alerts(
                id TEXT PRIMARY KEY, ts REAL NOT NULL, kind TEXT NOT NULL, app_key TEXT, app_name TEXT,
                detail TEXT NOT NULL, dedup TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS alerts_ts ON alerts(ts);
            """)
        if !ok { return nil }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK ? stmt : nil
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(stmt, i, s, -1, HistoryStore.transient) } else { sqlite3_bind_null(stmt, i) }
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }

    // MARK: 写入

    /// 写入（累加）一分钟内各应用的流量。同一分钟重复写入时累加，适合退出前写入未满一分钟的数据。
    func addMinute(_ minute: Int, traffic: [String: TrafficPoint], meta: [String: AppMeta]) {
        guard !traffic.isEmpty else { return }
        exec("BEGIN")
        if let ins = prepare("""
            INSERT INTO traffic(minute, app_key, bytes_in, bytes_out) VALUES(?,?,?,?)
            ON CONFLICT(minute, app_key) DO UPDATE SET bytes_in = bytes_in + excluded.bytes_in,
                                                       bytes_out = bytes_out + excluded.bytes_out
            """), let app = prepare("INSERT OR REPLACE INTO apps(app_key, name, bundle, kind) VALUES(?,?,?,?)") {
            for (key, t) in traffic where t.bytesIn > 0 || t.bytesOut > 0 {
                sqlite3_reset(ins)
                sqlite3_bind_int64(ins, 1, Int64(minute))
                bind(ins, 2, key)
                sqlite3_bind_int64(ins, 3, Int64(t.bytesIn))
                sqlite3_bind_int64(ins, 4, Int64(t.bytesOut))
                sqlite3_step(ins)
                if let m = meta[key] {
                    sqlite3_reset(app)
                    bind(app, 1, key); bind(app, 2, m.name); bind(app, 3, m.bundlePath)
                    sqlite3_bind_int(app, 4, Int32(m.kind.rawValue))
                    sqlite3_step(app)
                }
            }
            sqlite3_finalize(ins)
            sqlite3_finalize(app)
        }
        exec("COMMIT")
    }

    func addAlerts(_ alerts: [NetworkAlert]) {
        guard !alerts.isEmpty, let stmt = prepare("""
            INSERT OR REPLACE INTO alerts(id, ts, kind, app_key, app_name, detail, dedup) VALUES(?,?,?,?,?,?,?)
            """) else { return }
        exec("BEGIN")
        for a in alerts {
            sqlite3_reset(stmt)
            bind(stmt, 1, a.id.uuidString)
            sqlite3_bind_double(stmt, 2, a.date.timeIntervalSince1970)
            bind(stmt, 3, a.kind.rawValue); bind(stmt, 4, a.appKey); bind(stmt, 5, a.appName)
            bind(stmt, 6, a.detail); bind(stmt, 7, a.dedupKey)
            sqlite3_step(stmt)
        }
        exec("COMMIT")
        sqlite3_finalize(stmt)
    }

    func deleteAlerts(kind: AlertKind? = nil, appKey: String? = nil) {
        switch (kind, appKey) {
        case (nil, _): exec("DELETE FROM alerts")
        case (let k?, nil):
            if let s = prepare("DELETE FROM alerts WHERE kind = ?") { bind(s, 1, k.rawValue); sqlite3_step(s); sqlite3_finalize(s) }
        case (let k?, let app?):
            if let s = prepare("DELETE FROM alerts WHERE kind = ? AND app_key = ?") {
                bind(s, 1, k.rawValue); bind(s, 2, app); sqlite3_step(s); sqlite3_finalize(s)
            }
        }
    }

    /// 删除 24 小时以前的数据。
    func prune(nowMinute: Int, now: Date = Date()) {
        if let s = prepare("DELETE FROM traffic WHERE minute < ?") {
            sqlite3_bind_int64(s, 1, Int64(nowMinute - HistoryStore.retentionMinutes)); sqlite3_step(s); sqlite3_finalize(s)
        }
        if let s = prepare("DELETE FROM alerts WHERE ts < ?") {
            sqlite3_bind_double(s, 1, now.timeIntervalSince1970 - Double(HistoryStore.retentionMinutes * 60)); sqlite3_step(s); sqlite3_finalize(s)
        }
        exec("DELETE FROM apps WHERE app_key NOT IN (SELECT DISTINCT app_key FROM traffic)")
    }

    func clearAll() {
        exec("DELETE FROM traffic; DELETE FROM apps; DELETE FROM alerts; VACUUM;")
    }

    // MARK: 查询

    /// 全部应用合计，按 bucket 分钟聚合；返回从 since 起连续的桶（无数据的桶为 0）。
    func totals(sinceMinute: Int, untilMinute: Int, bucket: Int, appKey: String? = nil) -> [TrafficPoint] {
        let count = max((untilMinute - sinceMinute) / bucket + 1, 0)
        var result = [TrafficPoint](repeating: TrafficPoint(bytesIn: 0, bytesOut: 0), count: count)
        let sql = "SELECT (minute - ?1) / ?2, SUM(bytes_in), SUM(bytes_out) FROM traffic WHERE minute >= ?1 AND minute <= ?3"
            + (appKey == nil ? "" : " AND app_key = ?4") + " GROUP BY 1"
        guard let s = prepare(sql) else { return result }
        sqlite3_bind_int64(s, 1, Int64(sinceMinute))
        sqlite3_bind_int64(s, 2, Int64(bucket))
        sqlite3_bind_int64(s, 3, Int64(untilMinute))
        if let appKey { bind(s, 4, appKey) }
        while sqlite3_step(s) == SQLITE_ROW {
            let i = Int(sqlite3_column_int64(s, 0))
            guard i >= 0, i < count else { continue }
            result[i] = TrafficPoint(bytesIn: Double(sqlite3_column_int64(s, 1)), bytesOut: Double(sqlite3_column_int64(s, 2)))
        }
        sqlite3_finalize(s)
        return result
    }

    func appTotals(sinceMinute: Int) -> [AppDayTotal] {
        guard let s = prepare("""
            SELECT t.app_key, COALESCE(a.name, t.app_key), a.bundle, COALESCE(a.kind, 2), SUM(t.bytes_in), SUM(t.bytes_out)
            FROM traffic t LEFT JOIN apps a ON a.app_key = t.app_key
            WHERE t.minute >= ? GROUP BY t.app_key ORDER BY SUM(t.bytes_in) + SUM(t.bytes_out) DESC
            """) else { return [] }
        sqlite3_bind_int64(s, 1, Int64(sinceMinute))
        var result: [AppDayTotal] = []
        while sqlite3_step(s) == SQLITE_ROW {
            result.append(AppDayTotal(key: text(s, 0) ?? "", name: text(s, 1) ?? "", bundlePath: text(s, 2),
                                      kind: ProcessKind(rawValue: Int(sqlite3_column_int(s, 3))) ?? .system,
                                      bytesIn: UInt64(max(sqlite3_column_int64(s, 4), 0)),
                                      bytesOut: UInt64(max(sqlite3_column_int64(s, 5), 0))))
        }
        sqlite3_finalize(s)
        return result
    }

    /// 每个应用最近若干分钟的逐分钟流量（用于启动时恢复 60 分钟图表）。
    func appMinutes(sinceMinute: Int) -> [String: [Int: TrafficPoint]] {
        guard let s = prepare("SELECT app_key, minute, bytes_in, bytes_out FROM traffic WHERE minute >= ?") else { return [:] }
        sqlite3_bind_int64(s, 1, Int64(sinceMinute))
        var result: [String: [Int: TrafficPoint]] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let key = text(s, 0) ?? ""
            result[key, default: [:]][Int(sqlite3_column_int64(s, 1))] =
                TrafficPoint(bytesIn: Double(sqlite3_column_int64(s, 2)), bytesOut: Double(sqlite3_column_int64(s, 3)))
        }
        sqlite3_finalize(s)
        return result
    }

    func appMeta() -> [String: AppMeta] {
        guard let s = prepare("SELECT app_key, name, bundle, kind FROM apps") else { return [:] }
        var result: [String: AppMeta] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let key = text(s, 0) ?? ""
            result[key] = AppMeta(key: key, name: text(s, 1) ?? key, bundlePath: text(s, 2),
                                  kind: ProcessKind(rawValue: Int(sqlite3_column_int(s, 3))) ?? .system)
        }
        sqlite3_finalize(s)
        return result
    }

    func alerts(since: Date) -> [NetworkAlert] {
        guard let s = prepare("SELECT id, ts, kind, app_key, app_name, detail, dedup FROM alerts WHERE ts >= ? ORDER BY ts DESC LIMIT 300")
        else { return [] }
        sqlite3_bind_double(s, 1, since.timeIntervalSince1970)
        var result: [NetworkAlert] = []
        while sqlite3_step(s) == SQLITE_ROW {
            guard let kind = text(s, 2).flatMap(AlertKind.init(rawValue:)) else { continue }
            result.append(NetworkAlert(id: UUID(uuidString: text(s, 0) ?? "") ?? UUID(),
                                       date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), kind: kind,
                                       appKey: text(s, 3), appName: text(s, 4), detail: text(s, 5) ?? "",
                                       dedupKey: text(s, 6) ?? ""))
        }
        sqlite3_finalize(s)
        return result
    }

    var fileSize: Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
