import Foundation

/// A byte range `[start, end]` (inclusive) of the target file, plus how many bytes of it are on disk.
public struct Segment: Codable, Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var done: Int64

    public init(start: Int64, end: Int64, done: Int64 = 0) {
        self.start = start
        self.end = end
        self.done = done
    }

    public var nextOffset: Int64 { start + done }
    public var isComplete: Bool { nextOffset > end }
}

public let defaultSegmentCount = 8
public let minSegmentedSize: Int64 = 2 * 1024 * 1024

/// Splits `[0, total)` into contiguous segments; the last one absorbs the remainder.
public func makeSegments(total: Int64, count: Int = defaultSegmentCount) -> [Segment] {
    let n = total < minSegmentedSize ? 1 : Int64(count)
    let size = total / n
    return (0..<n).map { i in
        let start = i * size
        let end = i == n - 1 ? total - 1 : start + size - 1
        return Segment(start: start, end: end)
    }
}
