import Foundation

/// 本地性能诊断：复用已有 CPU 采样，不另开轮询器；异步写入、限频、滚动保存。
final class PerformanceLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Zest", isDirectory: true)
    static let shared = PerformanceLog(directory: directory,
                                       role: CommandLine.arguments.contains("--network-window") ? "network" : "main",
                                       enabled: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)

    private let queue = DispatchQueue(label: "app.zest.performance-log", qos: .utility)
    private let directory: URL
    private let role: String
    private let maxBytes: Int
    private let enabled: Bool
    private let pid = getpid()
    private let session = UUID().uuidString
    private let formatter = ISO8601DateFormatter()
    private var bytes = 0
    private var handle: FileHandle?
    private var failed = false
    private var lastSummary: TimeInterval = 0
    private var lastSpike: TimeInterval = -.infinity
    private var lastSlow: [String: TimeInterval] = [:]
    private var cpuTotal = 0.0
    private var cpuPeak = 0.0
    private var samples = 0

    init(directory: URL, role: String, maxBytes: Int = 2 * 1024 * 1024, enabled: Bool = true) {
        self.directory = directory
        self.role = role
        self.maxBytes = maxBytes
        self.enabled = enabled
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func event(_ name: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        queue.async { self.write(name, fields) }
    }

    func sample(_ usage: SelfUsage, panelVisible: Bool, tab: String, refreshInterval: Double) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        queue.async {
            self.samples += 1
            self.cpuTotal += usage.cpu
            self.cpuPeak = max(self.cpuPeak, usage.cpu)
            var fields: [String: Any] = ["cpu_percent": usage.cpu * 100,
                "memory_mib": Double(usage.memory) / 1_048_576, "panel_visible": panelVisible,
                "tab": tab, "refresh_seconds": refreshInterval]
            if let own = usage.processCPU { fields["cpu_self_percent"] = own * 100 }
            if let children = usage.childCPU { fields["cpu_children_percent"] = children * 100 }
            if usage.cpu >= 0.05 && now - self.lastSpike >= 5 {
                self.lastSpike = now
                self.write("cpu_spike", fields)
            }
            if now - self.lastSummary >= 30 {
                fields["cpu_average_percent"] = self.cpuTotal / Double(self.samples) * 100
                fields["cpu_peak_percent"] = self.cpuPeak * 100
                fields["samples"] = self.samples
                self.write("health", fields)
                self.lastSummary = now
                self.samples = 0; self.cpuTotal = 0; self.cpuPeak = 0
            }
        }
    }

    /// 只记录超过阈值的阶段；同一阶段最多每 5 秒一条。
    func timing(_ stage: String, since start: UInt64, thresholdMS: Double = 20, fields: [String: Any] = [:]) {
        guard enabled else { return }
        let duration = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6
        guard duration >= thresholdMS else { return }
        let now = ProcessInfo.processInfo.systemUptime
        queue.async {
            guard now - (self.lastSlow[stage] ?? -.infinity) >= 5 else { return }
            self.lastSlow[stage] = now
            var details = fields
            details["stage"] = stage
            details["duration_ms"] = duration
            self.write("slow_stage", details)
        }
    }

    func flush() { queue.sync {} }

    private var currentURL: URL { directory.appendingPathComponent("performance-\(role).jsonl") }

    private func open() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: currentURL.path) {
            guard FileManager.default.createFile(atPath: currentURL.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: currentURL)
        bytes = Int(try handle!.seekToEnd())
    }

    private func rotate() throws {
        try handle?.close(); handle = nil
        let fm = FileManager.default
        let previous = directory.appendingPathComponent("performance-\(role).1.jsonl")
        if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
        try fm.moveItem(at: currentURL, to: previous)
        bytes = 0
        try open()
    }

    private func write(_ event: String, _ fields: [String: Any]) {
        guard !failed else { return }
        var row = fields
        row["timestamp"] = formatter.string(from: Date())
        row["event"] = event
        row["pid"] = pid
        row["role"] = role
        row["session"] = session
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              data.count + 1 <= maxBytes else { return }
        data.append(0x0a)
        do {
            if handle == nil { try open() }
            if bytes + data.count > maxBytes { try rotate() }
            try handle?.write(contentsOf: data)
            bytes += data.count
        } catch {
            // 写入失败时停用本次会话的日志，不反复重试消耗 CPU。
            failed = true
            try? handle?.close(); handle = nil
        }
    }

    deinit { try? handle?.close() }
}
