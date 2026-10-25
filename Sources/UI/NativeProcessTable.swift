import AppKit
import SwiftUI

/// 高频变化的进程表使用 AppKit 复用单元格；不为每个采样重新构造 SwiftUI 行树。
struct NativeProcessTable: NSViewRepresentable {
    var apps: [AppUsage]
    var metric: ProcessMetric
    var hasCPU: Bool
    var showKind: Bool
    var monitor: ProcessMonitor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let table = NSOutlineView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizesOutlineColumn = false
        table.autoresizingMask = [.width]
        table.indentationPerLevel = 12
        for (id, width) in [("name", CGFloat(160)), ("cpu", 52), ("memory", 64), ("action", 22)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = id == "name" ? 60 : width
            column.maxWidth = id == "name" ? 1000 : width
            column.resizingMask = id == "name" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.outlineTableColumn = table.tableColumns.first
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        let menu = NSMenu()
        let action = NSMenuItem(title: L10n.text("退出、强制退出…"), action: #selector(Coordinator.contextAction(_:)), keyEquivalent: "")
        action.target = context.coordinator
        menu.addItem(action)
        table.menu = menu
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.update(self) }

    final class Row: NSObject {
        var app: AppUsage
        var process: ProcessUsage?
        var children: [Row] = []
        init(app: AppUsage, process: ProcessUsage? = nil) { self.app = app; self.process = process }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var value: NativeProcessTable
        weak var table: NSOutlineView?
        private var rows: [Row] = []
        private var indexed: [String: Row] = [:]

        init(_ value: NativeProcessTable) { self.value = value }

        func update(_ value: NativeProcessTable) {
            let start = DispatchTime.now().uptimeNanoseconds
            defer { PerformanceLog.shared.timing("process_table_update", since: start) }
            guard let table else { return }
            let oldIDs = rows.map { $0.app.id }
            let expanded = Set(rows.filter { table.isItemExpanded($0) }.map { $0.app.id })
            var structureChanged = oldIDs != value.apps.map(\.id)
            self.value = value
            rows = value.apps.map { app in
                let row = indexed[app.id] ?? Row(app: app)
                if (row.children.count > 1) != (app.processes.count > 1) ||
                    (expanded.contains(app.id) && row.children.map({ $0.process!.pid }) != app.processes.map(\.pid)) {
                    structureChanged = true
                }
                row.app = app
                let oldChildren = Dictionary(uniqueKeysWithValues: row.children.map { ($0.process!.pid, $0) })
                row.children = app.processes.map { process in
                    let child = oldChildren[process.pid] ?? Row(app: app, process: process)
                    child.app = app; child.process = process
                    return child
                }
                return row
            }
            indexed = Dictionary(uniqueKeysWithValues: rows.map { ($0.app.id, $0) })
            if structureChanged {
                let origin = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
                table.reloadData()
                for row in rows where expanded.contains(row.app.id) { table.expandItem(row) }
                table.enclosingScrollView?.contentView.scroll(to: origin)
                table.enclosingScrollView?.reflectScrolledClipView(table.enclosingScrollView!.contentView)
            } else {
                let visible = table.rows(in: table.visibleRect)
                guard visible.location != NSNotFound else { return }
                for index in visible.location..<min(NSMaxRange(visible), table.numberOfRows) {
                    guard let row = table.item(atRow: index) as? Row else { continue }
                    for column in table.tableColumns.indices {
                        if let cell = table.view(atColumn: column, row: index, makeIfNecessary: false) as? ProcessTableCell {
                            configure(cell, row: row, column: table.tableColumns[column].identifier.rawValue)
                        }
                    }
                }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let row = item as? Row else { return rows.count }
            return row.process == nil && row.children.count > 1 ? row.children.count : 0
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Row)?.children[index] ?? rows[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let row = item as? Row else { return false }
            return row.process == nil && row.children.count > 1
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? Row)?.process == nil ? 36 : 22
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let row = item as? Row, let column = tableColumn?.identifier else { return nil }
            let cell = (outlineView.makeView(withIdentifier: column, owner: nil) as? ProcessTableCell)
                ?? ProcessTableCell(column: column.rawValue)
            cell.identifier = column
            configure(cell, row: row, column: column.rawValue)
            return cell
        }

        private func configure(_ cell: ProcessTableCell, row: Row, column: String) {
            let process = row.process
            switch column {
            case "name":
                let title = process.map { "\($0.name) [\($0.pid)]" } ?? row.app.name
                let kind = value.showKind && row.app.kind != .app ? " · \(row.app.kind.title)" : ""
                cell.setText(title + kind, secondary: process.map { "PID \($0.pid)" }
                    ?? (row.children.count > 1 ? String(format: L10n.text("%lld 个进程"), Int64(row.children.count)) : ""))
                cell.lock.isHidden = !row.app.isProtected
                cell.icon.isHidden = process != nil
                if process == nil && cell.bundlePath != row.app.bundlePath {
                    cell.bundlePath = row.app.bundlePath
                    cell.icon.image = row.app.bundlePath.map { AppIcon.icon(for: $0) }
                        ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: L10n.text("命令行"))
                }
            case "cpu":
                cell.setText(value.hasCPU ? ProcessFmt.cpu(process?.cpu ?? row.app.cpu) : "…")
                cell.primary.textColor = value.metric == .cpu ? .systemBlue : .secondaryLabelColor
            case "memory":
                cell.setText(ProcessFmt.memory(process?.memory ?? row.app.memory))
                cell.primary.textColor = value.metric == .memory ? .labelColor : .secondaryLabelColor
            default:
                cell.action = { [weak self, weak row] in
                    guard let self, let row else { return }
                    self.showActions(row)
                }
            }
        }

        private func showActions(_ row: Row) {
            if let process = row.process {
                ProcessActionMenu.shared.show(for: process, protected: row.app.isProtected, monitor: value.monitor)
            } else {
                ProcessActionMenu.shared.show(for: row.app, monitor: value.monitor)
            }
        }
        @objc func contextAction(_ sender: Any?) {
            guard let table, let row = table.item(atRow: table.clickedRow) as? Row else { return }
            showActions(row)
        }
    }
}

