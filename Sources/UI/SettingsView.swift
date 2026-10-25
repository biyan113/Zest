//
//  SettingsView.swift
//  Zest
//

import Sparkle
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var network: NetworkMonitor?
    var updater: SPUUpdater?

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label(L10n.text("通用"), systemImage: "gearshape") }
            MenuBarSettings(settings: settings)
                .tabItem { Label(L10n.text("菜单栏"), systemImage: "menubar.rectangle") }
            NetworkSettings(settings: settings, network: network)
                .tabItem { Label(L10n.text("网络"), systemImage: "network") }
            AboutView(settings: settings, updater: updater)
                .tabItem { Label(L10n.text("关于"), systemImage: "info.circle") }
        }
        .frame(width: 460, height: 460)
        .id(settings.appLanguage)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Picker(selection: $settings.appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.label).tag(language)
                }
            } label: {
                Text(L10n.text("语言"))
            }
            Picker(L10n.text("刷新频率"), selection: $settings.refreshInterval) {
                ForEach(AppSettings.refreshChoices, id: \.self) { v in
                    Text(refreshIntervalLabel(v)).tag(v)
                }
            }
            Text(L10n.text("频率越低越省电。所有指标在同一个定时器中采集，系统可合并唤醒。"))
                .font(.caption).foregroundStyle(.secondary)

            Picker(L10n.text("温度单位"), selection: $settings.temperatureUnit) {
                ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0) }
            }

            Toggle(L10n.text("登录时启动 Zest"), isOn: Binding(get: { settings.launchAtLogin },
                                                             set: { settings.launchAtLogin = $0 }))
            if settings.launchAtLoginRequiresApproval {
                Text(L10n.text("需要在“系统设置 › 通用 › 登录项”中允许 Zest。")).font(.caption).foregroundStyle(.orange)
            }
            if let error = settings.launchAtLoginError {
                Text(String(format: L10n.text("无法修改登录项：%@"), error)).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .id(settings.appLanguage)
    }

    private func refreshIntervalLabel(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(format: L10n.text("%lld 毫秒"), Int64(Int(seconds * 1000)))
        }
        if seconds == 1 {
            return L10n.text("1 秒")
        }
        return String(format: L10n.text("%lld 秒"), Int64(Int(seconds)))
    }
}

private struct MenuBarSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                List {
                    ForEach($settings.menuBarEntries) { $entry in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Image(systemName: entry.item.symbol).frame(width: 18)
                            Toggle(entry.item.title, isOn: $entry.enabled)
                        }
                    }
                    .onMove { settings.menuBarEntries.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 190)
            } header: {
                Text(L10n.text("显示项目（拖动调整顺序）"))
            } footer: {
                Text(L10n.text("全部关闭时菜单栏只显示 Zest 图标。温度与风扇读取不到时显示 N/A。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L10n.text("恢复默认")) { settings.menuBarEntries = AppSettings.defaultEntries }
        }
        .formStyle(.grouped)
        .id(settings.appLanguage)
    }
}

private struct NetworkSettings: View {
    @ObservedObject var settings: AppSettings
    var network: NetworkMonitor?

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("后台网络监控"), isOn: $settings.networkMonitoring)
                Text(L10n.text("定时运行系统自带的 nettop（后台每 8 秒，界面打开时每 2 秒，单次约 17ms），记录各应用流量与 60 分钟历史，并在后台检测异常。关闭后网络页与告警停止更新。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L10n.text("解析远端主机名"), isOn: $settings.resolveHostnames)
                Text(L10n.text("开启后会对远端 IP 发送反向 DNS（PTR）查询，以显示主机名。默认关闭：Zest 本身不发起任何网络请求。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("出现警告时发送系统通知"), isOn: Binding(get: { settings.alertNotifications }, set: { on in
                    if on {
                        NetworkMonitor.requestNotificationPermission { granted in settings.alertNotifications = granted }
                    } else {
                        settings.alertNotifications = false
                    }
                }))
                Text(L10n.text("仅对“警告”级别（可疑端口、上传突增、周期性外连、端口扫描）发送通知。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let network {
                HistorySection(network: network, settings: settings)
            }
        }
        .formStyle(.grouped)
        .id(settings.appLanguage)
    }
}

private struct HistorySection: View {
    @ObservedObject var network: NetworkMonitor
    @ObservedObject var settings: AppSettings
    @State private var confirming = false

    var body: some View {
        Section {
            HStack {
                Text(L10n.text("网络历史"))
                Spacer()
                Text(String(format: L10n.text("保留 24 小时 · 占用 %@"), Fmt.bytes(Double(network.history.storeSize))))
                    .foregroundStyle(.secondary)
            }
            Text(L10n.text("每分钟保存各应用的收发字节与告警到本机（~/Library/Application Support），24 小时前的数据自动删除，不会上传。"))
                .font(.caption).foregroundStyle(.secondary)
            Button(confirming ? L10n.text("确认清除全部历史？") : L10n.text("清除网络历史"), role: .destructive) {
                if confirming { network.clearHistory(); confirming = false } else { confirming = true }
            }
        }
        .id(settings.appLanguage)
    }
}

private struct AboutView: View {
    @ObservedObject var settings: AppSettings
    var updater: SPUUpdater?

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Zest").font(.title2.weight(.semibold))
            Text(String(format: L10n.text("版本 %@"), Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                .foregroundStyle(.secondary)
            Text(L10n.text("轻量的 macOS 菜单栏系统监控工具。"))
            if let updater {
                Divider().padding(.horizontal, 40)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L10n.text("自动检查更新"), isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    Text(L10n.text("每天向 zest.bytenote.net 查询一次是否有新版本。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L10n.text("自动下载并安装更新"), isOn: Binding(
                        get: { updater.automaticallyDownloadsUpdates },
                        set: { updater.automaticallyDownloadsUpdates = $0 }
                    ))
                    .disabled(!updater.allowsAutomaticUpdates)
                    Button(L10n.text("检查更新…")) { updater.checkForUpdates() }
                }
                .frame(maxWidth: 360, alignment: .leading)
            }
            Divider().padding(.horizontal, 40)
            Link("@字节笔记本", destination: URL(string: "https://www.bytenote.net")!)
                .font(.caption)
        }
        .padding()
        .id(settings.appLanguage)
    }
}
