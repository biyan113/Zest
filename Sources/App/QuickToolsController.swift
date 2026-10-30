import AppKit
import Combine
import IOKit.pwr_mgt

final class QuickToolsController: ObservableObject {
    @Published private(set) var active = Set<QuickTool>()
    @Published private(set) var busy = Set<QuickTool>()
    @Published var message: String?
    @Published private(set) var shortcutErrors: [QuickTool: String] = [:]
    @Published private(set) var awakeUntil: Date?
    @Published private(set) var clamshellUntil: Date?
    let settings: AppSettings
    var closePanel: () -> Void = {}

    private var assertion: IOPMAssertionID?
    private var awakeTimer: Timer?
    private var clamshellTimer: Timer?
    private var powerLease: URL?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private let hotkeys = ToolHotkeys()
    private let cleaner = ToolCleaner()
    private let dock = DockLock()
    private var stopped = false
    private var recordingShortcut = false

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        hotkeys.onInvoke = { [weak self] in self?.perform($0) }
        cleaner.onFinish = { [weak self] in self?.refresh() }
        dock.onStop = { [weak self] error in
            self?.active.remove(.lockDock)
            self?.message = error
        }
        settings.$toolEntries.receive(on: RunLoop.main).sink { [weak self] entries in
            guard let self else { return }
            if !recordingShortcut { shortcutErrors = hotkeys.register(entries) }
            let enabled = Set(entries.filter(\.enabled).map(\.tool))
            if !enabled.contains(.keepAwake), assertion != nil { toggleAwake() }
            if !enabled.contains(.clamshell) { stopClamshell() }
            if !enabled.contains(.lockDock) { dock.stop(); set(.lockDock, false) }
            if (cleaner.mode == .screen && !enabled.contains(.cleanScreen)) ||
                (cleaner.mode == .keyboard && !enabled.contains(.cleanKeyboard)) { cleaner.stop() }
        }.store(in: &subscriptions)
        settings.$dockDisplayID.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, active.contains(.lockDock) else { return }
            dock.stop(); active.remove(.lockDock)
        }.store(in: &subscriptions)
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        refresh()
    }

    func recordShortcut(_ recording: Bool) {
        guard !stopped else { return }
        recordingShortcut = recording
        if recording { hotkeys.stop() } else { shortcutErrors = hotkeys.register(settings.toolEntries) }
    }

    func assignShortcut(_ shortcut: ToolShortcut?, to tool: QuickTool) -> Bool {
        if let shortcut {
            guard shortcut.isValid else { message = L10n.text("快捷键需要包含 ⌘、⌥ 或 ⌃ 修饰键。"); return false }
            guard !settings.toolEntries.contains(where: { $0.tool != tool && $0.shortcut == shortcut }) else {
                message = L10n.text("此快捷键已分配给其他工具。"); return false
            }
        }
        guard let index = settings.toolEntries.firstIndex(where: { $0.tool == tool }) else { return false }
        settings.toolEntries[index].shortcut = shortcut
        return true
    }

    var hasLid: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() != nil
    }

    func refresh() {
        set(.darkMode, NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let hidden = (CFPreferencesCopyValue("_HIHideMenuBar" as CFString, kCFPreferencesAnyApplication,
                                             kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Bool) ??
            (CFPreferencesCopyValue("_HIHideMenuBar" as CFString, kCFPreferencesAnyApplication,
                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
        set(.hideMenuBar, hidden)
        set(.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled)
        set(.cleanScreen, cleaner.mode == .screen)
        set(.cleanKeyboard, cleaner.mode == .keyboard)
    }

    func status(_ tool: QuickTool) -> String {
        if busy.contains(tool) { return L10n.text("处理中…") }
        if tool == .clamshell && !hasLid { return L10n.text("此 Mac 无合盖功能") }
        if tool == .lockDock && NSScreen.screens.count < 2 { return L10n.text("需要多显示器") }
        if let until = tool == .keepAwake ? awakeUntil : (tool == .clamshell ? clamshellUntil : nil) {
            return String(format: L10n.text("剩余 %lld 分钟"), Int64(max(1, ceil(until.timeIntervalSinceNow / 60))))
        }
        return tool.isToggle ? (active.contains(tool) ? L10n.text("已开启") : L10n.text("tool.off", defaultValue: "已关闭")) : L10n.text("点按执行")
    }

    func perform(_ tool: QuickTool) {
        guard !stopped, !busy.contains(tool) else { return }
        message = nil
        refresh()
        switch tool {
        case .darkMode:
            script(tool, "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .hideMenuBar:
            script(tool, "tell application \"System Events\" to tell dock preferences to set autohide menu bar to not autohide menu bar")
        case .lockScreen:
            guard requestAccessibility() else { return }
            closePanel()
            // The documented system shortcut avoids obsolete CGSession and private loginwindow APIs.
            let flags: CGEventFlags = [.maskControl, .maskCommand]
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false)
            down?.flags = flags; up?.flags = flags
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        case .keepAwake: toggleAwake()
        case .screenSaver:
            closePanel()
            ToolProcess.run("/usr/bin/open", ["-a", "/System/Library/CoreServices/ScreenSaverEngine.app"]) { [weak self] result in
                if case .failure(let error) = result { self?.message = error.localizedDescription }
            }
        case .cleanScreen, .cleanKeyboard:
            if cleaner.mode != nil { cleaner.stop(); return }
            if tool == .cleanKeyboard && !requestAccessibility() { return }
            closePanel()
            do { try cleaner.start(tool == .cleanKeyboard ? .keyboard : .screen, seconds: settings.cleaningSeconds) }
            catch { message = error.localizedDescription }
            refresh()
        case .emptyTrash:
            closePanel()
            let alert = NSAlert()
            alert.messageText = L10n.text("清空废纸篓？")
            alert.informativeText = L10n.text("废纸篓中的项目将被永久删除，此操作无法撤销。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.text("取消"))
            alert.addButton(withTitle: L10n.text("清空废纸篓"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                script(tool, "tell application \"Finder\" to empty trash")
            }
        case .clamshell: toggleClamshell()
        case .lockDock:
            if active.contains(tool) { dock.stop(); set(tool, false); return }
            guard NSScreen.screens.count > 1 else { message = L10n.text("连接至少两台显示器后才能锁定 Dock。"); return }
            guard requestAccessibility() else { return }
            do { try dock.start(displayID: settings.dockDisplayID); set(tool, true) }
            catch { message = error.localizedDescription }
        case .lowPower:
            let value = active.contains(.lowPower) ? "0" : "1"
            let command = "/usr/bin/pmset -a lowpowermode " + value
            script(tool, "do shell script " + ToolCommand.appleScriptString(command) + " with administrator privileges")
        }
    }

    private func set(_ tool: QuickTool, _ enabled: Bool) {
        if enabled { active.insert(tool) } else { active.remove(tool) }
    }

    private func script(_ tool: QuickTool, _ source: String, finished: ((Bool) -> Void)? = nil) {
        busy.insert(tool)
        ToolProcess.run("/usr/bin/osascript", ["-e", source]) { [weak self] result in
            guard let self else { return }
            busy.remove(tool)
            switch result {
            case .success: finished?(true)
            case .failure(let error):
                message = error.localizedDescription + "\n" + L10n.text("若权限被拒绝，请在系统设置 › 隐私与安全性中检查自动化或辅助功能。")
                finished?(false)
            }
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
        }
    }

    private func requestAccessibility() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        closePanel()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        message = L10n.text("请在系统设置 › 隐私与安全性 › 辅助功能中允许 Zest，然后再次点击此工具。")
        return false
    }

    private func toggleAwake() {
        if let assertion {
            IOPMAssertionRelease(assertion)
            self.assertion = nil; awakeTimer?.invalidate(); awakeTimer = nil; awakeUntil = nil
            set(.keepAwake, false)
            return
        }
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Zest keep display awake" as CFString, &identifier)
        guard result == kIOReturnSuccess else { message = L10n.text("无法创建保持亮屏会话。"); return }
        assertion = identifier; set(.keepAwake, true)
        if settings.awakeMinutes > 0 {
            awakeUntil = Date().addingTimeInterval(Double(settings.awakeMinutes) * 60)
            awakeTimer = Timer.scheduledTimer(withTimeInterval: Double(settings.awakeMinutes) * 60, repeats: false) { [weak self] _ in self?.toggleAwake() }
        }
    }

    private func toggleClamshell() {
        if active.contains(.clamshell) { stopClamshell(); return }
        guard hasLid else { message = L10n.text("此 Mac 没有合盖功能。"); return }
        guard let helper = Bundle.main.url(forResource: "PowerSession", withExtension: "sh") else {
            message = L10n.text("缺少电源会话脚本，请重新构建应用。"); return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zest-power-" + UUID().uuidString)
        let lease = directory.appendingPathComponent("lease")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: lease, options: .atomic)
        } catch { message = error.localizedDescription; return }
        powerLease = lease
        let command = "/bin/sh " + ToolCommand.shellQuote(helper.path) + " " + String(getpid()) + " " + ToolCommand.shellQuote(lease.path)
        script(.clamshell, "do shell script " + ToolCommand.appleScriptString(command) + " with administrator privileges") { [weak self] succeeded in
            guard let self else { return }
            guard succeeded, !stopped, powerLease == lease,
                  settings.toolEntries.contains(where: { $0.tool == .clamshell && $0.enabled }) else { stopClamshell(); return }
            set(.clamshell, true)
            if settings.awakeMinutes > 0 {
                clamshellUntil = Date().addingTimeInterval(Double(settings.awakeMinutes) * 60)
                clamshellTimer = Timer.scheduledTimer(withTimeInterval: Double(settings.awakeMinutes) * 60, repeats: false) { [weak self] _ in self?.stopClamshell() }
            }
        }
    }

    private func stopClamshell() {
        clamshellTimer?.invalidate(); clamshellTimer = nil; clamshellUntil = nil
        if let lease = powerLease {
            try? FileManager.default.removeItem(at: lease)
            try? FileManager.default.removeItem(at: lease.deletingLastPathComponent())
        }
        powerLease = nil; set(.clamshell, false)
    }

    func stop() {
        stopped = true
        hotkeys.stop(); cleaner.stop(); dock.stop(); stopClamshell()
        if assertion != nil { toggleAwake() }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll(); subscriptions.removeAll()
    }
}

enum ToolProcess {
    static func run(_ executable: String, _ arguments: [String], completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            let result: Result<String, Error>
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0 { result = .success(text) }
                else { result = .failure(NSError(domain: "Zest.Tools", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? L10n.text("系统操作未完成。") : text])) }
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
