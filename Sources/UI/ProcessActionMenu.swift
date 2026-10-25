//
//  ProcessActionMenu.swift
//  Zest
//
//  进程操作使用原生菜单：菜单项写明目标名称，并在弹出时锁定目标，
//  即使列表随后刷新重排，也不会作用到其他应用。
//

import AppKit

final class ProcessActionMenu: NSObject {
    static let shared = ProcessActionMenu()
    private var actions: [() -> Void] = []

    func show(for app: AppUsage, monitor: ProcessMonitor) {
        let menu = NSMenu()
        actions = []
        if app.isProtected {
            let info = NSMenuItem(title: app.processes.contains { $0.pid == getpid() } ? L10n.text("Zest 自身") : L10n.text("系统关键进程，不提供结束操作"),
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        } else {
            add(to: menu, String(format: L10n.text("退出“%@”"), app.name), symbol: "xmark.circle") { monitor.quit(app) }
            add(to: menu, String(format: L10n.text("强制退出“%@”…"), app.name), symbol: "bolt.circle") { monitor.requestForceQuit(.app(app)) }
        }
        menu.addItem(.separator())
        add(to: menu, L10n.text("在访达中显示"), symbol: "folder") { monitor.revealInFinder(app) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func show(for process: ProcessUsage, protected: Bool, monitor: ProcessMonitor) {
        let menu = NSMenu()
        actions = []
        if protected || process.pid == getpid() {
            let info = NSMenuItem(title: L10n.text("此进程不提供结束操作"), action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        } else {
            add(to: menu, String(format: L10n.text("结束进程 %@（%lld）"), process.name, Int64(process.pid)), symbol: "xmark.circle") {
                monitor.terminate(pid: process.pid, force: false)
            }
            add(to: menu, L10n.text("强制结束…"), symbol: "bolt.circle") { monitor.requestForceQuit(.process(process)) }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func add(to menu: NSMenu, _ title: String, symbol: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        actions.append(action)
        menu.addItem(item)
    }

    @objc private func run(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        actions[item.tag]()
    }
}
