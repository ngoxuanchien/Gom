import Foundation
import Testing
@testable import GomCore

/// A shell script standing in for yt-dlp; `$dir` is the `-P` folder. ffmpeg is never run by the fake.
func fakeYtDlp(_ body: String) throws -> VideoTools {
    let script = try makeTempDir().appending(path: "yt-dlp")
    let text = """
    #!/bin/sh
    while [ $# -gt 0 ]; do [ "$1" = "-P" ] && dir="$2"; shift; done
    \(body)
    """
    try text.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    return VideoTools(ytDlp: script, ffmpeg: URL(filePath: "/usr/bin/true"))
}

let successScript = """
echo "GOMNAME Test Clip"
echo "GOM 50 100 NA 1000"
echo "GOM 100 100 NA NA"
printf 'video' > "$dir/Test Clip [abc].mp4"
echo "GOMFILE $dir/Test Clip [abc].mp4"
"""

@Suite struct VideoEngineTests {
    func videoRecord(_ dir: URL, categories: [FileCategory]? = nil) -> DownloadRecord {
        DownloadRecord(url: URL(string: "https://youtu.be/abc")!, directory: dir, categories: categories, video: .best)
    }

    @Test func completesIntoCategoryFolder() async throws {
        let dir = try makeTempDir()
        let progress = Locked<[Int64]>([])
        let result = await runVideoDownload(videoRecord(dir, categories: defaultFileCategories), tools: try fakeYtDlp(successScript)) { record in
            progress.mutate { $0.append(record.downloadedBytes) }
        }
        #expect(result.state == .completed)
        #expect(result.fileURL?.path(percentEncoded: false) == dir.appending(path: "Video/Test Clip [abc].mp4").path(percentEncoded: false))
        #expect(try String(contentsOf: result.fileURL!, encoding: .utf8) == "video")
        #expect(result.totalBytes == 5)   // the real file size, not yt-dlp's reported total
        #expect(result.headers.isEmpty)
        #expect(progress.value == [50, 100])
        // The hidden temp folder is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) == ["Video"])
    }

    @Test func secondCopyGetsUniqueName() async throws {
        let dir = try makeTempDir()
        let tools = try fakeYtDlp(successScript)
        let first = await runVideoDownload(videoRecord(dir), tools: tools)
        let second = await runVideoDownload(videoRecord(dir), tools: tools)
        #expect(first.filename == "Test Clip [abc].mp4")
        #expect(second.filename == "Test Clip [abc] (1).mp4")
    }

    @Test func progressArrivesWhileYtDlpIsStillRunning() async throws {
        let dir = try makeTempDir()
        let tools = try fakeYtDlp("""
        echo "GOMNAME Slow Clip"
        sleep 0.3
        echo "GOM 10 100 NA NA"
        sleep 3
        printf 'video' > "$dir/Slow Clip [abc].mp4"
        echo "GOMFILE $dir/Slow Clip [abc].mp4"
        """)
        let start = ContinuousClock.now
        let first = Locked<(Duration, String?)?>(nil)
        let result = await runVideoDownload(videoRecord(dir), tools: tools) { record in
            first.mutate { if $0 == nil { $0 = (ContinuousClock.now - start, record.filename) } }
        }
        #expect(result.state == .completed)
        let (elapsed, filename) = try #require(first.value)
        #expect(elapsed < .milliseconds(1500))
        #expect(filename == "Slow Clip")
    }

    @Test func completedSizeIsTheFileSizeEvenWhenYtDlpReportsLess() async throws {
        let dir = try makeTempDir()
        let tools = try fakeYtDlp("""
        echo "GOM 2 2 NA NA"
        printf 'video' > "$dir/Clip [abc].mp4"
        echo "GOMFILE $dir/Clip [abc].mp4"
        """)
        let result = await runVideoDownload(videoRecord(dir), tools: tools)
        #expect(result.state == .completed)
        #expect(result.totalBytes == 5)
        #expect(result.downloadedBytes == 5)
    }

    @Test func failureUsesLastErrorLine() async throws {
        let tools = try fakeYtDlp("""
        echo "WARNING: something" >&2
        echo "ERROR: [generic] abc: Unsupported URL: https://youtu.be/abc" >&2
        exit 1
        """)
        let result = await runVideoDownload(videoRecord(try makeTempDir()), tools: tools)
        #expect(result.state == .failed("[generic] abc: Unsupported URL: https://youtu.be/abc"))
    }

    @Test func failureWithoutErrorLineReportsStatus() async throws {
        let result = await runVideoDownload(videoRecord(try makeTempDir()), tools: try fakeYtDlp("exit 3"))
        #expect(result.state == .failed("yt-dlp exited with status 3"))
    }

