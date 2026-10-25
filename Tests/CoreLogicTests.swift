//
//  CoreLogicTests.swift
//  ZestTests
//

import XCTest
@testable import Zest

final class RingBufferTests: XCTestCase {
    func testOrderAndOverwrite() {
        var buffer = RingBuffer<Int>(capacity: 3)
        XCTAssertEqual(buffer.elements, [])
        XCTAssertNil(buffer.last)
        buffer.append(1); buffer.append(2)
        XCTAssertEqual(buffer.elements, [1, 2])
        buffer.append(3); buffer.append(4)
        XCTAssertEqual(buffer.elements, [2, 3, 4])
        XCTAssertEqual(buffer.last, 4)
        XCTAssertEqual(buffer.count, 3)
        buffer.removeAll()
        XCTAssertEqual(buffer.elements, [])
    }
}

final class FormatterTests: XCTestCase {
    func testCompactBytes() {
        XCTAssertEqual(Fmt.compactBytes(0), "0B")
        XCTAssertEqual(Fmt.compactBytes(512), "512B")
        XCTAssertEqual(Fmt.compactBytes(1536), "1.5K")
        XCTAssertEqual(Fmt.compactBytes(250 * 1024), "250K")
        XCTAssertEqual(Fmt.compactBytes(5 * 1024 * 1024), "5.0M")
        XCTAssertEqual(Fmt.compactBytes(.nan), "0B")
    }

    func testBytesAndRate() {
        XCTAssertEqual(Fmt.bytes(16 * 1024 * 1024 * 1024), "16.0 GB")
        XCTAssertEqual(Fmt.rate(1024), "1.00 KB/s")
    }

    func testPercentClamps() {
        XCTAssertEqual(Fmt.percent(0.234), "23%")
        XCTAssertEqual(Fmt.percent(1.7), "100%")
        XCTAssertEqual(Fmt.percent(-1), "0%")
        XCTAssertEqual(Fmt.percent(.nan), "--")
    }

    func testTemperatureUnits() {
        XCTAssertEqual(Fmt.temperature(50, unit: .celsius), "50°")
        XCTAssertEqual(Fmt.temperature(50, unit: .fahrenheit), "122°")
        XCTAssertEqual(Fmt.temperature(50.25, unit: .celsius, decimals: true), "50.2°")
    }
}

final class CPUMathTests: XCTestCase {
    func testLoad() {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let b = CPUTicks(user: 150, system: 75, idle: 825, nice: 0)
        let load = CPUMath.load(previous: a, current: b)!
        XCTAssertEqual(load.user, 0.5, accuracy: 1e-9)
        XCTAssertEqual(load.system, 0.25, accuracy: 1e-9)
        XCTAssertEqual(load.usage, 0.75, accuracy: 1e-9)
    }

    func testNoElapsedTicksIsZero() {
        let a = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        XCTAssertEqual(CPUMath.load(previous: a, current: a)?.usage, 0)
    }

    func testCounterGoingBackwardsIsRejected() {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let b = CPUTicks(user: 10, system: 50, idle: 900, nice: 0)
        XCTAssertNil(CPUMath.load(previous: a, current: b))
    }

