import Foundation

@main
enum QuickToolsChecks {
    static var checks = 0
    static func check(_ passed: @autoclosure () -> Bool, _ name: String) {
        precondition(passed(), "Failed: " + name)
        checks += 1
    }

    static func main() throws {
        let tools: Set<String> = ["darkMode", "lockScreen", "keepAwake", "screenSaver", "cleanScreen", "cleanKeyboard",
                                   "hideMenuBar", "emptyTrash", "clamshell", "lockDock", "lowPower"]
        check(Set(QuickTool.allCases.map(\.rawValue)) == tools, "exactly the 11 approved tools")
        check(ToolEntry.load(nil).count == 11, "default settings")
        check(ToolEntry.load(Data("invalid".utf8)).count == 11, "corrupt settings recovery")
        let shortcut = ToolShortcut(keyCode: 40, modifiers: ToolShortcut.command | ToolShortcut.option, characters: "k")
        let sameKey = ToolShortcut(keyCode: 40, modifiers: shortcut.modifiers, characters: "κ")
        check(shortcut == sameKey && Set([shortcut, sameKey]).count == 1, "physical shortcut conflicts across keyboard layouts")
        check(shortcut.isValid && shortcut.label == "⌥⌘K", "shortcut label")
        check(!ToolShortcut(keyCode: 40, modifiers: ToolShortcut.shift, characters: "k").isValid, "no unmodified typing interception")
        check(!ToolShortcut(keyCode: 40, modifiers: 1 << 25, characters: "k").isValid, "reject unsupported modifiers")
        let encoded = try JSONEncoder().encode([
            ToolEntry(tool: .lockDock, enabled: false, shortcut: shortcut),
            ToolEntry(tool: .darkMode, shortcut: sameKey),
            ToolEntry(tool: .lockDock)
        ])
        let restored = ToolEntry.load(encoded)
        check(restored.count == 11 && restored.first?.tool == .lockDock && restored.first?.enabled == false, "preserve order and enabled state")
        check(restored.filter { $0.shortcut != nil }.count == 1, "remove duplicate shortcuts")
        let roundTrip = try JSONDecoder().decode([ToolEntry].self, from: JSONEncoder().encode(restored))
        check(roundTrip == restored, "settings round trip")

        let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let untouched = CGPoint(x: 800, y: 899)
        check(DockEdgeGuard.adjusted(untouched, displays: displays, lockedIndex: 0, orientation: "bottom") == untouched, "target display remains free")
        check(DockEdgeGuard.adjusted(CGPoint(x: 1800, y: 1079), displays: displays, lockedIndex: 0, orientation: "bottom").y == 1075, "secondary bottom edge protected")
        check(DockEdgeGuard.adjusted(CGPoint(x: 3359, y: 500), displays: displays, lockedIndex: 0, orientation: "right").x == 3355, "right-hand Dock protected")
        let boundary = CGPoint(x: 1441, y: 400)
        check(DockEdgeGuard.adjusted(boundary, displays: displays, lockedIndex: 0, orientation: "left") == boundary, "shared edges remain traversable")
        let stacked = [CGRect(x: 0, y: -900, width: 1440, height: 900), displays[0]]
        check(DockEdgeGuard.adjusted(CGPoint(x: 500, y: -1), displays: stacked, lockedIndex: 1, orientation: "bottom") == CGPoint(x: 500, y: -1), "vertical crossing remains traversable")
        check(DockEdgeGuard.adjusted(CGPoint(x: 1, y: 500), displays: displays, lockedIndex: 1, orientation: "left").x == 4, "left-hand Dock protected")
        check(DockEdgeGuard.adjusted(untouched, displays: displays, lockedIndex: 9, orientation: "bottom") == untouched, "disconnected display is safe")

        for text in ["a b'c\"d", "$(printf injected); `printf bad`", "line one\nline two", "中文路径"] {
            let task = Process(); let output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "printf %s " + ToolCommand.shellQuote(text)]
            task.standardOutput = output
            try task.run()
            let actual = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            check(task.terminationStatus == 0 && String(data: actual, encoding: .utf8) == text, "shell argument is literal")
        }
        check(ToolCommand.appleScriptString("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"", "AppleScript string escaping")
        print("Passed \(checks) quick-tool logic checks")
    }
}
