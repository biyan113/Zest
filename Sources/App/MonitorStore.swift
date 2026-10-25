//
//  MonitorStore.swift
//  Zest
//
//  保存最新快照与趋势历史。只有面板可见时才通知 SwiftUI 重绘，关闭面板后零 UI 开销。
//

import Combine
import Foundation

final class MonitorStore: ObservableObject {
    static let historyLength = 60

    private(set) var snapshot: Snapshot?
    private(set) var coreKinds: [CoreKind] = []

    private(set) var cpuHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var memoryHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var downloadHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var uploadHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var diskReadHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var diskWriteHistory = RingBuffer<Double>(capacity: historyLength)
    private(set) var temperatureHistory = RingBuffer<Double>(capacity: historyLength)

    var isPanelVisible = false {
        didSet { if isPanelVisible && !oldValue { objectWillChange.send() } }
    }

    func setCoreKinds(_ kinds: [CoreKind]) { coreKinds = kinds }

    func ingest(_ s: Snapshot) {
        snapshot = s
        if let cpu = s.cpu { cpuHistory.append(cpu.usage) }
        if let m = s.memory { memoryHistory.append(m.usedFraction) }
        if let n = s.network {
            downloadHistory.append(n.downloadRate)
            uploadHistory.append(n.uploadRate)
        }
        if let d = s.disk {
            diskReadHistory.append(d.readRate)
            diskWriteHistory.append(d.writeRate)
        }
        if let t = s.sensors?.cpuTemperature { temperatureHistory.append(t) }
        if isPanelVisible { objectWillChange.send() }
    }

    func resetHistory() {
        cpuHistory.removeAll(); memoryHistory.removeAll()
        downloadHistory.removeAll(); uploadHistory.removeAll()
        diskReadHistory.removeAll(); diskWriteHistory.removeAll()
        temperatureHistory.removeAll()
    }
}
