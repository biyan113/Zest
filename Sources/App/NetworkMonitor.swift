//
//  NetworkMonitor.swift
//  Zest
//
//  网络监控服务：定时运行一次 /usr/bin/nettop（后台每 8 秒、界面可见时每 2 秒），
//  驱动流量追踪、异常检测与局域网刷新。
//
//  不使用 nettop 的常驻日志模式（-L 0）：实测它会持续处理系统网络统计事件，
//  无论 -s 设多大都占用约 60% 单核；单次运行（-L 1）约 17ms CPU。
//

import AppKit
import Network
import UserNotifications

enum NetworkMonitorStatus: Equatable {
    case stopped, starting, running
    case failed(String)
}

enum LANAccess: Equatable { case unknown, granted, denied }

/// 来自持久化存储的 24 小时汇总。
struct HistorySummary: Equatable {
    static let bucketMinutes = 10
    /// 最近 24 小时，每 10 分钟一个桶（共 145 个，最后一个为当前时段）。
    var day: [TrafficPoint] = []
    var dayStartMinute = 0
    var apps: [AppDayTotal] = []
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var storeSize: Int64 = 0
}

final class NetworkMonitor: ObservableObject {
    /// primary：菜单栏主进程，负责采集、告警检测与历史写入。
    /// viewer：独立的“网络监控”窗口进程，只做展示（实时数据自行采集，历史与告警从数据库读取）。
    enum Role { case primary, viewer }

    /// 跨进程通知：查看器修改了告警或忽略规则，主进程据此重新加载。
    static let alertsChangedNotification = Notification.Name("app.zest.monitor.alertsChanged")

