import XCTest
@testable import Zest

final class SelfUsageAccountingTests: XCTestCase {
    func testRunningChildIsNotBilledAgainWhenItExits() throws {
        let sampler = SelfUsageSampler()
        _ = sampler.sample()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        sampler.childPIDs = [child.processIdentifier]
        Thread.sleep(forTimeInterval: 0.25)
        let running = sampler.sample()
        XCTAssertGreaterThan(try XCTUnwrap(running.childCPU), 0.1, "子进程运行期间就应该计入 CPU")
        child.terminate()
        child.waitUntilExit()
        sampler.childPIDs = []
        Thread.sleep(forTimeInterval: 0.1)
        let after = sampler.sample()
        XCTAssertLessThan(try XCTUnwrap(after.childCPU), 0.5, "退出时不应再次集中计入子进程整个生命周期的 CPU")
        XCTAssertEqual(after.cpu, (after.processCPU ?? 0) + (after.childCPU ?? 0), accuracy: 0.0001)
    }
}
