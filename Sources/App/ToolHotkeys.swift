import AppKit
import Carbon

final class ToolHotkeys {
    var onInvoke: ((QuickTool) -> Void)?
    private var handler: EventHandlerRef?
    private var hotkeys: [EventHotKeyRef] = []
    private var actions: [UInt32: QuickTool] = [:]

    func register(_ entries: [ToolEntry]) -> [QuickTool: String] {
        stop()
        let enabled = entries.filter { $0.enabled && $0.shortcut != nil }
        guard !enabled.isEmpty else { return [:] }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ToolHotkeys>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, let tool = owner.actions[identifier.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { [weak owner] in owner?.onInvoke?(tool) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            return Dictionary(uniqueKeysWithValues: enabled.map { ($0.tool, L10n.text("无法注册快捷键监听。")) })
        }
        var errors: [QuickTool: String] = [:]
        for (index, entry) in enabled.enumerated() {
            guard let shortcut = entry.shortcut, shortcut.isValid else { continue }
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x5A53544B, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotkeys.append(reference); actions[id] = entry.tool }
            else { errors[entry.tool] = L10n.text("快捷键被系统或其他应用占用，请重新设置。") }
        }
        return errors
    }

    func stop() {
        hotkeys.forEach { UnregisterEventHotKey($0) }; hotkeys.removeAll(); actions.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit { stop() }
}

final class DockLock {
    var onStop: ((String) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var displays: [CGRect] = []
    private var ids: [CGDirectDisplayID] = []
    private var lockedID: CGDirectDisplayID = 0
    private var orientation = "bottom"
    private var observer: NSObjectProtocol?

    func start(displayID: UInt32) throws {
        stop()
        ids = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        lockedID = displayID == 0 ? CGMainDisplayID() : displayID
        guard ids.count > 1, ids.contains(lockedID) else {
            throw NSError(domain: "Zest.Tools", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("所选显示器不可用，请在快捷工具设置中重新选择。")])
        }
        displays = ids.map { CGDisplayBounds($0) }
        orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<DockLock>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { [weak owner] in
                    owner?.stop(); owner?.onStop?(L10n.text("Dock 锁定已被系统暂停，请重新开启。"))
                }
                return Unmanaged.passUnretained(event)
            }
            guard let index = owner.ids.firstIndex(of: owner.lockedID) else { return Unmanaged.passUnretained(event) }
            let adjusted = DockEdgeGuard.adjusted(event.location, displays: owner.displays, lockedIndex: index, orientation: owner.orientation)
            if adjusted != event.location { event.location = adjusted; CGWarpMouseCursorPosition(adjusted) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            throw NSError(domain: "Zest.Tools", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("无法启用 Dock 锁定，请检查辅助功能权限。")])
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(); self?.onStop?(L10n.text("显示器配置已变化，Dock 锁定已关闭，请确认目标屏幕后重新开启。"))
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        tap = nil; source = nil; observer = nil
    }

    deinit { stop() }
}
