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
}
