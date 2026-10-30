import AppKit
import SwiftUI

final class ToolCleaner: ObservableObject {
    enum Mode { case screen, keyboard }
    @Published private(set) var secondsLeft = 0
    @Published private(set) var mode: Mode?
    var onFinish: (() -> Void)?
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var deadline = Date()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    func start(_ mode: Mode, seconds: Int) throws {
        stop()
        if mode == .keyboard {
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ToolCleaner>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async { [weak owner] in owner?.stop() }
                    return Unmanaged.passUnretained(event)
                }
                // Emergency exit still works while ordinary keys are blocked.
                if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 &&
                    event.flags.contains([.maskControl, .maskAlternate, .maskCommand]) {
                    DispatchQueue.main.async { [weak owner] in owner?.stop() }
                }
                return nil
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else {
                throw NSError(domain: "Zest.Tools", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.text("无法屏蔽键盘输入，请检查辅助功能权限。")])
            }
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        self.mode = mode
        secondsLeft = min(max(seconds, 15), 300)
        deadline = Date().addingTimeInterval(Double(secondsLeft))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.stop(); return nil }
            return event
        }
        for screen in NSScreen.screens {
            let window = CleaningWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.contentView = NSHostingView(rootView: CleaningView(cleaner: self))
            window.setFrame(screen.frame, display: false)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            secondsLeft = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            if secondsLeft == 0 { stop() }
        }
        // A newly attached monitor must not remain exposed while keyboard input is suppressed.
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        tap = nil; source = nil; keyMonitor = nil; screenObserver = nil
        windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll()
        let wasRunning = mode != nil
        mode = nil
        if wasRunning { onFinish?() }
    }

    deinit { stop() }
}

private final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct CleaningView: View {
    @ObservedObject var cleaner: ToolCleaner

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                Image(systemName: cleaner.mode == .keyboard ? "keyboard" : "sparkles")
                    .font(.system(size: 36, weight: .light))
                Text(cleaner.mode == .keyboard ? L10n.text("键盘清洁中") : L10n.text("屏幕清洁中"))
                    .font(.system(size: 22, weight: .medium))
                Text(String(format: L10n.text("%lld 秒后自动退出"), Int64(cleaner.secondsLeft)))
                    .monospacedDigit()
                Text(cleaner.mode == .keyboard ? L10n.text("普通按键已屏蔽。紧急退出：⌃⌥⌘ Esc") : L10n.text("按 Esc 或点击下方按钮退出。"))
                    .font(.system(size: 13))
                Button(L10n.text("退出清洁模式")) { cleaner.stop() }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(40)
        }
        .ignoresSafeArea()
    }
}
