//
//  ProcessMonitor.swift
//  Zest
//
//  进程占用的数据源与结束操作。仅在概览/进程页可见时每 3 秒采集一次。
//

import AppKit

/// 等待用户确认的强制结束目标。
enum ForceQuitTarget: Equatable {
    case app(AppUsage)
    case process(ProcessUsage)

    var title: String {
        switch self {
        case .app(let a): return String(format: L10n.text("强制退出“%@”？"), a.name)
        case .process(let p): return String(format: L10n.text("强制结束进程 %@（PID %lld）？"), p.name, Int64(p.pid))
        }
    }
}

final class ProcessMonitor: ObservableObject {
    @Published private(set) var reading: ProcessesReading?
    /// 强制结束前需在面板底部确认；目标在打开菜单时即已锁定，不受列表刷新影响。
    @Published var pendingForceQuit: ForceQuitTarget?

    private let queue = DispatchQueue(label: "app.zest.processes", qos: .utility)
    private lazy var sampler = ProcessSampler()
    private var timer: DispatchSourceTimer?
    let interval: TimeInterval = 3
    private var knownPIDs: Set<pid_t>?

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            // 立即采一次（内存可用），1 秒后建立 CPU 差值，之后每 3 秒。
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(300))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        guard timer != nil else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let r = sampler.sample()
        PerformanceLog.shared.timing("process_sample", since: started,
                                    fields: ["apps": r.apps.count, "inaccessible": r.inaccessibleProcesses])
        let current = Set(r.apps.flatMap { $0.processes.map(\.pid) })
        if let knownPIDs {
            let removed = knownPIDs.subtracting(current)
            let added = current.subtracting(knownPIDs)
            if !removed.isEmpty || !added.isEmpty {
                PerformanceLog.shared.event("process_set_changed", ["removed_count": removed.count,
                    "added_count": added.count, "removed_pids": Array(removed.sorted().prefix(20))])
            }
        }
        knownPIDs = current
        DispatchQueue.main.async { self.reading = r }
    }

    /// 结束后尽快刷新列表。
    private func refreshSoon() {
        queue.async { [self] in
            // 合并连续退出请求，并移动下一次定时采样，避免额外采样与原定时器挤在一起。
            timer?.schedule(deadline: .now() + 0.8, repeating: interval, leeway: .milliseconds(300))
        }
    }

    // MARK: 结束进程

    /// 正常退出：对应用发送“退出”（应用可提示保存）；命令行进程发送 SIGTERM。
    func quit(_ app: AppUsage) {
        guard !app.isProtected else { return }
        PerformanceLog.shared.event("quit_requested", ["target_pids": app.processes.map(\.pid)])
        if let running = runningApplication(for: app) {
            running.terminate()
        } else {
            app.processes.forEach { kill($0.pid, SIGTERM) }
        }
        refreshSoon()
    }

    /// 强制退出：等同“活动监视器”的强制退出，未保存的内容会丢失。
    func forceQuit(_ app: AppUsage) {
        guard !app.isProtected else { return }
        PerformanceLog.shared.event("force_quit_requested", ["target_pids": app.processes.map(\.pid)])
        runningApplication(for: app)?.forceTerminate()
        app.processes.forEach { kill($0.pid, SIGKILL) }
        refreshSoon()
    }

    func requestForceQuit(_ target: ForceQuitTarget) { pendingForceQuit = target }

    func confirmForceQuit() {
        guard let target = pendingForceQuit else { return }
        pendingForceQuit = nil
        switch target {
        case .app(let a): forceQuit(a)
        case .process(let p): terminate(pid: p.pid, force: true)
        }
    }

    func terminate(pid: pid_t, force: Bool) {
        guard pid != getpid() else { return }
        PerformanceLog.shared.event("process_quit_requested", ["target_pid": pid, "force": force])
        kill(pid, force ? SIGKILL : SIGTERM)
        refreshSoon()
    }

    private func runningApplication(for app: AppUsage) -> NSRunningApplication? {
        guard let bundlePath = app.bundlePath else { return nil }
        let pids = Set(app.processes.map(\.pid))
        return NSWorkspace.shared.runningApplications.first {
            pids.contains($0.processIdentifier) && $0.bundleURL?.standardizedFileURL.path == bundlePath
        }
    }

    func revealInFinder(_ app: AppUsage) {
        let path = app.bundlePath ?? app.processes.first.flatMap { ProcessOwners.path($0.pid) }
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
