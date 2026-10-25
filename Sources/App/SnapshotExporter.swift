//
//  SnapshotExporter.swift
//  Zest
//
//  仅 Debug：`Zest --render-snapshots <目录>` 采样数秒后把面板与菜单栏渲染为 PNG，用于界面回归检查。
//

#if DEBUG
import AppKit
import SwiftUI

enum SnapshotExporter {
    static var outputDirectory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--render-snapshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func export(store: MonitorStore, settings: AppSettings, network: NetworkMonitor, processes: ProcessMonitor, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = store.snapshot
        print("snapshot cpu=\(s?.cpu != nil) mem=\(s?.memory != nil) net=\(s?.network != nil) disk=\(s?.disk != nil) "
              + "temp=\(s?.sensors?.cpuTemperature.map { String(format: "%.1f", $0) } ?? "nil") fans=\(s?.sensors?.fans.count ?? -1)")
        store.isPanelVisible = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for tab in ["overview", "processes", "network"] {
                UserDefaults.standard.set(tab, forKey: "panelTab")
                let natural = NSHostingView(rootView: OverviewContent(store: store, settings: settings, processes: processes)
                    .frame(width: PanelView.contentWidth)).fittingSize.height
                let view = NSHostingView(rootView: PanelView(store: store, settings: settings, network: network, processes: processes,
                                                             contentHeight: natural, openSettings: {}, quit: {})
                    .background(Color(nsColor: .windowBackgroundColor)))
                view.appearance = NSAppearance(named: appearance)
                // 先布局一次让内容高度测量生效，再按最终尺寸输出。
                for _ in 0..<3 {
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                write(view, to: dir.appendingPathComponent("panel-\(tab)-\(name).png"), scale: 4)
            }
            // 强制退出确认条
            if let target = processes.reading?.top(by: .memory, limit: 1).first {
                UserDefaults.standard.set("processes", forKey: "panelTab")
                processes.pendingForceQuit = .app(target)
                let natural = NSHostingView(rootView: OverviewContent(store: store, settings: settings, processes: processes)
                    .frame(width: PanelView.contentWidth)).fittingSize.height
                let view = NSHostingView(rootView: PanelView(store: store, settings: settings, network: network,
                                                             processes: processes, contentHeight: natural,
                                                             openSettings: {}, quit: {}))
                view.appearance = NSAppearance(named: appearance)
                for _ in 0..<3 {
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                write(view, to: dir.appendingPathComponent("panel-forcequit-\(name).png"), scale: 4)
                processes.pendingForceQuit = nil
            }
            UserDefaults.standard.set("overview", forKey: "panelTab")
            // 模拟小屏：可用高度 520pt 时内容区应改为滚动，面板不超出屏幕。
            let small = NSHostingView(rootView: PanelView(store: store, settings: settings, network: network, processes: processes,
                                                          contentHeight: 380, openSettings: {}, quit: {}))
            small.appearance = NSAppearance(named: appearance)
            for _ in 0..<3 {
                small.frame = NSRect(origin: .zero, size: small.fittingSize)
                small.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            write(small, to: dir.appendingPathComponent("panel-small-screen-\(name).png"), scale: 4)

            let renderer = MenuBarRenderer()
            for (style, items) in [("default", settings.enabledItems), ("all", MenuBarItem.allCases)] {
                let segments = MenuBarContent.segments(for: items, snapshot: store.snapshot, unit: settings.temperatureUnit)
                guard let image = renderer.render(segments, height: 22) else { continue }
                let bar = NSImageView(image: image)
                bar.contentTintColor = appearance == .aqua ? .black : .white
                bar.wantsLayer = true
                bar.layer?.backgroundColor = (appearance == .aqua ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.15, alpha: 1)).cgColor
                bar.frame = NSRect(x: 0, y: 0, width: image.size.width + 16, height: 22)
                write(bar, to: dir.appendingPathComponent("menubar-\(style)-\(name).png"))
            }
        }
        // 网络监控窗口的各个页面
        for page in NetworkPage.allCases {
            UserDefaults.standard.set(page.rawValue, forKey: "networkPage")
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] where page == .overview || name == "light" {
                let view = NSHostingView(rootView: NetworkWindowView(monitor: network, settings: settings))
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 0, y: 0, width: 1080, height: 700)
                for _ in 0..<3 {
                    view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                }
                write(view, to: dir.appendingPathComponent("network-\(page.rawValue)-\(name).png"))
            }
        }
        UserDefaults.standard.set(NetworkPage.overview.rawValue, forKey: "networkPage")

        let settingsView = NSHostingView(rootView: SettingsView(settings: settings))
        settingsView.frame = NSRect(origin: .zero, size: settingsView.fittingSize)
        write(settingsView, to: dir.appendingPathComponent("settings.png"))
    }

    /// 截取真实窗口（含标题栏与侧边栏）的各个页面。
    static func captureWindows(to dir: URL, page controller: NSWindowController?) {
        guard let window = controller?.window, let frameView = window.contentView?.superview else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for page in NetworkPage.allCases {
            UserDefaults.standard.set(page.rawValue, forKey: "networkPage")
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            write(frameView, to: dir.appendingPathComponent("window-\(page.rawValue).png"))
        }
        UserDefaults.standard.set(NetworkPage.overview.rawValue, forKey: "networkPage")
    }

    /// `scale` 是点到像素的倍数。面板在网页上会放大显示，2 倍图会发糊，截图用 4 倍。
    private static func write(_ view: NSView, to url: URL, scale: CGFloat = 2) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let pixelsWide = max(1, Int((bounds.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((bounds.height * scale).rounded(.up)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
