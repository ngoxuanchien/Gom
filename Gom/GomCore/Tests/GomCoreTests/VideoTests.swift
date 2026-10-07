import Foundation
import Testing
@testable import GomCore

@Suite struct VideoTests {
    @Test func recognizesVideoHostsAndSubdomains() {
        #expect(isVideoPage(URL(string: "https://www.youtube.com/watch?v=abc")!))
        #expect(isVideoPage(URL(string: "https://m.youtube.com/watch?v=abc")!))
        #expect(isVideoPage(URL(string: "https://youtu.be/abc")!))
        #expect(isVideoPage(URL(string: "https://VIMEO.com/123")!))
    }

    @Test func rejectsLookalikesAndOtherHosts() {
        #expect(!isVideoPage(URL(string: "https://notyoutube.com/watch")!))
        #expect(!isVideoPage(URL(string: "https://youtube.com.evil.example/x")!))
        #expect(!isVideoPage(URL(string: "https://example.com/video.mp4")!))
        #expect(!isVideoPage(URL(string: "ftp://youtube.com/x")!))
    }

    @Test func qualityArguments() {
        #expect(VideoQuality.best.formatArguments == ["-S", "res,ext:mp4:m4a", "--merge-output-format", "mp4"])
        #expect(VideoQuality.p1080.formatArguments == ["-S", "res:1080,ext:mp4:m4a", "--merge-output-format", "mp4"])
        #expect(VideoQuality.p720.formatArguments == ["-S", "res:720,ext:mp4:m4a", "--merge-output-format", "mp4"])
        #expect(VideoQuality.audio.formatArguments == ["-f", "ba/b", "-x", "--audio-format", "m4a"])
        #expect(VideoQuality(rawValue: "1080p") == .p1080)
    }

