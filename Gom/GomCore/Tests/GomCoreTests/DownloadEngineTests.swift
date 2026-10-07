import Foundation
import Testing
@testable import GomCore

@Suite struct DownloadEngineTests {
    let noDelay: @Sendable (Int) -> Duration = { _ in .zero }

    func contents(_ record: DownloadRecord) throws -> Data {
        try Data(contentsOf: #require(record.fileURL))
    }

    func leftoverTempFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).filter { $0.hasSuffix(".gomdownload") }
    }

    /// Starts a slow download, cancels it after `after`, returns the paused record.
    func startAndPause(_ config: MockFile.Config, dir: URL, after: Duration = .milliseconds(200)) async throws -> (DownloadRecord, MockFile, HTTPStreamer) {
        let (url, file) = MockServer.serve(config)
        let streamer = MockServer.streamer()
        let noDelay = noDelay
        let task = Task { await runDownload(DownloadRecord(url: url, directory: dir), streamer: streamer, retryDelay: noDelay) }
        try await Task.sleep(for: after)
        task.cancel()
        return (await task.value, file, streamer)
    }

    @Test func segmentedDownloadProducesIdenticalFile() async throws {
        let dir = try makeTempDir()
        let data = testData(5_000_000)
        let (url, file) = MockServer.serve(.init(data: data))
        let record = DownloadRecord(url: url, headers: ["Cookie": "s=1"], directory: dir)

        let result = await runDownload(record, streamer: MockServer.streamer(), retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(try contents(result) == data)
        #expect(result.filename == "file.bin")
        #expect(result.headers.isEmpty)
        #expect(file.requests.count == 1 + 8)   // probe + 8 segments
        let allSentCookie = file.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "s=1" }
        #expect(allSentCookie)
        #expect(try leftoverTempFiles(dir).isEmpty)
    }

    @Test func serverWithoutRangesUsesSingleConnection() async throws {
        let dir = try makeTempDir()
        let data = testData(3_000_000)
        let (url, file) = MockServer.serve(.init(data: data, supportsRanges: false))

        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(result.resumable == false)
        #expect(try contents(result) == data)
        #expect(file.requests.count == 2)   // probe + one full GET
    }

    @Test func emptyFileCompletes() async throws {
        let dir = try makeTempDir()
        let (url, _) = MockServer.serve(.init(data: Data()))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)
        #expect(result.state == .completed)
        #expect(try contents(result).isEmpty)
    }

    @Test func pauseThenResumeContinuesWhereItStopped() async throws {
        let dir = try makeTempDir()
        let data = testData(5_000_000)
        let (paused, file, streamer) = try await startAndPause(.init(data: data, chunkDelay: 0.05), dir: dir)

        #expect(paused.state == .paused)
        #expect(paused.downloadedBytes > 0)
        #expect(paused.downloadedBytes < Int64(data.count))

        file.state.withLock { $0.chunkDelay = 0 }
        let before = file.requests.count
        let result = await runDownload(paused, streamer: streamer, retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(try contents(result) == data)
        let resumed = file.requests[before...]
        let expectedRanges = paused.segments.filter { !$0.isComplete }.map { "bytes=\($0.nextOffset)-\($0.end)" }
        #expect(Set(resumed.compactMap { $0.value(forHTTPHeaderField: "Range") }) == Set(expectedRanges))
        let allUsedIfRange = resumed.allSatisfy { $0.value(forHTTPHeaderField: "If-Range") == #""v1""# }
        #expect(allUsedIfRange)
    }

    @Test func changedFileRestartsFromZero() async throws {
        let dir = try makeTempDir()
        let (paused, file, streamer) = try await startAndPause(.init(data: testData(5_000_000), chunkDelay: 0.05), dir: dir)
        let newData = testData(4_000_000, seed: 7)
        file.state.withLock {
            $0.data = newData
            $0.etag = #""v2""#
            $0.chunkDelay = 0
        }

        let result = await runDownload(paused, streamer: streamer, retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(try contents(result) == newData)
        #expect(try leftoverTempFiles(dir).isEmpty)
    }

    @Test func inconsistentETagsFallBackToSingleConnection() async throws {
        let dir = try makeTempDir()
        let data = testData(5_000_000)
        var config = MockFile.Config(data: data)
        config.rotateETag = true
        let (url, _) = MockServer.serve(config)

        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(result.resumable == false)
        #expect(try contents(result) == data)
    }

    @Test func sortsIntoCategoryOnceServerNamesTheFile() async throws {
        let dir = try makeTempDir()
        let data = testData(100_000)
        let (url, _) = MockServer.serve(.init(data: data), path: "/report.pdf")
        let record = DownloadRecord(url: url, directory: dir, categories: defaultFileCategories)

        let result = await runDownload(record, streamer: MockServer.streamer(), retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(result.directory == dir.appending(path: "Documents", directoryHint: .isDirectory))
        #expect(result.categories == nil)
        #expect(try contents(result) == data)
    }

    @Test func serverFilenameReadsContentDisposition() async {
        let (named, _) = MockServer.serve(.init(data: testData(1000), extraHeaders: ["Content-Disposition": #"attachment; filename="book.pdf""#]), path: "/upload_file")
        let (missing, _) = MockServer.serve(.init(data: Data(), status: 404))
        #expect(await serverFilename(url: named, headers: [:], streamer: MockServer.streamer()) == "book.pdf")
        #expect(await serverFilename(url: missing, headers: [:], streamer: MockServer.streamer()) == nil)
    }

    @Test func transientFailuresAreRetried() async throws {
        let dir = try makeTempDir()
        let data = testData(5_000_000)
        let (url, _) = MockServer.serve(.init(data: data, failFirst: 2))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)
        #expect(result.state == .completed)
        #expect(try contents(result) == data)
    }

    @Test func retriesFiveTimesAfterTheFirstAttempt() async throws {
        let dir = try makeTempDir()
        let data = testData(1000)   // one segment, so failFirst counts that segment's attempts
        let (url, file) = MockServer.serve(.init(data: data, failFirst: 5))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)
        #expect(result.state == .completed)
        #expect(file.requests.count == 1 + 6)   // probe + 1 attempt + 5 retries
    }

    @Test func defaultRetryDelayBacksOffWithJitter() {
        for attempt in 0..<5 {
            let base = Duration.seconds(1 << attempt)
            let delays = (0..<20).map { _ in defaultRetryDelay(attempt) }
            let inRange = delays.allSatisfy { $0 >= base && $0 <= base * 1.5 }
            #expect(inRange)
            #expect(Set(delays).count > 1)
        }
    }

    @Test func persistentFailuresGiveUp() async throws {
        let dir = try makeTempDir()
        let (url, _) = MockServer.serve(.init(data: testData(5_000_000), failFirst: 1000))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), maxAttempts: 3, retryDelay: noDelay)
        guard case .failed = result.state else {
            Issue.record("expected failed, got \(result.state)")
            return
        }
    }

    @Test func forbiddenFailsWithoutRetry() async throws {
        let dir = try makeTempDir()
        let (url, file) = MockServer.serve(.init(data: testData(10), status: 403))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)
        #expect(result.state == .failed("HTTP 403 – login or cookie may have expired"))
        #expect(file.requests.count == 1)
    }

    @Test func pathTraversalFilenameStaysInDirectory() async throws {
        let parent = try makeTempDir()
        let dir = parent.appending(path: "downloads")
        let (url, _) = MockServer.serve(.init(data: testData(1000)))
        let record = DownloadRecord(url: url, filename: "../evil.bin", directory: dir)

        let result = await runDownload(record, streamer: MockServer.streamer(), retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(result.fileURL == dir.appending(path: "evil.bin"))
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "evil.bin").path(percentEncoded: false)))
    }

    @Test func sameFilenameConcurrently() async throws {
        let dir = try makeTempDir()
        let dataA = testData(3_000_000, seed: 1)
        let dataB = testData(3_000_000, seed: 2)
        let (urlA, _) = MockServer.serve(.init(data: dataA))
        let (urlB, _) = MockServer.serve(.init(data: dataB))

        async let a = runDownload(DownloadRecord(url: urlA, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)
        async let b = runDownload(DownloadRecord(url: urlB, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)
        let results = await [a, b]

        let allCompleted = results.allSatisfy { $0.state == .completed }
        #expect(allCompleted)
        #expect(Set(results.compactMap(\.filename)) == ["file.bin", "file (1).bin"])
        #expect(try contents(results[0]) == dataA)
        #expect(try contents(results[1]) == dataB)
    }
}
