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
        #expect(result.totalBytes == 100)
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
