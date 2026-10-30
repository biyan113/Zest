import AppKit
import SwiftUI

/// Offscreen rendering only: never shows a window, starts monitoring, or invokes a tool.
@main
enum RenderQuickTools {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let defaults = UserDefaults(suiteName: "app.zest.preview.transient")!
        let settings = AppSettings(defaults: defaults)
        let tools = QuickToolsController(settings: settings)
        for tool in QuickTool.allCases {
            precondition(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil, "Missing SF Symbol: " + tool.symbol)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in [AppLanguage.zhHans, .en] {
            L10n.use(language)
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                try render(QuickToolsView(tools: tools, settings: settings, openSettings: {})
                    .padding(12).frame(width: 372).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme),
                    to: output.appendingPathComponent("tools-\(language.rawValue)-\(name).png"), scheme: scheme)
            }
            try render(QuickToolsSettings(settings: settings, tools: tools).frame(width: 520, height: 520)
                .background(Color(nsColor: .windowBackgroundColor)),
                to: output.appendingPathComponent("settings-\(language.rawValue).png"), scheme: .light)
        }
        print("Rendered 6 offscreen previews; all tool symbols are available.")
    }

    static func render<V: View>(_ root: V, to url: URL, scheme: ColorScheme) throws {
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        // Attach a hidden window so AppKit-backed List rows receive a real visible rect.
        // Never order this window front or activate the application.
        for _ in 0..<3 {
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let size = view.bounds.size
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        window.contentView = nil
        window.close()
    }
}
