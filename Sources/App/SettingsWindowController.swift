//
//  SettingsWindowController.swift
//  Zest
//

import AppKit
import Combine
import Sparkle
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var languageCancellable: AnyCancellable?

    convenience init(settings: AppSettings, network: NetworkMonitor? = nil, updater: SPUUpdater? = nil, tools: QuickToolsController? = nil) {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, network: network, updater: updater, tools: tools))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        window.title = L10n.text("Zest 设置")
        // L10n.use 在 appLanguage 的 didSet 里，而 $appLanguage 在 didSet 之前发出。
        languageCancellable = settings.$appLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.window?.title = L10n.text("Zest 设置")
            }
    }

    func present() {
        // 菜单栏应用默认是 accessory，打开设置时临时变成常规应用以便窗口获得焦点。
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MemoryRelief.releaseFreePages()
    }
}