    @Test func fileRecordEncodesWithoutVideoKeyAndRoundTrips() throws {
        // Records saved before phase 2 have no "video" key; nil must encode the same way and decode back.
        let record = DownloadRecord(url: URL(string: "https://example.com/a.zip")!, directory: URL(filePath: "/tmp"))
        let data = try JSONEncoder().encode(record)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"video\""))
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: data) == record)
    }

    @Test func videoRecordTempURLIsHiddenFolder() {
        let id = UUID(uuidString: "12345678-0000-0000-0000-000000000000")!
        let record = DownloadRecord(url: URL(string: "https://youtu.be/x")!, directory: URL(filePath: "/tmp/dl"), id: id, video: .best)
        #expect(record.tempURL?.path(percentEncoded: false) == "/tmp/dl/.gom-12345678/")
    }

    @Test func parsesProgressLines() {
        // Captured from yt-dlp 2026.08.19.
        #expect(parseYtDlpLine("GOM 1024 309288 NA 130764.72205815192") == .progress(downloaded: 1024, total: 309288))
        #expect(parseYtDlpLine("GOM 2048 NA 500000.5 NA") == .progress(downloaded: 2048, total: 500000))
        #expect(parseYtDlpLine("GOM 2048 NA NA NA") == .progress(downloaded: 2048, total: nil))
    }

    @Test func parsesOddNumbers() {
        #expect(parseYtDlpLine("GOM 309288.0 309288.0 NA NA") == .progress(downloaded: 309288, total: 309288))
        #expect(parseYtDlpLine("GOM nan inf NA NA") == nil)
        #expect(parseYtDlpLine("GOM NA 100 NA NA") == nil)
        #expect(parseYtDlpLine("GOM") == nil)
        #expect(parseYtDlpLine("GOM 1e19 NA NA NA") == nil)
    }

    @Test func parsesTitleAndFile() {
        #expect(parseYtDlpLine("GOMNAME Me at the zoo") == .title("Me at the zoo"))
        #expect(parseYtDlpLine("GOMFILE /tmp/x/Me at the zoo [jNQXAC9IVRw].m4a") == .file("/tmp/x/Me at the zoo [jNQXAC9IVRw].m4a"))
    }

    @Test func ignoresOtherOutput() {
        #expect(parseYtDlpLine("[youtube] jNQXAC9IVRw: Downloading webpage") == nil)
        #expect(parseYtDlpLine("") == nil)
        #expect(parseYtDlpLine("GOMBLE 1 2") == nil)
    }

    @Test func bytesKeepGrowingAcrossStreams() {
        var progress = StreamProgress()
        #expect(progress.update(downloaded: 40, total: 100) == (40, 100))
        #expect(progress.update(downloaded: 100, total: 100) == (100, 100))
        // Audio stream starts: its counter restarts below the previous value.
        #expect(progress.update(downloaded: 10, total: 50) == (110, 150))
        #expect(progress.update(downloaded: 50, total: nil) == (150, nil))
    }

    @Test func argumentsDropCookies() {
        let args = ytDlpArguments(
            url: URL(string: "https://youtu.be/abc")!, quality: .p720,
            ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"), folder: URL(filePath: "/tmp/dl/.gom-1"),
            limitRate: 500_000,
            headers: ["Cookie": "secret=1", "User-Agent": "UA", "Referer": "https://youtube.com/"]
        )
        #expect(!args.joined(separator: " ").contains("secret"))
        #expect(args.contains("User-Agent:UA"))
        #expect(args.contains("Referer:https://youtube.com/"))
        #expect(args.suffix(2) == ["--", "https://youtu.be/abc"])
        #expect(args.contains("res:720,ext:mp4:m4a"))
        let items = args.firstIndex(of: "-I")!
        #expect(args[items + 1] == "1")
        let rate = args.firstIndex(of: "--limit-rate")!
        #expect(args[rate + 1] == "500000")
        let folder = args.firstIndex(of: "-P")!
        #expect(args[folder + 1] == "/tmp/dl/.gom-1")
    }

    @Test func argumentsOmitLimitWhenUnlimited() {
        let args = ytDlpArguments(url: URL(string: "https://youtu.be/abc")!, quality: .best, ffmpeg: URL(filePath: "/f"), folder: URL(filePath: "/d"), limitRate: 0, headers: [:])
        #expect(!args.contains("--limit-rate"))
        #expect(!args.contains("--add-header"))
    }

    @Test func locateToolTakesFirstExecutableCandidate() {
        let dirs = [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin"), URL(filePath: "/Users/me/.local/bin")]
        let found = locateTool("yt-dlp", in: dirs) { $0.path(percentEncoded: false) == "/Users/me/.local/bin/yt-dlp" }
        #expect(found?.path(percentEncoded: false) == "/Users/me/.local/bin/yt-dlp")
        #expect(locateTool("yt-dlp", in: dirs) { _ in false } == nil)
    }

    @Test func toolDirectoriesAppendLoginShellPATHWithoutDuplicates() {
        let paths = toolDirectories(loginShellPATH: "/usr/local/bin:.:bin:/Users/me/bin:").map { $0.path(percentEncoded: false) }
        #expect(Array(paths.prefix(2)) == ["/opt/homebrew/bin/", "/usr/local/bin/"])
        #expect(paths.last == "/Users/me/bin/")
        #expect(paths.filter { $0 == "/usr/local/bin/" }.count == 1)
        #expect(!paths.contains { !$0.hasPrefix("/") })
    }

    @Test func missingTools() {
        #expect(VideoTools(ffmpeg: URL(filePath: "/f"), deno: URL(filePath: "/d")).missing == ["yt-dlp"])
        #expect(VideoTools().missing == ["yt-dlp", "ffmpeg", "deno"])
    }

    @Test func processPATHListsToolFoldersOnceBeforeSystemOnes() {
        let tools = VideoTools(ytDlp: URL(filePath: "/opt/homebrew/bin/yt-dlp"), ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"), deno: URL(filePath: "/Users/me/.deno/bin/deno"))
        #expect(tools.processPATH == "/opt/homebrew/bin:/Users/me/.deno/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(VideoTools().processPATH == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func runsProcessToCompletion() async throws {
        let result1 = try await runProcess(URL(filePath: "/bin/sh"), ["-c", "echo hello; echo oops >&2; exit 3"])
        #expect(result1.status == 3)
        #expect(result1.output.contains("hello"))
        #expect(result1.output.contains("oops"))
        let result2 = try await runProcess(URL(filePath: "/bin/echo"), ["hi"])
        #expect(result2.status == 0)
        #expect(result2.output == "hi\n")
    }
}
