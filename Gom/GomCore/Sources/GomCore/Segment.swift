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
    var remaining: Int64 { end - nextOffset + 1 }
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

/// A segment is split only when at least this much of it is left, so each half gets 512 KiB or more.
public let minSplitRemainder: Int64 = 1024 * 1024

/// Cuts the unfinished segment with the most bytes left in two and appends the second half.
/// Returns the new segment's index, or nil if no segment has `minSplitRemainder` left.
/// Existing indexes don't change, so a connection working on the shrunk segment keeps its index.
func splitLargest(_ segments: inout [Segment]) -> Int? {
    // max(by:) keeps the first of equal elements: ties go to the lowest index.
    guard let victim = segments.indices.max(by: { segments[$0].remaining < segments[$1].remaining }),
          segments[victim].remaining >= minSplitRemainder else { return nil }
    let mid = segments[victim].nextOffset + segments[victim].remaining / 2
    segments.append(Segment(start: mid, end: segments[victim].end))
    segments[victim].end = mid - 1
    return segments.count - 1
}
