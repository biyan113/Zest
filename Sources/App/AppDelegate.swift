//
//  AppDelegate.swift
//  Zest
//

import AppKit
import Combine
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let store = MonitorStore()
    private let engine = MonitorEngine()
    private lazy var network = NetworkMonitor(settings: settings, role: AppDelegate.isNetworkViewer ? .viewer : .primary)
    private(set) var networkWindow: NetworkWindowController?
    /// 独立的“网络监控”窗口进程。
    private var viewerProcess: Process?
    private var parentWatcher: DispatchSourceProcess?
    private let processes = ProcessMonitor()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    /// 只在菜单栏进程启动。网络窗口进程与测试进程不检查更新。
    private var updaterController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()
    private var screensAsleep = false
    private var applicationExitObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?

    static var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// 以 `--network-window` 启动时作为独立的“网络监控”窗口进程运行：
    /// 不创建菜单栏图标，窗口关闭即退出，从而把 SwiftUI / 图表占用的内存完整归还系统。
    static let isNetworkViewer = CommandLine.arguments.contains("--network-window")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppDelegate.isRunningTests else { return }
        observeLanguageChanges()
        PerformanceLog.shared.event("start", ["refresh_seconds": settings.refreshInterval,
            "network_monitoring": settings.networkMonitoring,
            "process_refresh_seconds": processes.interval,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"])
        if AppDelegate.isNetworkViewer {
            launchAsNetworkViewer()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        // 网络监控窗口进程修改了告警或忽略规则：重新加载。
        DistributedNotificationCenter.default().addObserver(
            forName: NetworkMonitor.alertsChangedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.settings.reloadSuppressions()
            self?.network.reloadAlertsFromStore()
        }

        statusItem = StatusItemController(store: store, settings: settings, network: network, processes: processes,
                                          openSettings: { [weak self] in self?.openSettings() },
                                          openNetworkWindow: { [weak self] in self?.openNetworkWindow() })
        statusItem?.onPanelVisibilityChange = { [weak self] visible in
            guard let self else { return }
            if visible && UserDefaults.standard.string(forKey: "panelTab") != "processes" { engine.refreshCapacity() }
            PerformanceLog.shared.event("panel_visibility", ["visible": visible])
            updateSampleOptions()
        }
        statusItem?.onPanelTabChange = { [weak self] _ in self?.updateSampleOptions() }

        store.setCoreKinds(engine.coreKinds)
        engine.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            store.ingest(snapshot)
            statusItem?.update(snapshot: snapshot)
            if let usage = snapshot.selfUsage {
                PerformanceLog.shared.sample(usage, panelVisible: store.isPanelVisible,
                    tab: UserDefaults.standard.string(forKey: "panelTab") ?? "overview",
                    refreshInterval: settings.refreshInterval)
            }
        }
        updateSampleOptions()
        engine.start(interval: settings.refreshInterval)
        network.start()
        settings.$networkMonitoring.dropFirst().removeDuplicates().sink { [weak self] on in
            on ? self?.network.start() : self?.network.stop()
        }.store(in: &cancellables)

        #if PERFORMANCE_TEST
        if CommandLine.arguments.contains("--performance-panel") {
            performancePanelPreference = UserDefaults.standard.object(forKey: "panelTab")
            isPerformanceRun = true
            UserDefaults.standard.set("processes", forKey: "panelTab")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                statusItem?.debugShowPanel()
                print("PERFORMANCE_PANEL visible=\(store.isPanelVisible)")
                fflush(stdout)
            }
        }
        #endif

        #if DEBUG
        if ProcessInfo.processInfo.environment["ZEST_DEBUG_LAYOUT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in statusItem?.debugShowPanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
        }
        if ProcessInfo.processInfo.environment["ZEST_DEBUG_WINDOW_CYCLE"] != nil {
            // 打开网络监控窗口 20 秒后关闭，再观察 20 秒，用于检查关闭后内存是否回落。
            func footprint() -> String {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
                _ = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                return "\(info.phys_footprint / 1_048_576) MB"
            }
            print("启动后: \(footprint())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
                print("打开窗口前（菜单栏进程）: \(footprint())")
                openNetworkWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
                    print("窗口打开 20 秒（菜单栏进程）: \(footprint())，窗口进程 pid \(viewerProcess?.processIdentifier ?? 0)")
                    viewerProcess?.terminate()
                    for delay in [2.0, 10, 45] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            print("关闭后 \(Int(delay)) 秒: \(footprint())")
                            if delay == 45 { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["ZEST_DEBUG_NETWORK_WINDOW"] {
            presentNetworkWindowInProcess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [self] in
                SnapshotExporter.captureWindows(to: URL(fileURLWithPath: dir), page: networkWindow)
                NSApp.terminate(nil)
            }
        }
        if let dir = SnapshotExporter.outputDirectory {
            UserDefaults.standard.set("overview", forKey: "panelTab")
            store.isPanelVisible = true
            updateSampleOptions()
            network.setVisible(true)
            processes.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [self] in
                SnapshotExporter.export(store: store, settings: settings, network: network, processes: processes, to: dir)
                NSApp.terminate(nil)
            }
        }
        #endif

        settings.$refreshInterval.dropFirst().removeDuplicates().sink { [weak self] interval in
            guard let self, !screensAsleep else { return }
            engine.start(interval: interval)
        }.store(in: &cancellables)

        Publishers.Merge(settings.$menuBarEntries.map { _ in () },
                         settings.$temperatureUnit.map { _ in () })
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                updateSampleOptions()
                statusItem?.forceRedraw(snapshot: store.snapshot)
            }.store(in: &cancellables)

        // 菜单栏图片按上一帧内容缓存；语言变化时必须强制重画，不能另起定时器。
        settings.$appLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                statusItem?.forceRedraw(snapshot: store.snapshot)
            }.store(in: &cancellables)

        // 屏幕休眠/锁屏时暂停采样，节省电量。
        let ws = NSWorkspace.shared.notificationCenter
        applicationExitObserver = ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                  object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            PerformanceLog.shared.event("application_exit", ["target_pid": app.processIdentifier,
                "bundle_id": app.bundleIdentifier ?? "unknown"])
        }
        ws.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// 菜单栏进程和网络窗口进程都订阅。收到后重新读取语言，@Published 会刷新 SwiftUI。
    private func observeLanguageChanges() {
        guard languageObserver == nil else { return }
        languageObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppSettings.languageChangedNotification, object: nil, queue: .main) { [weak self] note in
                self?.settings.reloadLanguage(note)
            }
    }

    /// 只有菜单栏显示温度/风扇或面板打开时才读取 SMC。
    private func updateSampleOptions() {
        let overviewVisible = store.isPanelVisible &&
            (UserDefaults.standard.string(forKey: "panelTab") ?? "overview") == "overview"
        let needsSensors = overviewVisible || settings.enabledItems.contains { $0.needsSensors }
        engine.setOptions(SampleOptions(sensors: needsSensors))
    }

    @objc private func screensDidSleep() {
        guard !screensAsleep else { return }
        screensAsleep = true
        engine.stop()
    }

    @objc private func screensDidWake() {
        guard screensAsleep else { return }
        screensAsleep = false
        store.resetHistory()
        engine.start(interval: settings.refreshInterval)
    }

    #if PERFORMANCE_TEST
    private var performancePanelPreference: Any?
    private var isPerformanceRun = false
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        #if PERFORMANCE_TEST
        if isPerformanceRun {
            if let performancePanelPreference {
                UserDefaults.standard.set(performancePanelPreference, forKey: "panelTab")
            } else {
                UserDefaults.standard.removeObject(forKey: "panelTab")
            }
        }
        #endif
        network.flushSync()
        network.stop()
        viewerProcess?.terminate()
        PerformanceLog.shared.event("stop")
        PerformanceLog.shared.flush()
    }

    /// 打开网络监控：启动（或激活已在运行的）独立窗口进程。
    private func openNetworkWindow() {
        if let running = viewerProcess, running.isRunning {
            NSRunningApplication(processIdentifier: running.processIdentifier)?.activate(options: [.activateAllWindows])
            return
        }
        guard let executable = Bundle.main.executableURL else { return }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["--network-window"]
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.viewerProcess = nil
                self?.engine.setChildProcesses([])
                self?.settings.reloadSuppressions()
                self?.network.reloadAlertsFromStore()
                self?.network.markAlertsRead()
            }
        }
        do {
            try task.run()
            viewerProcess = task
            engine.setChildProcesses([task.processIdentifier])
        } catch {
            // 无法启动独立进程时退回到本进程内打开。
            presentNetworkWindowInProcess()
        }
    }

    private func presentNetworkWindowInProcess() {
        if networkWindow == nil { networkWindow = NetworkWindowController(monitor: network, settings: settings) }
        networkWindow?.present()
    }

    // MARK: 网络监控窗口进程

    private func launchAsNetworkViewer() {
        NSApp.setActivationPolicy(.regular)
        network.start()
        let controller = NetworkWindowController(monitor: network, settings: settings)
        controller.onClose = { NSApp.terminate(nil) }
        networkWindow = controller
        controller.present()
        // 菜单栏主进程退出时随之退出，不残留窗口进程。
        let parent = getppid()
        let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        watcher.setEventHandler { NSApp.terminate(nil) }
        watcher.resume()
        parentWatcher = watcher
        if parent == 1 && ProcessInfo.processInfo.environment["ZEST_DEBUG_NETWORK_WINDOW"] == nil { NSApp.terminate(nil) }
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["ZEST_DEBUG_NETWORK_WINDOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [self] in
                SnapshotExporter.captureWindows(to: URL(fileURLWithPath: dir), page: networkWindow)
                NSApp.terminate(nil)
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppDelegate.isNetworkViewer
    }

    private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, network: network, updater: updaterController?.updater)
        }
        settingsWindow?.present()
    }
}
