import Foundation
import Synchronization
import Testing
@testable import GomCore

/// Timing-based: run serialized so parallel suites don't skew the clock much.
@Suite(.serialized) struct BandwidthLimitTests {
    let noDelay: @Sendable (Int) -> Duration = { _ in .zero }
    let size = Int(minSegmentedSize)   // smallest file that is split into 8 segments

    @Test func combinedSpeedStaysNearTheLimit() async throws {
        let dir = try makeTempDir()
        let data = testData(size)
        let (url, _) = MockServer.serve(.init(data: data, chunkSize: 16 * 1024, chunkDelay: 0.001))
        let streamer = MockServer.streamer()
        streamer.bytesPerSecond = 500_000

        let start = ContinuousClock.now
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: streamer, retryDelay: noDelay)
        let elapsed = ContinuousClock.now - start

        #expect(result.state == .completed)
        #expect(result.segments.count == 8)
        #expect(try Data(contentsOf: #require(result.fileURL)) == data)
        // 2 097 152 bytes at 500 000 B/s ≈ 4.2 s, minus the 0.25 s burst.
        #expect(elapsed > .seconds(3.5) && elapsed < .seconds(5), "took \(elapsed)")
    }

    @Test func raisingTheLimitAppliesToRunningDownloads() async throws {
        let dir = try makeTempDir()
        let (url, _) = MockServer.serve(.init(data: testData(size), chunkSize: 16 * 1024, chunkDelay: 0.001))
        let streamer = MockServer.streamer()
        streamer.bytesPerSecond = 100_000   // would take ~21 s
        let noDelay = noDelay

        let done = Mutex(false)
        let start = ContinuousClock.now
        let task = Task {
            let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: streamer, retryDelay: noDelay)
            done.withLock { $0 = true }
            return result
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!done.withLock { $0 }, "the limit should still be holding it back")
        streamer.bytesPerSecond = 0
        let result = await task.value

        #expect(result.state == .completed)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func pausingWhileThrottledStopsPromptly() async throws {
        let dir = try makeTempDir()
        let (url, _) = MockServer.serve(.init(data: testData(size), chunkSize: 16 * 1024, chunkDelay: 0.001))
        let streamer = MockServer.streamer()
        streamer.bytesPerSecond = 50_000
        let noDelay = noDelay

        let task = Task { await runDownload(DownloadRecord(url: url, directory: dir), streamer: streamer, retryDelay: noDelay) }
        try await Task.sleep(for: .milliseconds(300))
        let cancelled = ContinuousClock.now
        task.cancel()
        let result = await task.value

        #expect(result.state == .paused)
        #expect(ContinuousClock.now - cancelled < .seconds(1))
    }
}
