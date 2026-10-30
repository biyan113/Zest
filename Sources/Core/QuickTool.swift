import Foundation
import CoreGraphics

enum QuickTool: String, CaseIterable, Codable, Identifiable {
    case darkMode, lockScreen, keepAwake, screenSaver, cleanScreen, cleanKeyboard
    case hideMenuBar, emptyTrash, clamshell, lockDock, lowPower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .darkMode: return L10n.text("深色模式")
        case .lockScreen: return L10n.text("锁屏")
        case .keepAwake: return L10n.text("保持亮屏")
        case .screenSaver: return L10n.text("进入屏保")
        case .cleanScreen: return L10n.text("清洁屏幕")
        case .cleanKeyboard: return L10n.text("清洁键盘")
        case .hideMenuBar: return L10n.text("自动隐藏菜单栏")
        case .emptyTrash: return L10n.text("清倒废纸篓")
        case .clamshell: return L10n.text("合盖不休眠")
        case .lockDock: return L10n.text("锁定 Dock")
        case .lowPower: return L10n.text("省电模式")
        }
    }

    var symbol: String {
        switch self {
        case .darkMode: return "circle.lefthalf.filled"
        case .lockScreen: return "lock.display"
        case .keepAwake: return "sun.max"
        case .screenSaver: return "play.rectangle"
        case .cleanScreen: return "sparkles.rectangle.stack"
        case .cleanKeyboard: return "keyboard"
        case .hideMenuBar: return "menubar.rectangle"
        case .emptyTrash: return "trash"
        case .clamshell: return "laptopcomputer"
        case .lockDock: return "dock.rectangle"
        case .lowPower: return "leaf"
        }
    }

    var detail: String {
        switch self {
        case .darkMode: return L10n.text("切换系统深浅色；首次使用需要允许自动化控制 System Events。")
        case .lockScreen: return L10n.text("立即锁定 Mac；需要辅助功能权限。")
        case .keepAwake: return L10n.text("阻止屏幕因闲置而关闭，计时结束或退出 Zest 后恢复。")
        case .screenSaver: return L10n.text("立即启动系统屏幕保护程序。")
        case .cleanScreen: return L10n.text("全屏黑色背景方便清洁；按 Esc 或点击退出。")
        case .cleanKeyboard: return L10n.text("暂时屏蔽普通键盘输入；点击退出或等待倒计时恢复。电源键和 Touch ID 不受控制。")
        case .hideMenuBar: return L10n.text("切换系统菜单栏自动隐藏；需要自动化权限。")
        case .emptyTrash: return L10n.text("清空 Finder 废纸篓；执行前需要确认，清空后无法撤销。")
        case .clamshell: return L10n.text("需要管理员授权，临时关闭系统睡眠；关闭、到期或 Zest 退出后由独立守护进程恢复原设置。")
        case .lockDock: return L10n.text("阻止鼠标在其他屏幕边缘唤出 Dock。需要辅助功能权限，会避开这些边缘的 4 个点；可随时关闭。")
        case .lowPower: return L10n.text("需要管理员授权，同时切换电池和接通电源时的低电量模式；退出 Zest 后保留。")
        }
    }

    var isToggle: Bool {
        [.darkMode, .keepAwake, .hideMenuBar, .clamshell, .lockDock, .lowPower].contains(self)
    }
}

struct ToolEntry: Codable, Equatable, Identifiable {
    var tool: QuickTool
    var enabled = true
    var shortcut: ToolShortcut?
    var id: String { tool.rawValue }

    static var defaults: [ToolEntry] { QuickTool.allCases.map { ToolEntry(tool: $0) } }

    static func load(_ data: Data?) -> [ToolEntry] {
        guard let data, let decoded = try? JSONDecoder().decode([ToolEntry].self, from: data) else { return defaults }
        var seen = Set<QuickTool>()
        var shortcuts = Set<ToolShortcut>()
        var entries = decoded.filter { seen.insert($0.tool).inserted }
        for index in entries.indices {
            if let shortcut = entries[index].shortcut,
               !shortcut.isValid || !shortcuts.insert(shortcut).inserted { entries[index].shortcut = nil }
        }
        entries += defaults.filter { !seen.contains($0.tool) }
        return entries
    }
}

/// Carbon modifier bit values; kept separate from AppKit for command-line tests.
struct ToolShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let characters: String

    static let command: UInt32 = 1 << 8
    static let shift: UInt32 = 1 << 9
    static let option: UInt32 = 1 << 11
    static let control: UInt32 = 1 << 12
    static let allowedModifiers = command | shift | option | control

    var isValid: Bool {
        keyCode < 128 && modifiers & ~Self.allowedModifiers == 0 &&
            modifiers & (Self.command | Self.option | Self.control) != 0 && !characters.isEmpty
    }

    var label: String {
        (modifiers & Self.control != 0 ? "⌃" : "") +
        (modifiers & Self.option != 0 ? "⌥" : "") +
        (modifiers & Self.shift != 0 ? "⇧" : "") +
        (modifiers & Self.command != 0 ? "⌘" : "") + characters.uppercased()
    }

    // Labels depend on keyboard layout; physical key + modifiers determine conflicts.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers }
    func hash(into hasher: inout Hasher) { hasher.combine(keyCode); hasher.combine(modifiers) }
}

enum ToolCommand {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

enum DockEdgeGuard {
    /// Coordinates are Quartz display coordinates (origin at the primary display's top left).
    static func adjusted(_ point: CGPoint, displays: [CGRect], lockedIndex: Int, orientation: String) -> CGPoint {
        guard displays.indices.contains(lockedIndex), !displays[lockedIndex].contains(point),
              let index = displays.firstIndex(where: { $0.contains(point) }) else { return point }
        let rect = displays[index]
        var candidate = point
        var outside = point
        switch orientation {
        case "left":
            guard point.x < rect.minX + 4 else { return point }
            outside.x = rect.minX - 1; candidate.x = rect.minX + 4
        case "right":
            guard point.x >= rect.maxX - 4 else { return point }
            outside.x = rect.maxX + 1; candidate.x = rect.maxX - 5
        default:
            guard point.y >= rect.maxY - 4 else { return point }
            outside.y = rect.maxY + 1; candidate.y = rect.maxY - 5
        }
        // A shared display boundary cannot summon Dock; leave crossing between screens intact.
        if displays.enumerated().contains(where: { $0.offset != index && $0.element.contains(outside) }) { return point }
        return candidate
    }
}
