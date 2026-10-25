import XCTest
@testable import Zest

final class PerformanceLogTests: XCTestCase {
    func testRotationKeepsTwoBoundedValidJSONFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = PerformanceLog(directory: directory, role: "test", maxBytes: 1024)
        for index in 0..<40 { log.event("test", ["index": index, "detail": String(repeating: "x", count: 120)]) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        var indices: [Int] = []
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 1024)
            for line in data.split(separator: 0x0a) {
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                XCTAssertEqual(row["event"] as? String, "test")
                XCTAssertNotNil(row["timestamp"])
                indices.append(try XCTUnwrap(row["index"] as? Int))
            }
        }
        XCTAssertEqual(indices.max(), 39)
        XCTAssertEqual(indices.count, Set(indices).count)
    }

    func testSpikesAndSlowStagesAreRateLimited() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = PerformanceLog(directory: directory, role: "test")
        for _ in 0..<20 {
            log.sample(SelfUsage(cpu: 0.25, memory: 1024), panelVisible: true, tab: "processes", refreshInterval: 1)
            log.timing("process_sample", since: DispatchTime.now().uptimeNanoseconds - 30_000_000)
        }
        log.flush()
        let data = try Data(contentsOf: directory.appendingPathComponent("performance-test.jsonl"))
        let rows = try data.split(separator: 0x0a).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(rows.filter { $0["event"] as? String == "cpu_spike" }.count, 1)
        XCTAssertEqual(rows.filter { $0["event"] as? String == "slow_stage" }.count, 1)
        XCTAssertEqual(rows.filter { $0["event"] as? String == "health" }.count, 1)
    }
}
