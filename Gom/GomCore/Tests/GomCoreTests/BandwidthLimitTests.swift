import Foundation
import Synchronization
import Testing
@testable import GomCore

/// Timing-based: run serialized so parallel suites don't skew the clock much.
@Suite(.serialized) struct BandwidthLimitTests {
    let noDelay: @Sendable (Int) -> Duration = { _ in .zero }
    let size = Int(minSegmentedSize)   // smallest file that is split into 8 segments

    /// Bytes asked for by each non-probe range request.
    func requestedLengths(_ file: MockFile) -> [Int] {
        file.requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
            .filter { $0 != "bytes=0-0" }
            .compactMap { MockURLProtocol.parseRange($0, total: Int.max) }
            .map { $0.1 - $0.0 + 1 }
    }

    @Test func combinedSpeedStaysNearTheLimit() async throws {
        let dir = try makeTempDir()
        let data = testData(size)
        let (url, file) = MockServer.serve(.init(data: data, chunkSize: 16 * 1024))
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
        #expect(requestedLengths(file).allSatisfy { $0 <= pieceSize(for: 500_000) })
    }

    @Test func raisingTheLimitAppliesToRunningDownloads() async throws {
        let dir = try makeTempDir()
        let (url, _) = MockServer.serve(.init(data: testData(size), chunkSize: 16 * 1024))
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

    @Test func settingALimitSplitsRunningDownloadsIntoPieces() async throws {
        let dir = try makeTempDir()
        let data = testData(size)
        // ~400 KB/s per segment unlimited, so it is still running when the limit arrives.
        let (url, file) = MockServer.serve(.init(data: data, chunkSize: 4 * 1024, chunkDelay: 0.01))
        let streamer = MockServer.streamer()
        let noDelay = noDelay

        let task = Task { await runDownload(DownloadRecord(url: url, directory: dir), streamer: streamer, retryDelay: noDelay) }
        try await Task.sleep(for: .milliseconds(200))
        let before = requestedLengths(file).count
        streamer.bytesPerSecond = 1_000_000
        let result = await task.value

        #expect(result.state == .completed)
        #expect(try Data(contentsOf: #require(result.fileURL)) == data)
        let after = requestedLengths(file).dropFirst(before)
        #expect(!after.isEmpty)
        #expect(after.allSatisfy { $0 <= pieceSize(for: 1_000_000) })
    }

    @Test func serverWithoutRangesIsPacedToo() async throws {
        let dir = try makeTempDir()
        let data = testData(500_000)
        let (url, _) = MockServer.serve(.init(data: data, supportsRanges: false, chunkSize: 16 * 1024))
        let streamer = MockServer.streamer()
        streamer.bytesPerSecond = 250_000

        let start = ContinuousClock.now
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: streamer, retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(try Data(contentsOf: #require(result.fileURL)) == data)
        #expect(ContinuousClock.now - start > .seconds(1.5))   // 2 s minus the burst
    }

    @Test func pausingWhileThrottledStopsPromptly() async throws {
        let dir = try makeTempDir()
        let (url, _) = MockServer.serve(.init(data: testData(size), chunkSize: 16 * 1024))
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

    @Test func limiterPacesReservationsAndWakesOnRateChange() async throws {
        let limiter = BandwidthLimiter()
        limiter.bytesPerSecond = 100_000
        let start = ContinuousClock.now
        for _ in 0..<3 { try await limiter.acquire(50_000) }   // 150 KB at 100 KB/s, minus the burst
        #expect(ContinuousClock.now - start > .seconds(0.6))

        let waiter = Task { try await limiter.acquire(1_000_000) }   // would wait ~10 s
        try await Task.sleep(for: .milliseconds(100))
        limiter.bytesPerSecond = 0
        let woke = ContinuousClock.now
        try await waiter.value
        #expect(ContinuousClock.now - woke < .milliseconds(300))
    }
}
