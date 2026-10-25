//
//  SamplerSmokeTests.swift
//  ZestTests
//
//  在真实机器上运行采集器，检查数值落在合理范围内。
//

import XCTest
@testable import Zest

final class SamplerSmokeTests: XCTestCase {
    func testCPU() throws {
        let sampler = CPUSampler()
        Thread.sleep(forTimeInterval: 0.2)
        let r = try XCTUnwrap(sampler.sample())
        XCTAssertEqual(r.cores.count, ProcessInfo.processInfo.processorCount)
        XCTAssert((0...1).contains(r.usage))
        XCTAssertEqual(sampler.coreKinds.count, r.cores.count)
        #if arch(arm64)
        XCTAssertFalse(sampler.coreKinds.contains(.unknown), "Apple Silicon 应能从 IODeviceTree 读出核心类型")
        #endif
    }

    func testMemory() throws {
        let r = try XCTUnwrap(MemorySampler().sample())
        XCTAssertEqual(r.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(r.used, 0)
        XCTAssertLessThanOrEqual(r.used, r.total)
        XCTAssertNotNil(r.pressureLevel)
        if let p = r.pressure { XCTAssert((0...1).contains(p)) }
    }

    func testNetwork() throws {
        let sampler = NetworkSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let r = try XCTUnwrap(sampler.sample())
        XCTAssertGreaterThanOrEqual(r.downloadRate, 0)
        XCTAssertGreaterThanOrEqual(r.uploadRate, 0)
        XCTAssertGreaterThanOrEqual(r.bootDownload, r.sessionDownload)
    }

    func testDisk() throws {
        let sampler = DiskSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let r = sampler.sample()
        let total = try XCTUnwrap(r.total)
        let available = try XCTUnwrap(r.available)
        XCTAssertGreaterThan(total, 1_000_000_000)
        XCTAssertLessThanOrEqual(available, total)
        XCTAssertGreaterThanOrEqual(r.readRate, 0)
    }

    func testSensorsNeverFabricate() {
        let r = SMCSensors().sample()
        switch r.temperatureStatus {
        case .available:
            let t = try! XCTUnwrap(r.cpuTemperature)
            XCTAssert(SMCDecoder.isPlausibleTemperature(t))
            XCTAssertGreaterThanOrEqual(r.cpuTemperatureMax!, t)
        case .noSensor, .unavailable:
            XCTAssertNil(r.cpuTemperature)
        }
        if r.fanStatus != .available { XCTAssertTrue(r.fans.isEmpty) }
        r.fans.forEach { XCTAssertGreaterThanOrEqual($0.rpm, 0) }
    }

    /// 一次完整采样的耗时预算（不含首次 SMC 枚举）。
    func testSamplingCostIsSmall() {
        let cpu = CPUSampler(), mem = MemorySampler(), net = NetworkSampler(), disk = DiskSampler(), smc = SMCSensors()
        _ = smc.sample(); _ = disk.sample()
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            _ = cpu.sample(); _ = mem.sample(); _ = net.sample(); _ = disk.sample(); _ = smc.sample()
        }
    }
}
