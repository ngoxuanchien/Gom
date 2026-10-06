import Foundation
import Testing
@testable import GomCore

@MainActor
@Suite struct DownloadQueueTests {
    func makeQueue(_ dir: URL) -> DownloadQueue {
        DownloadQueue(store: DownloadStore(fileURL: dir.appending(path: "downloads.json")), streamer: MockServer.streamer(), retryDelay: { _ in .zero })
    }

    func leftoverTempFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).filter { $0.hasSuffix(".gomdownload") }
    }

    @Test func runsAtMostThreeAtOnce() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        for _ in 0..<5 {
            let (url, _) = MockServer.serve(.init(data: testData(3_000_000), chunkDelay: 0.05))
            queue.add(url: url, directory: dir)
        }

        #expect(queue.activeCount == 3)
        #expect(queue.items.filter { $0.state == .downloading }.count == 3)
        #expect(queue.items.filter { $0.state == .queued }.count == 2)

        try await waitUntil { queue.items.allSatisfy { $0.state == .completed } }
        #expect(queue.activeCount == 0)
    }

    @Test func duplicateURLIsIgnoredAndHighlighted() throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        let (url, _) = MockServer.serve(.init(data: testData(3_000_000), chunkDelay: 0.05))

        let first = queue.add(url: url, directory: dir)
        let second = queue.add(url: url, directory: dir)

        #expect(first == second)
        #expect(queue.items.count == 1)
        #expect(queue.highlighted == first)
    }

    @Test func completedRecordKeepsNoCookies() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        var finished: [DownloadRecord] = []
        queue.onFinished = { finished.append($0) }
        let (url, _) = MockServer.serve(.init(data: testData(100_000)))

        queue.add(url: url, headers: ["Cookie": "secret=1"], directory: dir)
        try await waitUntil { queue.items.first?.state == .completed }

        let saved = try String(contentsOf: dir.appending(path: "downloads.json"), encoding: .utf8)
        #expect(!saved.contains("secret"))
        #expect(finished.map(\.state) == [.completed])
    }

    @Test func failureCallsOnFinishedButPauseDoesNot() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        var finished: [DownloadRecord] = []
        queue.onFinished = { finished.append($0) }
        let (failing, _) = MockServer.serve(.init(data: testData(1_000), status: 403), path: "/denied.bin")
        let (slow, _) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.05), path: "/slow.bin")

        queue.add(url: failing, directory: dir)
        let paused = queue.add(url: slow, directory: dir)
        try await waitUntil { if case .failed = queue.items.first?.state { true } else { false } }
        try await Task.sleep(for: .milliseconds(200))
        queue.pause(paused)
        try await waitUntil { queue.items.last?.state == .paused }

        #expect(finished.count == 1)
        guard case .failed = finished.first?.state else { Issue.record("expected a failed record"); return }
    }

    @Test func pauseAndResume() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        let data = testData(5_000_000)
        let (url, file) = MockServer.serve(.init(data: data, chunkDelay: 0.05))
        let id = queue.add(url: url, directory: dir)

        try await Task.sleep(for: .milliseconds(200))
        queue.pause(id)
        try await waitUntil { queue.items.first?.state == .paused }
        #expect(queue.activeCount == 0)

        file.state.withLock { $0.chunkDelay = 0 }
        queue.resume(id)
        try await waitUntil { queue.items.first?.state == .completed }
        #expect(try Data(contentsOf: #require(queue.items.first?.fileURL)) == data)
    }

    @Test func shutdownSavesRunningAsQueuedAndRelaunchResumes() async throws {
        let dir = try makeTempDir()
        let data = testData(5_000_000)
        let (url, file) = MockServer.serve(.init(data: data, chunkDelay: 0.1))
        let queue = makeQueue(dir)
        queue.add(url: url, directory: dir)
        try await waitUntil { (queue.items.first?.downloadedBytes ?? 0) > 0 }

        await queue.shutdown()

        let saved = DownloadStore(fileURL: dir.appending(path: "downloads.json")).load()
        #expect(saved.first?.state == .queued)
        #expect((saved.first?.downloadedBytes ?? 0) > 0)

        file.state.withLock { $0.chunkDelay = 0 }
        let relaunched = makeQueue(dir)
        try await waitUntil { relaunched.items.first?.state == .completed }
        #expect(try Data(contentsOf: #require(relaunched.items.first?.fileURL)) == data)
    }

    @Test func removeWhileRunningDeletesTempFile() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        let (url, _) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.05))
        let id = queue.add(url: url, directory: dir)
        try await Task.sleep(for: .milliseconds(200))

        queue.remove(id, deleteFile: false)

        #expect(queue.items.isEmpty)
        try await waitUntil { queue.activeCount == 0 }
        #expect(try leftoverTempFiles(dir).isEmpty)
    }
}
