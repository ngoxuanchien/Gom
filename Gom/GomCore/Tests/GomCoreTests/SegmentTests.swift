import Testing
@testable import GomCore

@Suite struct SegmentTests {
    @Test func eightContiguousSegmentsCoverLargeFile() {
        let total: Int64 = 10_000_003
        let segments = makeSegments(total: total)
        #expect(segments.count == 8)
        #expect(segments.first?.start == 0)
        #expect(segments.last?.end == total - 1)
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(b.start == a.end + 1)
        }
    }

    @Test func smallFileGetsOneSegment() {
        let total = minSegmentedSize - 1
        #expect(makeSegments(total: total) == [Segment(start: 0, end: total - 1)])
    }

    @Test func emptyFileIsImmediatelyComplete() {
        let allComplete = makeSegments(total: 0).allSatisfy(\.isComplete)
        #expect(allComplete)
    }

    @Test func progressHelpers() {
        var segment = Segment(start: 100, end: 199)
        #expect(segment.nextOffset == 100)
        #expect(!segment.isComplete)
        segment.done = 100
        #expect(segment.nextOffset == 200)
        #expect(segment.isComplete)
    }

    let mib: Int64 = 1024 * 1024

    @Test func splitTakesTheSecondHalfOfTheLargestRemainder() {
        var segments = [
            Segment(start: 0, end: 4 * mib - 1, done: 4 * mib),         // complete
            Segment(start: 4 * mib, end: 8 * mib - 1, done: mib),      // 3 MiB left
            Segment(start: 8 * mib, end: 12 * mib - 1, done: 2 * mib), // 2 MiB left
        ]
        let new = splitLargest(&segments)

        #expect(new == 3)
        let mid = 5 * mib + 3 * mib / 2
        #expect(segments[1] == Segment(start: 4 * mib, end: mid - 1, done: mib))
        #expect(segments[3] == Segment(start: mid, end: 8 * mib - 1))
        #expect(coversContiguously(segments, total: 12 * mib))
    }

    @Test func splitBreaksTiesByLowestIndex() {
        var segments = [Segment(start: 0, end: 2 * mib - 1), Segment(start: 2 * mib, end: 4 * mib - 1)]
        #expect(splitLargest(&segments) == 2)
        #expect(segments[0].end == mib - 1)
        #expect(segments[1].end == 4 * mib - 1)
    }

    @Test func splitNeedsOneMebibyteLeft() {
        var small = [Segment(start: 0, end: minSplitRemainder - 2)]   // 1 MiB - 1 byte left
        #expect(splitLargest(&small) == nil)
        #expect(small.count == 1)

        var exact = [Segment(start: 0, end: minSplitRemainder - 1)]
        #expect(splitLargest(&exact) == 1)
        #expect(exact[0].remaining == minSplitRemainder / 2)
        #expect(exact[1].remaining == minSplitRemainder / 2)
    }

    @Test func completedSegmentsAreNeverSplit() {
        var segments = [Segment(start: 0, end: 4 * mib - 1, done: 4 * mib)]
        #expect(splitLargest(&segments) == nil)
    }
}
