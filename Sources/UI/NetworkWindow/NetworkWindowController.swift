//
//  NetworkWindowController.swift
//  Zest
//
//  独立的“网络监控”窗口。关闭后释放整个视图层级。
//

import AppKit
import Combine
import SwiftUI

final class NetworkWindowController: NSWindowController, NSWindowDelegate {
    private let monitor: NetworkMonitor
    private let settings: AppSettings
    /// 独立窗口进程中：窗口关闭后退出进程。
    var onClose: (() -> Void)?
    private var languageCancellable: AnyCancellable?

    init(monitor: NetworkMonitor, settings: AppSettings) {
        self.monitor = monitor
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L10n.text("网络监控")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 980, height: 600)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ZestNetworkWindow")
        super.init(window: window)
        window.delegate = self
        // 标题栏隐藏，窗口菜单、调度中心和辅助功能仍读 title。
        languageCancellable = settings.$appLanguage.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.window?.title = L10n.text("网络监控")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        if window.contentViewController == nil {
            let frame = window.frame
            let hosting = NSHostingController(rootView: NetworkWindowView(monitor: monitor, settings: settings))
            // 默认 sizingOptions 会把窗口收缩到 SwiftUI 的理想尺寸；这里只让它约束最小尺寸。
            hosting.sizingOptions = [.minSize]
            window.contentViewController = hosting
            monitor.setVisible(true)
            if frame.width >= 980 && frame.height >= 600 {
                window.setFrame(frame, display: false)
            } else {
                window.setContentSize(NSSize(width: 1160, height: 740))
                window.center()
            }
        }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        monitor.setVisible(false)
        window?.contentViewController = nil
        if let onClose {
            onClose()
            return
        }
        MemoryRelief.releaseFreePages()
        if !NSApp.windows.contains(where: { $0.isVisible && $0 !== window && $0.canBecomeMain }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
