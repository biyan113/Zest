import AppKit
import SwiftUI

struct QuickToolsView: View {
    @ObservedObject var tools: QuickToolsController
    @ObservedObject var settings: AppSettings
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("快捷工具")).font(.system(size: 14, weight: .semibold))
                    Text(L10n.text("常用操作，触手可及")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    UserDefaults.standard.set("tools", forKey: "settingsSection")
                    openSettings()
                } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help(L10n.text("管理快捷工具"))
                    .accessibilityLabel(L10n.text("管理快捷工具"))
            }
            if let message = tools.message {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(message).font(.system(size: 11)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { tools.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("关闭提示"))
                }
                .foregroundStyle(.secondary).padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 8) {
                ForEach(settings.toolEntries.filter(\.enabled)) { entry in
                    tile(entry)
                }
            }
            if !settings.toolEntries.contains(where: \.enabled) {
                Text(L10n.text("尚未启用工具，请在设置中选择。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 24)
            }
            Text(L10n.text("部分工具首次使用需要系统授权。临时模式到期或退出 Zest 后自动结束。"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { tools.refresh() }
        .id(settings.appLanguage)
    }

    private func tile(_ entry: ToolEntry) -> some View {
        let tool = entry.tool
        let active = tools.active.contains(tool)
        let busy = tools.busy.contains(tool)
        return Button { tools.perform(tool) } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.055))
                        .frame(width: 44, height: 44)
                    if busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: tool.symbol).font(.system(size: 20, weight: .regular))
                        .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.8)) }
                }
                Text(tool.title).font(.system(size: 10.5, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center).frame(height: 28)
                Text(tools.status(tool)).font(.system(size: 9))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.accentColor.opacity(0.045) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(busy)
        .help(tool.detail + (entry.shortcut.map { "\n" + $0.label } ?? ""))
        .accessibilityLabel(tool.title)
        .accessibilityValue(tools.status(tool))
        .accessibilityHint(tool.detail)
    }
}

struct QuickToolsSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var tools: QuickToolsController
    @State private var recording: QuickTool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("启用工具，拖动调整顺序")).font(.headline)
                Spacer()
                Button(L10n.text("恢复默认")) { recording = nil; settings.toolEntries = ToolEntry.defaults }
            }
            List {
                ForEach($settings.toolEntries) { $entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Image(systemName: entry.tool.symbol).frame(width: 20)
                            Toggle(entry.tool.title, isOn: $entry.enabled).toggleStyle(.checkbox)
                            Spacer(minLength: 4)
                            Button {
                                recording = recording == entry.tool ? nil : entry.tool
                            } label: {
                                Text(recording == entry.tool ? L10n.text("请按快捷键…") : (entry.shortcut?.label ?? L10n.text("设置快捷键")))
                                    .font(.system(size: 11)).frame(minWidth: 86)
                            }
                            .help(L10n.text("包含 ⌘、⌥ 或 ⌃；Esc 取消，Delete 清除。"))
                            .background {
                                if recording == entry.tool {
                                    ShortcutCapture { shortcut in
                                        guard recording == entry.tool else { return }
                                        _ = tools.assignShortcut(shortcut, to: entry.tool)
                                        recording = nil
                                    } cancel: {
                                        if recording == entry.tool { recording = nil }
                                    }
                                    .frame(width: 0, height: 0)
                                }
                            }
                        }
                        if let error = tools.shortcutErrors[entry.tool] {
                            Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                    .help(entry.tool.detail)
                }
                .onMove { settings.toolEntries.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 245)
            Group {
                Picker(L10n.text("亮屏 / 合盖模式时长"), selection: $settings.awakeMinutes) {
                    Text(L10n.text("直到手动关闭")).tag(0)
                    ForEach([15, 30, 60, 120], id: \.self) { minutes in
                        Text(String(format: L10n.text("%lld 分钟"), Int64(minutes))).tag(minutes)
                    }
                }
                Picker(L10n.text("清洁模式自动退出"), selection: $settings.cleaningSeconds) {
                    ForEach([30, 60, 120], id: \.self) { seconds in
                        Text(String(format: L10n.text("%lld 秒"), Int64(seconds))).tag(seconds)
                    }
                }
                Picker(L10n.text("Dock 固定屏幕"), selection: $settings.dockDisplayID) {
                    Text(L10n.text("主显示器")).tag(UInt32(0))
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                            Text(screen.localizedName).tag(id)
                        }
                    }
                    if settings.dockDisplayID != 0 && !NSScreen.screens.contains(where: {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == settings.dockDisplayID
                    }) { Text(L10n.text("未连接的显示器")).tag(settings.dockDisplayID) }
                }
            }
            .font(.system(size: 12))
            if let message = tools.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Button(L10n.text("辅助功能权限")) { openPrivacy("Privacy_Accessibility") }
                Button(L10n.text("自动化权限")) { openPrivacy("Privacy_Automation") }
                Spacer()
            }
            .font(.system(size: 11))
            Text(L10n.text("快捷键仅对已启用工具生效。省电和合盖模式会请求管理员授权；清洁模式可用 ⌃⌥⌘ Esc 紧急退出。"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(16)
        .onChange(of: recording) { tools.recordShortcut($0 != nil) }
        .onDisappear { recording = nil; tools.recordShortcut(false) }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}

private struct ShortcutCapture: NSViewRepresentable {
    var received: (ToolShortcut?) -> Void
    var cancel: () -> Void

    func makeNSView(context: Context) -> CaptureView { CaptureView(received: received, cancel: cancel) }
    func updateNSView(_ view: CaptureView, context: Context) {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    final class CaptureView: NSView {
        let received: (ToolShortcut?) -> Void
        let cancel: () -> Void
        init(received: @escaping (ToolShortcut?) -> Void, cancel: @escaping () -> Void) {
            self.received = received; self.cancel = cancel
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func resignFirstResponder() -> Bool {
            DispatchQueue.main.async { self.cancel() }
            return true
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { capture(event); return true }
        override func keyDown(with event: NSEvent) { capture(event) }
        private func capture(_ event: NSEvent) {
            if event.keyCode == 53 { cancel(); return }
            if event.keyCode == 51 || event.keyCode == 117 { received(nil); return }
            var flags: UInt32 = 0
            if event.modifierFlags.contains(.command) { flags |= ToolShortcut.command }
            if event.modifierFlags.contains(.option) { flags |= ToolShortcut.option }
            if event.modifierFlags.contains(.control) { flags |= ToolShortcut.control }
            if event.modifierFlags.contains(.shift) { flags |= ToolShortcut.shift }
            let shortcut = ToolShortcut(keyCode: UInt32(event.keyCode), modifiers: flags, characters: event.charactersIgnoringModifiers ?? "")
            guard shortcut.isValid else { NSSound.beep(); return }
            received(shortcut)
        }
    }
}