final class ProcessTableCell: NSView {
    let primary = NSTextField(labelWithString: "")
    let secondary = NSTextField(labelWithString: "")
    let icon = NSImageView()
    let lock = NSImageView()
    let button = NSButton()
    var bundlePath: String? = ""
    var action: (() -> Void)?
    private let column: String

    init(column: String) {
        self.column = column
        super.init(frame: .zero)
        primary.font = column == "name" ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        primary.lineBreakMode = .byTruncatingTail
        primary.alignment = column == "name" ? .left : .right
        secondary.font = .systemFont(ofSize: 9.5)
        secondary.textColor = .tertiaryLabelColor
        secondary.lineBreakMode = .byTruncatingTail
        addSubview(primary)
        if column == "name" {
            addSubview(secondary); addSubview(icon); addSubview(lock)
            icon.imageScaling = .scaleProportionallyUpOrDown
            lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: L10n.text("受保护"))
            lock.contentTintColor = .tertiaryLabelColor
        } else if column == "action" {
            primary.isHidden = true
            button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L10n.text("退出或强制退出"))
            button.isBordered = false
            button.target = self; button.action = #selector(pressed)
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setText(_ text: String, secondary detail: String = "") {
        var changed = false
        if primary.stringValue != text { primary.stringValue = text; changed = true }
        if secondary.stringValue != detail { secondary.stringValue = detail; changed = true }
        if changed { needsLayout = true }
    }
    override func layout() {
        super.layout()
        let height = bounds.height
        if column == "name" {
            let leading: CGFloat = icon.isHidden ? 0 : 25
            let trailing: CGFloat = lock.isHidden ? 0 : 12
            icon.frame = NSRect(x: 0, y: (height-20)/2, width: 20, height: 20)
            lock.frame = NSRect(x: bounds.width-10, y: (height-10)/2, width: 9, height: 10)
            let width = max(0, bounds.width-leading-trailing)
            if height > 25 && !secondary.stringValue.isEmpty {
                primary.frame = NSRect(x: leading, y: 15, width: width, height: 16)
                secondary.frame = NSRect(x: leading, y: 2, width: width, height: 12)
                secondary.isHidden = false
            } else {
                primary.frame = NSRect(x: leading, y: (height-16)/2, width: width, height: 16)
                secondary.isHidden = true
            }
        } else {
            primary.frame = NSRect(x: 0, y: (height-16)/2, width: bounds.width, height: 16)
            button.frame = NSRect(x: 0, y: (height-20)/2, width: bounds.width, height: 20)
        }
    }
    @objc private func pressed() { action?() }
}
