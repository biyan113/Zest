//
//  LocalizationTests.swift
//  ZestTests
//

import XCTest

/// 从测试宿主 Zest.app 的 lproj 读取编译后的字符串表。
final class LocalizationTests: XCTestCase {
    /// 基础语言 zh-Hans、en，以及同样需要覆盖的额外语言。
    private static let languages: [String] = {
        let baseline = ["zh-Hans", "en"]
        let extra = ["zh-Hans", "en"]
        var ordered: [String] = []
        for code in baseline + extra where !ordered.contains(code) {
            ordered.append(code)
        }
        return ordered
    }()

    func testLocalizableKeysValuesAndPlaceholders() throws {
        let bundle = try hostBundle()
        let tables = try Self.languages.map { language in
            (language, try loadStrings(named: "Localizable", language: language, bundle: bundle))
        }
        let referenceLanguage = tables[0].0
        let reference = tables[0].1
        XCTAssertFalse(reference.isEmpty, "\(referenceLanguage).lproj/Localizable.strings 没有条目")
        let referenceKeys = Set(reference.keys)

        for (language, table) in tables {
            XCTAssertEqual(Set(table.keys), referenceKeys, "\(language) 与 \(referenceLanguage) 的键集合不同")
            for key in referenceKeys.sorted() {
                let value = try XCTUnwrap(table[key], "\(language) 缺少键 \(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language) 的值为空：\(key)")
                let actual = Self.placeholderCounts(value)
                let expected = Self.placeholderCounts(reference[key] ?? "")
                XCTAssertEqual(actual, expected,
                               "\(language) 与 \(referenceLanguage) 占位符个数不一致：\(key)\n\(language): \(actual)\n\(referenceLanguage): \(expected)")
            }
        }
    }

    func testLocalNetworkUsageDescriptionIsPresent() throws {
        let bundle = try hostBundle()
        for language in Self.languages {
            let table = try loadStrings(named: "InfoPlist", language: language, bundle: bundle)
            let value = table["NSLocalNetworkUsageDescription"] ?? ""
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(language) 的 NSLocalNetworkUsageDescription 为空")
        }
    }

    /// `%1$@` 这类序号占位符先从文本里去掉，再数 `%@` `%d` `%lld` `%.0f` `%.2f`，避免和普通占位符重复计算。
    private static func placeholderCounts(_ value: String) -> PlaceholderCounts {
        let positional = countMatches("%[0-9]+\\$", in: value)
        var plain = value.replacingOccurrences(of: "%[0-9]+\\$", with: "", options: .regularExpression)
        func take(_ token: String) -> Int {
            let count = plain.components(separatedBy: token).count - 1
            if count > 0 { plain = plain.replacingOccurrences(of: token, with: "") }
            return count
        }
        return PlaceholderCounts(
            object: take("%@"),
            int: take("%d"),
            longLong: take("%lld"),
            float0: take("%.0f"),
            float2: take("%.2f"),
            positional: positional
        )
    }

    private static func countMatches(_ pattern: String, in text: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func hostBundle() throws -> Bundle {
        if Bundle.main.bundleURL.lastPathComponent == "Zest.app" { return Bundle.main }
        if let app = Bundle.allBundles.first(where: { $0.bundleURL.lastPathComponent == "Zest.app" }) {
            return app
        }
        var url = Bundle(for: LocalizationTests.self).bundleURL
        for _ in 0..<6 {
            url.deleteLastPathComponent()
            if url.lastPathComponent == "Zest.app", let bundle = Bundle(url: url) { return bundle }
            if url.path == "/" { break }
        }
        XCTFail("测试宿主不是 Zest.app：\(Bundle.main.bundleURL.path)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadStrings(named name: String, language: String, bundle: Bundle) throws -> [String: String] {
        let url = try XCTUnwrap(stringsURL(name: name, language: language, bundle: bundle),
                                "缺少 \(language).lproj/\(name).strings")
        let raw = try XCTUnwrap(NSDictionary(contentsOf: url), "无法读取 \(url.path)")
        var table: [String: String] = [:]
        table.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard let key = key as? String, let value = value as? String else {
                XCTFail("\(language).lproj/\(name).strings 含非字符串条目")
                continue
            }
            table[key] = value
        }
        return table
    }

    private func stringsURL(name: String, language: String, bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: "strings", subdirectory: nil, localization: language) {
            return url
        }
        let direct = bundle.resourceURL?
            .appendingPathComponent("\(language).lproj", isDirectory: true)
            .appendingPathComponent("\(name).strings")
        if let direct, FileManager.default.fileExists(atPath: direct.path) { return direct }
        return nil
    }
}

private struct PlaceholderCounts: Equatable, CustomStringConvertible {
    var object: Int
    var int: Int
    var longLong: Int
    var float0: Int
    var float2: Int
    var positional: Int

    var description: String {
        "%@=\(object) %d=\(int) %lld=\(longLong) %.0f=\(float0) %.2f=\(float2) positional=\(positional)"
    }
}
