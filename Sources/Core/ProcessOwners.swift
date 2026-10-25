//
//  ProcessOwners.swift
//  Zest
//
//  把进程归属到所在的 .app（如 “Google Chrome Helper” → Google Chrome），供“进程”与“连接”页共用。
//

import Foundation

enum ProcessKind: Int, CaseIterable, Identifiable, Comparable {
    case app, commandLine, system

    var id: Int { rawValue }
    static func < (a: ProcessKind, b: ProcessKind) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .app: return L10n.text("process.kind.app", defaultValue: "应用")
        case .commandLine: return L10n.text("命令行")
        case .system: return L10n.text("process.kind.system", defaultValue: "系统")
        }
    }
}

struct ProcessOwner: Equatable {
    /// 分组键：.app 路径，命令行程序则为进程名。
    var key: String
    /// 所属 .app 包路径；命令行程序为 nil。
    var bundlePath: String?
    var name: String
    var kind: ProcessKind
}

final class ProcessOwnerResolver {
    private var cache: [pid_t: ProcessOwner] = [:]

    /// 结果按 pid 缓存；pid 复用的情况由 prune(alive:) 清理已退出的进程。
    func owner(of pid: pid_t) -> ProcessOwner {
        if let cached = cache[pid] { return cached }
        let result: ProcessOwner
        let path = ProcessOwners.path(pid)
        let bundle = ProcessOwners.outermostApp(path: path)
        let kind = ProcessOwners.kind(bundlePath: bundle, executablePath: path)
        if let bundle {
            let name = (FileManager.default.displayName(atPath: bundle) as NSString).deletingPathExtension
            result = ProcessOwner(key: bundle, bundlePath: bundle, name: name, kind: kind)
        } else {
            let name = ProcessOwners.name(pid)
            result = ProcessOwner(key: name, bundlePath: nil, name: name, kind: kind)
        }
        cache[pid] = result
        return result
    }

    func prune(alive: Set<pid_t>) {
        cache = cache.filter { alive.contains($0.key) }
    }
}

enum ProcessOwners {
    private static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/",
                                         "/private/var/", "/Library/Developer/", "/Applications/Xcode.app/Contents/Developer/"]

    /// 按可执行文件位置分类：
    /// - 应用：普通 .app；系统自带的用户应用（/System/Applications 下的备忘录等、访达）也算应用。
    /// - 系统：/System、/usr 等位置的系统进程与守护进程（含 Dock、控制中心等系统界面进程）。
    /// - 命令行：其余无 .app 的进程（如 Homebrew 安装的 python、node）。
    static func kind(bundlePath: String?, executablePath: String?) -> ProcessKind {
        if let bundle = bundlePath {
            if bundle.contains("/System/Applications/") || bundle.hasSuffix("/CoreServices/Finder.app") { return .app }
            if bundle.hasPrefix("/System/") || bundle.hasPrefix("/Library/Apple/") { return .system }
            return .app
        }
        guard let path = executablePath else { return .system }   // 读不到路径的多为系统进程
        return systemPrefixes.contains { path.hasPrefix($0) } ? .system : .commandLine
    }

    static func outermostApp(path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN) + 1)
        proc_name(pid, &buf, UInt32(buf.count))
        let name = String(cString: buf)
        return name.isEmpty ? "pid \(pid)" : name
    }

    static func allPIDs(buffer: inout [pid_t]) -> ArraySlice<pid_t> {
        var count = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        if count > Int32(buffer.count) - 64 {
            buffer = [pid_t](repeating: 0, count: Int(count) * 2)
            count = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        return buffer.prefix(Int(max(count, 0))).filter { $0 > 0 }[...]
    }
}
