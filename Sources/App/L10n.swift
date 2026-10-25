//
//  L10n.swift
//  Zest
//

import Foundation

/// 界面语言。`system` 使用 Bundle.main，由系统在已有语言里选择。
/// 指定语言加载对应 lproj；文件不存在则回退 Bundle.main。
enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    /// 语言选择器标题。简体中文 / English 是自称，不翻译。
    var label: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    var bundle: Bundle {
        guard self != .system else { return .main }
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let localized = Bundle(path: path) else { return .main }
        return localized
    }

    static func stored(_ raw: String?) -> AppLanguage {
        guard let raw, let language = AppLanguage(rawValue: raw) else { return .system }
        return language
    }
}

enum L10n {
    private static var language = AppLanguage.system

    static var bundle: Bundle { language.bundle }

    static func use(_ language: AppLanguage) {
        self.language = language
    }

    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }

    /// 一词多义时键和默认文案分开，例如页签「应用」和进程种类「应用」。
    static func text(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: bundle)
    }
}