    @Test func missingToolsFailImmediately() async throws {
        let dir = try makeTempDir()
        #expect(await runVideoDownload(videoRecord(dir), tools: VideoTools()).state == .failed("yt-dlp not installed"))
        #expect(await runVideoDownload(videoRecord(dir), tools: VideoTools(ytDlp: URL(filePath: "/usr/bin/true"))).state == .failed("ffmpeg not installed"))
    }

    @Test func cancelPausesAndKeepsTempFolder() async throws {
        let dir = try makeTempDir()
        let tools = try fakeYtDlp("""
        printf 'part' > "$dir/Test Clip [abc].mp4.part"
        echo "GOM 10 100 NA NA"
        exec sleep 30
        """)
        let started = Locked(false)
        let record = videoRecord(dir)
        let task = Task { await runVideoDownload(record, tools: tools) { _ in started.mutate { $0 = true } } }
        while !started.value { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        let result = await task.value
        #expect(result.state == .paused)
        #expect(result.downloadedBytes == 10)
        #expect(FileManager.default.fileExists(atPath: record.tempURL!.appending(path: "Test Clip [abc].mp4.part").path(percentEncoded: false)))
    }
}

@Suite struct VideoKillTests {
    @Test func killsYtDlpThatIgnoresSIGINT() async throws {
        let tools = try fakeYtDlp(#"trap '' INT; echo "GOM 10 100 NA NA"; while :; do sleep 0.2; done"#)
        let started = Locked(false)
        let record = DownloadRecord(url: URL(string: "https://youtu.be/abc")!, directory: try makeTempDir(), video: .best)
        let task = Task { await runVideoDownload(record, tools: tools) { _ in started.mutate { $0 = true } } }
        while !started.value { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        #expect(await task.value.state == .paused)
    }
}

@MainActor
@Suite struct VideoQueueTests {
    func makeQueue(_ dir: URL) -> DownloadQueue {
        DownloadQueue(store: DownloadStore(fileURL: dir.appending(path: "downloads.json")), streamer: MockServer.streamer(), retryDelay: { _ in .zero })
    }

    @Test func missingToolFailsThenRetriesAfterInstall() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        let id = queue.add(url: URL(string: "https://youtu.be/abc")!, directory: dir, video: .p720)
        try await waitUntil { queue.items.first?.state == .failed("yt-dlp not installed") }

        queue.videoTools = try fakeYtDlp(successScript)
        queue.retryMissingTools()
        try await waitUntil { queue.items.first?.state == .completed }
        #expect(queue.items.first { $0.id == id }?.filename == "Test Clip [abc].mp4")
    }

    @Test func retryMissingToolsLeavesOtherFailuresAlone() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        queue.videoTools = try fakeYtDlp(#"echo "ERROR: Unsupported URL" >&2; exit 1"#)
        queue.add(url: URL(string: "https://youtu.be/abc")!, directory: dir, video: .best)
        try await waitUntil { queue.items.first?.state == .failed("Unsupported URL") }
        queue.retryMissingTools()
        #expect(queue.items.first?.state == .failed("Unsupported URL"))
    }

    @Test func persistedVideoRunsWithToolsGivenToInit() async throws {
        let dir = try makeTempDir()
        let store = DownloadStore(fileURL: dir.appending(path: "downloads.json"))
        try store.save([DownloadRecord(url: URL(string: "https://youtu.be/abc")!, directory: dir, video: .best)])
        let queue = DownloadQueue(store: store, streamer: MockServer.streamer(), retryDelay: { _ in .zero }, videoTools: try fakeYtDlp(successScript))
        try await waitUntil { queue.items.first?.state == .completed }
    }

    @Test func sameURLWithDifferentQualityIsNotADuplicate() throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        let url = URL(string: "https://youtu.be/abc")!
        let a = queue.add(url: url, directory: dir, video: .best)
        let b = queue.add(url: url, directory: dir, video: .audio)
        #expect(a != b)
        #expect(queue.items.count == 2)
    }

    @Test func removingVideoDeletesTempFolder() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        queue.videoTools = try fakeYtDlp("""
        echo "GOM 10 100 NA NA"
        exec sleep 30
        """)
        let id = queue.add(url: URL(string: "https://youtu.be/abc")!, directory: dir, video: .best)
        let folder = queue.items[0].tempURL!
        try await waitUntil { queue.items.first?.downloadedBytes == 10 }
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))

        queue.pause(id)
        try await waitUntil { queue.items.first?.state == .paused }
        queue.remove(id, deleteFile: false)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }
}
