//
//  StatusItemController.swift
//  Zest
//

import AppKit
import Combine
import SwiftUI

final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let renderer = MenuBarRenderer()
    private let store: MonitorStore
    private let settings: AppSettings
    private let network: NetworkMonitor
    private let processes: ProcessMonitor
    private let onOpenSettings: () -> Void
    private let onOpenNetworkWindow: () -> Void
    private var tools: QuickToolsController?
    private var lastSegments: [MenuBarSegment]?
    private var lastImageHeight: CGFloat?
    private var lastImageScale: CGFloat?
    private var outsideClickMonitor: Any?

    var onPanelVisibilityChange: ((Bool) -> Void)?
    var onPanelTabChange: ((PanelView.PanelTab) -> Void)?

    init(store: MonitorStore, settings: AppSettings, network: NetworkMonitor, processes: ProcessMonitor,
         openSettings: @escaping () -> Void, openNetworkWindow: @escaping () -> Void, tools: QuickToolsController? = nil) {
        self.store = store
        self.settings = settings
        self.network = network
        self.processes = processes
        self.onOpenSettings = openSettings
        self.onOpenNetworkWindow = openNetworkWindow
        self.tools = tools
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.imagePosition = .imageOnly
        }
        update(snapshot: nil)
    }

    /// 只有显示内容变化时才重新生成菜单栏图片。
    func update(snapshot: Snapshot?) {
        statusItem.button?.setAccessibilityTitle(L10n.text("Zest 系统监控"))
        let items = settings.enabledItems
        let segments = MenuBarContent.segments(for: items, snapshot: snapshot, unit: settings.temperatureUnit)
        guard let button = statusItem.button else { return }
        let height = NSStatusBar.system.thickness
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard segments != lastSegments || height != lastImageHeight || scale != lastImageScale else { return }
        lastSegments = segments
        lastImageHeight = height
        lastImageScale = scale

        let started = DispatchTime.now().uptimeNanoseconds
        defer { PerformanceLog.shared.timing("menubar_render", since: started) }
        if let image = renderer.render(segments, height: height, scale: scale) {
            button.image = image
        } else {
            let icon = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Zest")
                ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Zest")
            icon?.isTemplate = true
            button.image = icon
        }
        button.toolTip = segments.isEmpty ? "Zest" : segments.map(\.accessibilityText).joined(separator: "\n")
    }

    func forceRedraw(snapshot: Snapshot?) {
        lastSegments = nil
        update(snapshot: snapshot)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        let contentHeight = panelContentHeight(below: button)
        // 尺寸在弹出前一次算定，之后不随 SwiftUI 内容变化自动调整（否则弹窗会以底边为基准向上长出屏幕）。
        // 关闭 sizingOptions 后控制器自身的 fittingSize 恒为 0，因此用独立的 NSHostingView 测量。
        let size = NSHostingView(rootView: makePanel(contentHeight: contentHeight)).fittingSize
        let hosting = NSHostingController(rootView: makePanel(contentHeight: contentHeight))
        hosting.sizingOptions = []
        hosting.view.frame.size = size
        hosting.preferredContentSize = size
        popover.contentViewController = hosting
        popover.contentSize = size
        store.isPanelVisible = true
        let tab = UserDefaults.standard.string(forKey: "panelTab") ?? "overview"
        if tab == "overview" || tab == "processes" { processes.start() }
        onPanelVisibilityChange?(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZEST_DEBUG_LAYOUT"] != nil {
            for delay in [0.3, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let window = popover.contentViewController?.view.window else { return }
                    let screen = button.window?.screen
                    print("layout t=\(delay) popoverWindow=\(window.frame) content=\(popover.contentSize)",
                          "hostingFitting=\(hosting.view.fittingSize) preferred=\(hosting.preferredContentSize)",
                          "screen=\(screen?.frame ?? .zero) visible=\(screen?.visibleFrame ?? .zero) button=\(button.window?.frame ?? .zero)")
                }
            }
        }
        #endif
    }

    #if DEBUG || PERFORMANCE_TEST
    func debugShowPanel() {
        if PanelView.isPerformanceRun { popover.behavior = .applicationDefined }
        showPanel()
    }
    #endif

    private func makePanel(contentHeight: CGFloat?) -> PanelView {
        PanelView(store: store, settings: settings, network: network, processes: processes,
                  contentHeight: contentHeight,
                  openSettings: { [weak self] in
                      self?.popover.performClose(nil)
                      self?.onOpenSettings()
                  },
                  openNetworkWindow: { [weak self] in
                      self?.popover.performClose(nil)
                      self?.onOpenNetworkWindow()
                  },
                  quit: { NSApp.terminate(nil) },
                  onTabChange: { [weak self] tab in
                      guard let self else { return }
                      if tab == .network || tab == .tools { processes.stop() } else { processes.start() }
                      PerformanceLog.shared.event("panel_tab", ["tab": tab.rawValue])
                      onPanelTabChange?(tab)
                  }, tools: tools)
    }

    func closePanel() { popover.performClose(nil) }

    /// 内容区高度：取概览页的自然高度，若整个面板放不进菜单栏下方的可用空间则相应缩小（内容区可滚动）。
    private func panelContentHeight(below button: NSStatusBarButton) -> CGFloat {
        let overview = NSHostingView(rootView: OverviewContent(store: store, settings: settings, processes: processes)
            .frame(width: PanelView.contentWidth))
        let natural = overview.fittingSize.height
        let full = NSHostingView(rootView: makePanel(contentHeight: natural)).fittingSize.height
        let chrome = full - natural

        let screen = button.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let buttonBottom = button.window?.frame.minY ?? visible.maxY
        // 弹出框箭头约 13pt，底部再留 12pt 边距。
        var available = buttonBottom - visible.minY - 13 - 12
        #if DEBUG
        if let v = ProcessInfo.processInfo.environment["ZEST_DEBUG_AVAILABLE"].flatMap(Double.init) { available = v }
        #endif
        return max(min(natural, available - chrome, 480), 200)
    }

    func popoverDidClose(_ notification: Notification) {
        store.isPanelVisible = false
        processes.stop()
        onPanelVisibilityChange?(false)
        // 释放 SwiftUI 视图层级，关闭面板后不保留任何渲染开销，并把空闲页归还系统。
        popover.contentViewController = nil
        MemoryRelief.releaseFreePages()
    }
}
