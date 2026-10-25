//
//  AppSettings.swift
//  Zest
//

import Foundation
import ServiceManagement

enum MenuBarItem: String, CaseIterable, Codable, Identifiable {
    case cpu, memory, network, temperature, disk, fan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return L10n.text("CPU 使用率")
        case .memory: return L10n.text("内存占用")
        case .network: return L10n.text("网络速度")
        case .temperature: return L10n.text("CPU 温度")
        case .disk: return L10n.text("磁盘占用")
        case .fan: return L10n.text("风扇转速")
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .temperature: return "thermometer"
        case .disk: return "internaldrive"
        case .fan: return "fanblades"
        }
    }

    var needsSensors: Bool { self == .temperature || self == .fan }
}

struct MenuBarEntry: Codable, Identifiable, Equatable {
    var item: MenuBarItem
    var enabled: Bool
    var id: String { item.rawValue }
}

final class AppSettings: ObservableObject {
    static let refreshChoices: [Double] = [0.5, 1, 2, 3, 5, 10]
    static let languageChangedNotification = Notification.Name("app.zest.monitor.language")

    private let defaults: UserDefaults
    private var isApplyingRemoteLanguage = false

    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: Keys.interval) } }
    @Published var menuBarEntries: [MenuBarEntry] { didSet { saveEntries() } }
    @Published var temperatureUnit: TemperatureUnit { didSet { defaults.set(temperatureUnit.rawValue, forKey: Keys.unit) } }
    @Published var launchAtLoginError: String?
    @Published var appLanguage: AppLanguage {
        didSet {
            guard appLanguage != oldValue else { return }
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            L10n.use(appLanguage)
            guard !isApplyingRemoteLanguage else { return }
            DistributedNotificationCenter.default().postNotificationName(
                AppSettings.languageChangedNotification, object: nil,
                userInfo: ["appLanguage": appLanguage.rawValue], deliverImmediately: true)
        }
    }

    // 网络监控
    @Published var networkMonitoring: Bool { didSet { defaults.set(networkMonitoring, forKey: Keys.networkMonitoring) } }
    @Published var resolveHostnames: Bool { didSet { defaults.set(resolveHostnames, forKey: Keys.resolveHostnames) } }
    @Published var alertNotifications: Bool { didSet { defaults.set(alertNotifications, forKey: Keys.alertNotifications) } }
    @Published var suppressions: [SuppressionRule] {
        didSet { if let d = try? JSONEncoder().encode(suppressions) { defaults.set(d, forKey: Keys.suppressions) } }
    }

    private enum Keys {
        static let interval = "refreshInterval"
        static let entries = "menuBarEntries"
        static let unit = "temperatureUnit"
        static let networkMonitoring = "networkMonitoring"
        static let resolveHostnames = "resolveHostnames"
        static let alertNotifications = "alertNotifications"
        static let suppressions = "alertSuppressions"
        static let appLanguage = "appLanguage"
    }

    static let defaultEntries: [MenuBarEntry] = [
        .init(item: .cpu, enabled: true),
        .init(item: .memory, enabled: true),
        .init(item: .disk, enabled: true),
        .init(item: .network, enabled: true),
        .init(item: .temperature, enabled: false),
        .init(item: .fan, enabled: false),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.double(forKey: Keys.interval)
        refreshInterval = AppSettings.refreshChoices.contains(interval) ? interval : 1
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: Keys.unit) ?? "") ?? .celsius
        menuBarEntries = AppSettings.loadEntries(defaults.data(forKey: Keys.entries))
        networkMonitoring = defaults.object(forKey: Keys.networkMonitoring) as? Bool ?? true
        resolveHostnames = defaults.bool(forKey: Keys.resolveHostnames)
        alertNotifications = defaults.bool(forKey: Keys.alertNotifications)
        suppressions = defaults.data(forKey: Keys.suppressions)
            .flatMap { try? JSONDecoder().decode([SuppressionRule].self, from: $0) } ?? []
        appLanguage = AppLanguage.stored(defaults.string(forKey: Keys.appLanguage))
        L10n.use(appLanguage)
    }

    /// 解析已保存的顺序；补齐新增项目、去掉未知项目。
    static func loadEntries(_ data: Data?) -> [MenuBarEntry] {
        guard let data, let saved = try? JSONDecoder().decode([MenuBarEntry].self, from: data) else { return defaultEntries }
        var seen = Set<MenuBarItem>()
        var result = saved.filter { seen.insert($0.item).inserted }
        for entry in defaultEntries where !seen.contains(entry.item) {
            result.append(MenuBarEntry(item: entry.item, enabled: false))
        }
        return result
    }

    private func saveEntries() {
        if let data = try? JSONEncoder().encode(menuBarEntries) { defaults.set(data, forKey: Keys.entries) }
    }

    /// 其他进程（网络监控窗口）修改了忽略规则后重新读取。
    func reloadSuppressions() {
        let fresh = defaults.data(forKey: Keys.suppressions)
            .flatMap { try? JSONDecoder().decode([SuppressionRule].self, from: $0) } ?? []
        if fresh != suppressions { suppressions = fresh }
    }

    /// 另一个进程改了界面语言。值不变则不赋值，避免再次广播。
    func reloadLanguage(_ note: Notification? = nil) {
        let raw = note?.userInfo?["appLanguage"] as? String ?? defaults.string(forKey: Keys.appLanguage)
        let fresh = AppLanguage.stored(raw)
        guard fresh != appLanguage else { return }
        isApplyingRemoteLanguage = true
        appLanguage = fresh
        isApplyingRemoteLanguage = false
    }

    var enabledItems: [MenuBarItem] { menuBarEntries.filter(\.enabled).map(\.item) }

    // MARK: 开机启动（SMAppService，macOS 13+，无需辅助程序）

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
        }
    }

    var launchAtLoginRequiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}
