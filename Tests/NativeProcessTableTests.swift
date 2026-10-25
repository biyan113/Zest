import AppKit
import XCTest
@testable import Zest

final class NativeProcessTableTests: XCTestCase {
    func testUpdatesReuseRowsAndApplicationExitRemovesChildren() {
        let monitor = ProcessMonitor()
        func app(_ key: String, _ pids: [pid_t], cpu: Double = 0) -> AppUsage {
            AppUsage(key: key, bundlePath: nil, name: key, kind: .commandLine,
                processes: pids.map { ProcessUsage(pid: $0, name: key, cpu: cpu, memory: 1024) }, isProtected: true)
        }
        var value = NativeProcessTable(apps: [app("a", [10001,10002]), app("b", [10003])],
                                       metric: .cpu, hasCPU: true, showKind: false, monitor: monitor)
        let coordinator = NativeProcessTable.Coordinator(value)
        let table = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        table.addTableColumn(column); table.outlineTableColumn = column
        table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.update(value)
        XCTAssertEqual(table.numberOfRows, 2)
        let root = table.item(atRow: 0) as! NativeProcessTable.Row
        table.expandItem(root)
        XCTAssertEqual(table.numberOfRows, 4)
        value.apps[0] = app("a", [10001,10002], cpu: 0.2)
        coordinator.update(value)
        XCTAssertTrue((table.item(atRow: 0) as AnyObject) === root)
        XCTAssertEqual(root.children[0].process?.cpu, 0.2)
        XCTAssertTrue(table.isItemExpanded(root))
        value.apps.removeFirst()
        coordinator.update(value)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual((table.item(atRow: 0) as? NativeProcessTable.Row)?.app.id, "b")
    }
}
