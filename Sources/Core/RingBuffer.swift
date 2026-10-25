//
//  RingBuffer.swift
//  Zest
//

import Foundation

/// 定长环形缓冲区，用于迷你趋势图。追加为 O(1)，不产生额外分配。
struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    var last: Element? {
        count == 0 ? nil : storage[(head - 1 + capacity) % capacity]
    }

    /// 按时间顺序（旧 → 新）返回元素。
    var elements: [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        let start = (head - count + capacity) % capacity
        for i in 0..<count {
            if let e = storage[(start + i) % capacity] { result.append(e) }
        }
        return result
    }
}