    @Published private(set) var state = NetworkState()
    @Published private(set) var alerts: [NetworkAlert] = []
    @Published private(set) var devices: [LANDevice] = []
    @Published private(set) var score = PrivacyScore(score: 100, factors: [])
    @Published private(set) var status = NetworkMonitorStatus.stopped
    @Published private(set) var lanAccess = LANAccess.unknown
    @Published private(set) var unreadWarnings = 0
    @Published private(set) var hostnames: [String: String] = [:]
    @Published private(set) var history = HistorySummary()
    /// 按需加载的单个应用 24 小时曲线。
    @Published private(set) var appDay: [String: [TrafficPoint]] = [:]

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "app.zest.network", qos: .utility)
    private let tracker = NetworkTracker()
    private let performanceSampler = SelfUsageSampler()
    private var store: HistoryStore?
    private var storeOpened = false
    private let detector = AnomalyDetector()
    private let lan = LANScanner()
    private var timer: DispatchSourceTimer?
    private var interval: Int = NetworkMonitor.backgroundInterval
    static let backgroundInterval = 8
    static let foregroundInterval = 2
    private var lastLANScan: Date = .distantPast
    private var visibleClients = 0
    /// 仅在采集队列上读写。
    private var enabled = false
    private var lanBrowser: NWBrowser?
    private let resolver = HostResolver()
    let role: Role
    private var tickCount = 0

    static let maxAlerts = 300

    init(settings: AppSettings, role: Role = .primary) {
        self.settings = settings
        self.role = role
        if role == .viewer { interval = NetworkMonitor.foregroundInterval; visibleClients = 1 }
        resolver.onResolved = { [weak self] ip, name in
            DispatchQueue.main.async { self?.hostnames[ip] = name }
        }
    }

    // MARK: 生命周期

    func start() {
        guard role == .viewer || settings.networkMonitoring else { return }
        queue.async {
            self.enabled = true
            self.openStore()
            self.schedule()
        }
    }

    // MARK: 持久化（串行队列）

    static func minute(_ date: Date = Date()) -> Int { Int(date.timeIntervalSince1970 / 60) }

    private func openStore() {
        guard !storeOpened else { return }
        storeOpened = true
        store = HistoryStore()
        guard let store else { return }
        let now = NetworkMonitor.minute()
        store.prune(nowMinute: now)
        tracker.preload(perApp: store.appMinutes(sinceMinute: now - NetworkTracker.minuteCapacity), nowMinute: now)
        tracker.onMinuteCompleted = { [weak self] minute, traffic, meta in
            guard let self, let store = self.store else { return }
            // 历史只由主进程写入；查看器只读，避免重复计入。
            guard self.role == .primary else { return }
            store.addMinute(minute, traffic: traffic, meta: meta)
            store.prune(nowMinute: minute + 1)
            self.refreshHistory()
        }
        let restored = store.alerts(since: Date().addingTimeInterval(-Double(HistoryStore.retentionMinutes * 60)))
        detector.restore(from: restored)
        DispatchQueue.main.async { if self.alerts.isEmpty { self.alerts = restored } }
        refreshHistory()
    }

    private func refreshHistory() {
        guard let store else { return }
        let now = NetworkMonitor.minute()
        let bucket = HistorySummary.bucketMinutes
        let start = (now - HistoryStore.retentionMinutes) / bucket * bucket
        let day = store.totals(sinceMinute: start, untilMinute: now, bucket: bucket)
        let apps = store.appTotals(sinceMinute: now - HistoryStore.retentionMinutes)
        let summary = HistorySummary(day: day, dayStartMinute: start, apps: apps,
                                     bytesIn: apps.reduce(0) { $0 &+ $1.bytesIn }, bytesOut: apps.reduce(0) { $0 &+ $1.bytesOut },
                                     storeSize: store.fileSize)
        DispatchQueue.main.async { self.history = summary }
    }

    /// 加载某个应用最近 24 小时的曲线（10 分钟一个桶）。
    func loadAppHistory(_ key: String) {
        queue.async { [self] in
            guard let store else { return }
            let now = NetworkMonitor.minute()
            let bucket = HistorySummary.bucketMinutes
            let start = (now - HistoryStore.retentionMinutes) / bucket * bucket
            let series = store.totals(sinceMinute: start, untilMinute: now, bucket: bucket, appKey: key)
            DispatchQueue.main.async { self.appDay[key] = series }
        }
    }

    /// 退出前同步写入未满一分钟的数据（异步写入可能来不及在进程退出前执行）。
    func flushSync() {
        guard role == .primary else { return }
        queue.sync {
            if let (minute, traffic, meta) = tracker.takePartialMinute() {
                store?.addMinute(minute, traffic: traffic, meta: meta)
            }
        }
    }

    func clearHistory() {
        queue.async { [self] in
            store?.clearAll()
            refreshHistory()
            DispatchQueue.main.async { self.appDay.removeAll() }
        }
    }

    func stop() {
        queue.async { [self] in
            enabled = false
            timer?.cancel()
            timer = nil
            DispatchQueue.main.async { self.status = .stopped }
        }
    }

    /// 网络摘要或监控窗口可见时提高采样频率。
    func setVisible(_ visible: Bool) {
        guard role == .primary else { return }
        queue.async { [self] in
            visibleClients = max(0, visibleClients + (visible ? 1 : -1))
            let desired = visibleClients > 0 ? NetworkMonitor.foregroundInterval : NetworkMonitor.backgroundInterval
            guard desired != interval else { return }
            interval = desired
            if desired == NetworkMonitor.foregroundInterval {
                lastLANScan = .distantPast
                refreshHistory()
            }
            if enabled { schedule() }
        }
        if visible { markAlertsRead() }
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(interval), leeway: .milliseconds(interval * 100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        if status == .stopped { DispatchQueue.main.async { self.status = .starting } }
    }

    private func tick() {
        guard enabled else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            PerformanceLog.shared.timing("network_sample", since: started)
            if role == .viewer {
                PerformanceLog.shared.sample(performanceSampler.sample(), panelVisible: true,
                    tab: UserDefaults.standard.string(forKey: "networkPage") ?? "overview",
                    refreshInterval: Double(interval))
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-L", "1", "-x", "-n", "-t", "external", "-J", "state,bytes_in,bytes_out"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            DispatchQueue.main.async { self.status = .failed(String(format: L10n.text("无法运行 /usr/bin/nettop：%@"), error.localizedDescription)) }
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            DispatchQueue.main.async { self.status = .failed(String(format: L10n.text("nettop 退出码 %lld"), Int64(task.terminationStatus))) }
            return
        }
        let parser = NettopParser()
        var sample: NettopSample?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let s = parser.feed(line) { sample = s }
        }
        if let last = parser.flush() { sample = last }
        if let sample { process(sample) }
    }

    // MARK: 数据处理（串行队列）

    private func process(_ sample: NettopSample) {
        let now = Date()
        let newState = tracker.ingest(sample, date: now)
        let lanInterval: TimeInterval = visibleClients > 0 ? 10 : 60
        var newDevices: [LANDevice]?
        var lanHidden = false
        if now.timeIntervalSince(lastLANScan) >= lanInterval {
            lastLANScan = now
            newDevices = lan.scan(now: now)
            // 已连接网络（有默认网关）而 ARP 表为空：系统对本进程隐藏了局域网设备，即缺少“本地网络”权限。
            lanHidden = newDevices?.isEmpty == true && LANScanner.defaultGateway() != nil
        }
        let devicesForDetection = newDevices ?? currentDevices
        if let newDevices { currentDevices = newDevices }
        tickCount += 1
        var detected: [NetworkAlert] = []
        if role == .primary {
            detected = detector.evaluate(state: newState, devices: devicesForDetection, now: now)
        } else {
            // 查看器：告警由主进程检测并写入数据库，这里定期读取；历史汇总同理。
            if tickCount % 5 == 1 { reloadAlertsFromStore() }
            if tickCount % 15 == 1 { refreshHistory() }
        }
        let visible = visibleClients > 0
        DispatchQueue.main.async { [self] in
            let fresh = detected.filter { a in !settings.suppressions.contains { $0.matches(a) } }
            if settings.resolveHostnames {
                resolver.resolve(Set(newState.activeFlows.filter { $0.scope != .loopback }.compactMap { $0.remote?.address }))
            }
            state = newState
            status = .running
            if let newDevices {
                devices = newDevices
                if !newDevices.isEmpty { lanAccess = .granted } else if lanHidden { lanAccess = .denied }
            }
            if !fresh.isEmpty {
                queue.async { self.store?.addAlerts(fresh) }
                alerts.insert(contentsOf: fresh.reversed(), at: 0)
                if alerts.count > NetworkMonitor.maxAlerts { alerts.removeLast(alerts.count - NetworkMonitor.maxAlerts) }
                let warnings = fresh.filter { $0.kind.severity == .warning }
                if !visible { unreadWarnings += warnings.count }
                if settings.alertNotifications { warnings.forEach(notify) }
            }
            score = PrivacyScore.compute(state: newState, alerts: alerts)
        }
    }

    private var currentDevices: [LANDevice] = []

    // MARK: 告警管理

    func markAlertsRead() { DispatchQueue.main.async { self.unreadWarnings = 0 } }

    /// 从数据库重新加载 24 小时内的告警（查看器定期调用；主进程在收到跨进程通知时调用）。
    func reloadAlertsFromStore() {
        queue.async { [self] in
            guard let store else { return }
            let list = store.alerts(since: Date().addingTimeInterval(-Double(HistoryStore.retentionMinutes * 60)))
            DispatchQueue.main.async {
                if self.alerts != list { self.alerts = list }
            }
        }
    }

    func clearAlerts() {
        alerts.removeAll()
        unreadWarnings = 0
        queue.async { self.store?.deleteAlerts(); self.notifyOtherProcess() }
    }

    func suppress(_ rule: SuppressionRule) {
        if !settings.suppressions.contains(rule) { settings.suppressions.append(rule) }
        alerts.removeAll { rule.matches($0) }
        queue.async { self.store?.deleteAlerts(kind: rule.kind, appKey: rule.appKey); self.notifyOtherProcess() }
    }

    func unsuppress(_ rule: SuppressionRule) {
        settings.suppressions.removeAll { $0 == rule }
        notifyOtherProcess()
    }

    private func notifyOtherProcess() {
        guard role == .viewer else { return }
        DistributedNotificationCenter.default().postNotificationName(
            NetworkMonitor.alertsChangedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func notify(_ alert: NetworkAlert) {
        let content = UNMutableNotificationContent()
        content.title = "Zest · \(alert.kind.title)"
        content.body = alert.detail
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil))
    }

    static func requestNotificationPermission(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: 本地网络权限

    /// 未获授权时系统对本进程隐藏 ARP 表。浏览一次 Bonjour 服务会触发系统的“本地网络”授权提示。
    func requestLANAccess() {
        let browser = NWBrowser(for: .bonjour(type: "_services._dns-sd._udp", domain: "local."), using: .udp)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { DispatchQueue.main.async { self?.lanAccess = .denied } }
        }
        browser.start(queue: queue)
        lanBrowser = browser
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.lanBrowser?.cancel()
            self?.lanBrowser = nil
            self?.lastLANScan = .distantPast
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, devices.isEmpty else { return }
            lanAccess = .denied
        }
    }

    func rescanLAN() { queue.async { self.lastLANScan = .distantPast } }

    static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 可选的反向 DNS 解析（默认关闭：会向 DNS 服务器发送 PTR 查询）。结果缓存，最多 4 个并发。
final class HostResolver {
    private let queue = DispatchQueue(label: "app.zest.dns", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var known = Set<String>()
    private let semaphore = DispatchSemaphore(value: 4)
    var onResolved: ((String, String) -> Void)?

    func resolve(_ addresses: Set<String>) {
        lock.lock()
        let todo = addresses.subtracting(known)
        known.formUnion(todo)
        lock.unlock()
        for ip in todo {
            queue.async { [self] in
                semaphore.wait()
                defer { semaphore.signal() }
                if let name = HostResolver.reverse(ip) { onResolved?(ip, name) }
            }
        }
    }

    static func reverse(_ ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0
        else { return nil }
        return String(cString: host)
    }
}