    func testAggregateWeightsCoresByTicks() {
        let prev = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let cur = [CPUTicks(user: 100, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let (total, cores) = CPUMath.aggregate(previous: prev, current: cur)!
        XCTAssertEqual(cores.map(\.usage), [1, 0])
        XCTAssertEqual(total.usage, 0.5, accuracy: 1e-9)
        XCTAssertNil(CPUMath.aggregate(previous: prev, current: [cur[0]]))
    }
}

final class MemoryMathTests: XCTestCase {
    func testActivityMonitorStyleUsedMemory() {
        var s = vm_statistics64()
        s.internal_page_count = 1000
        s.purgeable_count = 100
        s.wire_count = 200
        s.compressor_page_count = 50
        s.external_page_count = 300
        s.free_count = 400
        let r = MemoryMath.reading(stats: s, pageSize: 16384, total: 16384 * 2000)
        XCTAssertEqual(r.app, 900 * 16384)
        XCTAssertEqual(r.wired, 200 * 16384)
        XCTAssertEqual(r.compressed, 50 * 16384)
        XCTAssertEqual(r.cached, 400 * 16384)
        XCTAssertEqual(r.used, 1150 * 16384)
        XCTAssertEqual(r.available, 850 * 16384)
        XCTAssertEqual(r.usedFraction, 0.575, accuracy: 1e-9)
    }
}

final class NetworkMathTests: XCTestCase {
    func testDeltaIgnoresCounterReset() {
        XCTAssertEqual(NetworkMath.delta(previous: 100, current: 250), 150)
        XCTAssertEqual(NetworkMath.delta(previous: 1_000_000, current: 20), 0)
    }
}

final class SMCDecoderTests: XCTestCase {
    func testFourCC() {
        XCTAssertEqual(FourCC.string(FourCC.code("TC0P")), "TC0P")
        XCTAssertEqual(FourCC.code("flt "), 0x666C_7420)
    }

    func testDecodeTypes() {
        let f = Float(48.5).bitPattern
        let fltBytes = [UInt8(f & 0xff), UInt8(f >> 8 & 0xff), UInt8(f >> 16 & 0xff), UInt8(f >> 24 & 0xff)]
        XCTAssertEqual(SMCDecoder.decode(type: FourCC.code("flt "), size: 4, bytes: fltBytes), 48.5)
        XCTAssertEqual(SMCDecoder.decode(type: FourCC.code("sp78"), size: 2, bytes: [0x30, 0x80]), 48.5)
        XCTAssertEqual(SMCDecoder.decode(type: FourCC.code("fpe2"), size: 2, bytes: [0x1C, 0x20]), 1800)
        XCTAssertEqual(SMCDecoder.decode(type: FourCC.code("ui8 "), size: 1, bytes: [2]), 2)
        XCTAssertNil(SMCDecoder.decode(type: FourCC.code("hex_"), size: 1, bytes: [2]))
        XCTAssertNil(SMCDecoder.decode(type: FourCC.code("flt "), size: 2, bytes: [0, 0]))
    }

    func testClassification() {
        XCTAssertEqual(SMCDecoder.classify(key: "Tp01", isAppleSilicon: true), .cpu)
        XCTAssertEqual(SMCDecoder.classify(key: "Te05", isAppleSilicon: true), .cpu)
        XCTAssertEqual(SMCDecoder.classify(key: "Tg05", isAppleSilicon: true), .gpu)
        XCTAssertNil(SMCDecoder.classify(key: "TB0T", isAppleSilicon: true))
        XCTAssertEqual(SMCDecoder.classify(key: "TC0P", isAppleSilicon: false), .cpu)
        XCTAssertEqual(SMCDecoder.classify(key: "TG0D", isAppleSilicon: false), .gpu)
        XCTAssertNil(SMCDecoder.classify(key: "F0Ac", isAppleSilicon: false))
        XCTAssertFalse(SMCDecoder.isPlausibleTemperature(0))
        XCTAssertFalse(SMCDecoder.isPlausibleTemperature(200))
    }
}

final class SettingsTests: XCTestCase {
    func testLoadEntriesRepairsSavedOrder() throws {
        let saved = [MenuBarEntry(item: .network, enabled: true), MenuBarEntry(item: .network, enabled: false),
                     MenuBarEntry(item: .cpu, enabled: false)]
        let entries = AppSettings.loadEntries(try JSONEncoder().encode(saved))
        XCTAssertEqual(entries.first, MenuBarEntry(item: .network, enabled: true))
        XCTAssertEqual(entries.count, MenuBarItem.allCases.count)
        XCTAssertEqual(Set(entries.map(\.item)), Set(MenuBarItem.allCases))
        XCTAssertEqual(AppSettings.loadEntries(Data("garbage".utf8)), AppSettings.defaultEntries)
    }

    func testPersistence() {
        let defaults = UserDefaults(suiteName: "zest.tests.\(UUID().uuidString)")!
        let a = AppSettings(defaults: defaults)
        a.refreshInterval = 2
                a.menuBarEntries[0].enabled = false
        let b = AppSettings(defaults: defaults)
        XCTAssertEqual(b.refreshInterval, 2)
        XCTAssertEqual(b.menuBarEntries, a.menuBarEntries)
    }
}

final class MenuBarContentTests: XCTestCase {
    func testUnavailableSensorsShowNA() {
        let snapshot = Snapshot(cpu: nil, memory: nil, network: nil, disk: nil,
                                sensors: SensorReading(cpuTemperature: nil, cpuTemperatureMax: nil, gpuTemperature: nil,
                                                       temperatureStatus: .unavailable, fans: [], fanStatus: .noSensor),
                                selfUsage: nil, thermalState: .nominal)
        let segs = MenuBarContent.segments(for: [.temperature, .fan, .cpu], snapshot: snapshot, unit: .celsius)
        XCTAssertEqual(segs, [.metric(item: .temperature, value: "N/A", label: "TEMP"),
                              .metric(item: .fan, value: "N/A", label: "RPM"),
                              .metric(item: .cpu, value: "--", label: "CPU")])
    }

    func testLemonStyleSpeedFormatting() {
        XCTAssertEqual(MenuBarContent.speed(0), SpeedText(number: "0.0", unit: " K/s"))
        XCTAssertEqual(MenuBarContent.speed(20.5 * 1024), SpeedText(number: "20.5", unit: " K/s"))
        XCTAssertEqual(MenuBarContent.speed(257 * 1024), SpeedText(number: "257", unit: " K/s"))
        XCTAssertEqual(MenuBarContent.speed(1500 * 1024), SpeedText(number: "1.5", unit: " M/s"))
        XCTAssertEqual(MenuBarContent.speed(-5), SpeedText(number: "0.0", unit: " K/s"))
    }

    func testRendererRasterizesAtScreenScale() {
        let renderer = MenuBarRenderer()
        let segments: [MenuBarSegment] = [.metric(item: .cpu, value: "100%", label: "CPU")]
        for scale: CGFloat in [1, 2] {
            let image = renderer.render(segments, height: 22, scale: scale)!
            let bitmap = image.representations.first as? NSBitmapImageRep
            XCTAssertEqual(image.representations.count, 1)
            XCTAssertNotNil(bitmap)
            XCTAssertEqual(bitmap?.pixelsWide, Int(image.size.width * scale))
            XCTAssertEqual(bitmap?.pixelsHigh, Int(22 * scale))
            XCTAssertEqual(bitmap?.size, image.size)
            XCTAssertTrue(image.isTemplate)
        }
        XCTAssertNil(renderer.render(segments, height: 0))
        XCTAssertNil(renderer.render(segments, height: 22, scale: 0))
    }

    func testRendererProducesStableTemplateImage() {
        let r = MenuBarRenderer()
        let a = r.render([.metric(item: .cpu, value: "1%", label: "CPU"),
                          .rates(up: SpeedText(number: "0.0", unit: " K/s"), down: SpeedText(number: "1.2", unit: " K/s"))],
                         height: 22)
        let b = r.render([.metric(item: .cpu, value: "100%", label: "CPU"),
                          .rates(up: SpeedText(number: "999", unit: " M/s"), down: SpeedText(number: "257", unit: " K/s"))],
                         height: 22)
        XCTAssertNotNil(a)
        XCTAssertTrue(a!.isTemplate)
        // 数值变化不应改变宽度（防抖动）。
        XCTAssertEqual(a!.size.width, b!.size.width)
        XCTAssertNil(r.render([], height: 22))
    }
}

final class SMCSpreadTests: XCTestCase {
    func testSpreadPicksEvenlyAndKeepsShortLists() {
        XCTAssertEqual(SMCSensors.spread([1, 2, 3], limit: 5), [1, 2, 3])
        XCTAssertEqual(SMCSensors.spread(Array(0..<12), limit: 4), [0, 3, 6, 9])
        XCTAssertEqual(SMCSensors.spread(Array(0..<37), limit: 12).count, 12)
    }
}

final class ConnectionTests: XCTestCase {
    func testIPv4Scopes() {
        func v4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> AddressScope {
            AddressClassifier.scope(ipv4: a << 24 | b << 16 | c << 8 | d)
        }
        XCTAssertEqual(v4(127, 0, 0, 1), .loopback)
        XCTAssertEqual(v4(192, 168, 1, 2), .lan)
        XCTAssertEqual(v4(10, 0, 0, 1), .lan)
        XCTAssertEqual(v4(172, 20, 0, 1), .lan)
        XCTAssertEqual(v4(172, 32, 0, 1), .internet)
        XCTAssertEqual(v4(198, 18, 0, 84), .reserved)
        XCTAssertEqual(v4(8, 8, 8, 8), .internet)
    }

    func testIPv6Scopes() {
        var loop = [UInt8](repeating: 0, count: 16); loop[15] = 1
        XCTAssertEqual(AddressClassifier.scope(ipv6: loop), .loopback)
        var linkLocal = [UInt8](repeating: 0, count: 16); linkLocal[0] = 0xfe; linkLocal[1] = 0x80
        XCTAssertEqual(AddressClassifier.scope(ipv6: linkLocal), .lan)
        var mapped = [UInt8](repeating: 0, count: 16); mapped[10] = 0xff; mapped[11] = 0xff
        mapped[12] = 8; mapped[13] = 8; mapped[14] = 8; mapped[15] = 8
        XCTAssertEqual(AddressClassifier.scope(ipv6: mapped), .internet)
        var global = [UInt8](repeating: 0, count: 16); global[0] = 0x24; global[1] = 0x08
        XCTAssertEqual(AddressClassifier.scope(ipv6: global), .internet)
    }

    func testOutermostAppGrouping() {
        XCTAssertEqual(ProcessOwners.outermostApp(path:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            "/Applications/Google Chrome.app")
        XCTAssertNil(ProcessOwners.outermostApp(path: "/usr/sbin/mDNSResponder"))
        XCTAssertNil(ProcessOwners.outermostApp(path: nil))
    }
}

final class ProcessTests: XCTestCase {
    func testCPUFraction() {
        XCTAssertEqual(ProcessMath.cpuFraction(previous: 1_000, current: 501_000, elapsedNanos: 1_000_000), 0.5)
        // 多线程进程可超过 100%。
        XCTAssertEqual(ProcessMath.cpuFraction(previous: 0, current: 2_000_000, elapsedNanos: 1_000_000), 2)
        XCTAssertEqual(ProcessMath.cpuFraction(previous: nil, current: 5, elapsedNanos: 10), 0)
        XCTAssertEqual(ProcessMath.cpuFraction(previous: 10, current: 5, elapsedNanos: 10), 0)
    }

    func testSortingAndTop() {
        func app(_ name: String, cpu: Double, mem: UInt64) -> AppUsage {
            AppUsage(key: name, bundlePath: nil, name: name, kind: .app,
                     processes: [ProcessUsage(pid: 1, name: name, cpu: cpu, memory: mem)], isProtected: false)
        }
        let r = ProcessesReading(apps: [app("a", cpu: 0.1, mem: 300), app("b", cpu: 0.9, mem: 100), app("c", cpu: 0.5, mem: 200)],
                                 inaccessibleProcesses: 0, hasCPU: true)
        XCTAssertEqual(r.top(by: .cpu, limit: 2).map(\.name), ["b", "c"])
        XCTAssertEqual(r.top(by: .memory, limit: 2).map(\.name), ["a", "c"])
    }

    func testLiveSamplerSeesOwnProcessProtected() throws {
        let sampler = ProcessSampler()
        _ = sampler.sample()
        let r = sampler.sample()
        XCTAssertTrue(r.hasCPU)
        let mine = try XCTUnwrap(r.apps.first { $0.processes.contains { $0.pid == getpid() } })
        XCTAssertTrue(mine.isProtected, "Zest 自身不应提供结束操作")
        XCTAssertGreaterThan(mine.memory, 1_000_000)
        XCTAssertTrue(ProcessMath.protectedNames.contains("loginwindow"))
    }
}

final class ProcessQuitTests: XCTestCase {
    func testQuitAndForceQuitEndRealProcesses() throws {
        for force in [false, true] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["300"]
            try child.run()
            let sampler = ProcessSampler()
            let app = try XCTUnwrap(sampler.sample().apps.first { $0.processes.contains { $0.pid == child.processIdentifier } })
            XCTAssertFalse(app.isProtected)
            let target = AppUsage(key: app.key, bundlePath: app.bundlePath, name: app.name, kind: app.kind,
                                  processes: app.processes.filter { $0.pid == child.processIdentifier }, isProtected: false)
            let monitor = ProcessMonitor()
            force ? monitor.forceQuit(target) : monitor.quit(target)
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .uncaughtSignal)
            XCTAssertEqual(child.terminationStatus, force ? SIGKILL : SIGTERM)
        }
    }
}

final class ProcessKindTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(ProcessOwners.kind(bundlePath: "/Applications/Google Chrome.app", executablePath: nil), .app)
        XCTAssertEqual(ProcessOwners.kind(bundlePath: "/System/Applications/Notes.app", executablePath: nil), .app)
        XCTAssertEqual(ProcessOwners.kind(bundlePath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
                                          executablePath: nil), .app)
        XCTAssertEqual(ProcessOwners.kind(bundlePath: "/System/Library/CoreServices/Finder.app", executablePath: nil), .app)
        XCTAssertEqual(ProcessOwners.kind(bundlePath: "/System/Library/CoreServices/Dock.app", executablePath: nil), .system)
        XCTAssertEqual(ProcessOwners.kind(bundlePath: nil, executablePath: "/usr/libexec/avconferenced"), .system)
        XCTAssertEqual(ProcessOwners.kind(bundlePath: nil, executablePath: "/System/Library/PrivateFrameworks/X.framework/x"), .system)
        XCTAssertEqual(ProcessOwners.kind(bundlePath: nil, executablePath: "/opt/homebrew/bin/node"), .commandLine)
        XCTAssertEqual(ProcessOwners.kind(bundlePath: nil, executablePath: nil), .system)
    }
}

final class FrozenOrderTests: XCTestCase {
    private func app(_ name: String, cpu: Double) -> AppUsage {
        AppUsage(key: name, bundlePath: nil, name: name, kind: .app,
                 processes: [ProcessUsage(pid: 1, name: name, cpu: cpu, memory: 1)], isProtected: false)
    }

    func testOrderStaysPutWhileFrozenEvenIfValuesChange() {
        var frozen = FrozenOrder()
        frozen.freeze(["a", "b", "c"])
        // 刷新后排序变为 c, a, b，并新出现 d —— 冻结期间仍保持 a, b, c，d 排在最后。
        let refreshed = [app("c", cpu: 0.9), app("d", cpu: 0.8), app("a", cpu: 0.5), app("b", cpu: 0.1)]
        XCTAssertEqual(frozen.apply(refreshed).map(\.name), ["a", "b", "c", "d"])
        // 数值是最新的。
        XCTAssertEqual(frozen.apply(refreshed).first?.cpu, 0.5)
        frozen.release()
        XCTAssertEqual(frozen.apply(refreshed).map(\.name), ["c", "d", "a", "b"])
    }
}
