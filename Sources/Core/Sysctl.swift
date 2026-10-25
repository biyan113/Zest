//
//  Sysctl.swift
//  Zest
//

import Foundation

enum Sysctl {
    static func value<T>(_ name: String, as _: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard sysctlbyname(name, ptr, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return ptr.load(as: T.self)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func int32(_ name: String) -> Int? { value(name, as: Int32.self).map(Int.init) }
    static func uint64(_ name: String) -> UInt64? { value(name, as: UInt64.self) }
}
