# Video Downloads (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Download videos from video pages through Gom's existing queue by driving an installed `yt-dlp` subprocess, with a quality choice and an install offer when tools are missing.

**Architecture:** `DownloadRecord` gains `video: VideoQuality?`; `DownloadQueue.start` sends video records to a new `runVideoDownload` (GomCore) instead of `runDownload`. `runVideoDownload` runs `yt-dlp` with a machine-readable `--progress-template`, maps its `GOM …` lines onto the record's single segment, and moves the finished file into the category folder with the existing helpers. The app locates/installs tools (`VideoSetup`); the extension adds a right-click submenu.

**Tech Stack:** Swift 6.2, SwiftUI, Foundation `Process`, Swift Testing, Chrome MV3 extension (plain JS).

**Spec:** `docs/superpowers/specs/2026-10-07-video-downloads-design.md`

## Global Constraints

- macOS 27, Swift tools 6.2, no new package dependencies (GomCore stays dependency-free).
- Quality args exactly: Best `-S res,ext:mp4:m4a --merge-output-format mp4`; 1080p `-S res:1080,ext:mp4:m4a --merge-output-format mp4`; 720p `-S res:720,ext:mp4:m4a --merge-output-format mp4`; Audio only `-f ba/b -x --audio-format m4a`.
- `VideoQuality` raw values: `best`, `1080p`, `720p`, `audio`. Labels: Best / 1080p / 720p / Audio only.
- Video host list: `youtube.com youtu.be vimeo.com dailymotion.com tiktok.com x.com twitter.com facebook.com instagram.com twitch.tv bilibili.com soundcloud.com` (host equal or subdomain).
- Missing-tool failure reasons exactly `yt-dlp not installed` / `ffmpeg not installed`.
- Temp folder for a video record: `<directory>/.gom-<first 8 chars of id>/`.
- Cookies are never passed to yt-dlp; only `User-Agent` and `Referer` headers.
- Tool search order: `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, then the login shell's `PATH`.
- Comments follow the codebase: short `///` doc comments, `ponytail:` for known ceilings. Docs in English.
- Run core tests with `swift test --package-path Gom/GomCore` from the worktree root.

## Review Focus

1. yt-dlp prints `NA`, `nan`, or float strings (`309288.0`) in progress fields → no crash; treated as unknown or truncated to bytes. (Task 2 test `parsesOddNumbers`)
2. A video's title contains spaces/brackets, or the same video is downloaded twice → file lands as one path component, second copy is `name (1).mp4`, nothing overwritten. (Task 3 test `secondCopyGetsUniqueName`)
3. Removing a paused video download → its hidden `.gom-xxxxxxxx` folder is deleted. (Task 4 test `removingVideoDeletesTempFolder`)
4. The extension hands over a request that carries a `Cookie` header → never reaches yt-dlp's arguments. (Task 2 test `argumentsDropCookies`)
5. Cancelling (pause/quit) mid-download → record comes back `.paused` with its progress, and the temp folder with `.part` data is kept for resume. (Task 3 test `cancelPausesAndKeepsTempFolder`)

---

## File Structure

| File | Responsibility |
|---|---|
| Create `Gom/GomCore/Sources/GomCore/Video.swift` | `VideoQuality`, `isVideoPage`, `YtDlpEvent` + `parseYtDlpLine`, `StreamProgress`, `ytDlpArguments`, `VideoTools` + `locateTool` + `toolDirectories`, `runProcess` |
| Create `Gom/GomCore/Sources/GomCore/VideoEngine.swift` | `runVideoDownload`: process lifecycle, progress mapping, finishing |
| Modify `Gom/GomCore/Sources/GomCore/DownloadRecord.swift` | `video` field, `tempURL` for video |
| Modify `Gom/GomCore/Sources/GomCore/Bridge.swift` | `AddRequest.video` |
| Modify `Gom/GomCore/Sources/GomCore/DownloadEngine.swift` | `moveToUniqueDestination` private → internal |
| Modify `Gom/GomCore/Sources/GomCore/DownloadQueue.swift` | `videoTools`, `add(video:)`, dispatch, `retryMissingTools()` |
| Create `Gom/GomCore/Tests/GomCoreTests/VideoTests.swift` | pure-function tests |
| Create `Gom/GomCore/Tests/GomCoreTests/VideoEngineTests.swift` | fake-yt-dlp engine + queue tests |
| Modify `Gom/GomCore/Tests/GomCoreTests/BridgeTests.swift` | `/add` with `video` |
| Create `Gom/App/VideoSetup.swift` | locate tools, yt-dlp version, install with brew, alerts |
| Modify `Gom/App/AppSettings.swift`, `ContentView.swift`, `GomApp.swift`, `SettingsView.swift` | wiring and the Video settings section |
| Modify `extension/manifest.json`, `extension/background.js`, `extension/README.md` | context menu |
| Modify `README.md` | Features, Roadmap |

---

### Task 1: Video model – quality, host list, record and bridge fields

**Files:**
- Create: `Gom/GomCore/Sources/GomCore/Video.swift`
- Modify: `Gom/GomCore/Sources/GomCore/DownloadRecord.swift`
- Modify: `Gom/GomCore/Sources/GomCore/Bridge.swift:3-9`
- Test: `Gom/GomCore/Tests/GomCoreTests/VideoTests.swift`, `Gom/GomCore/Tests/GomCoreTests/BridgeTests.swift`

**Interfaces:**
- Produces: `public enum VideoQuality: String, Codable, CaseIterable, Sendable { case best, p1080 = "1080p", p720 = "720p", audio }` with `public var label: String` and `var formatArguments: [String]`; `public func isVideoPage(_ url: URL) -> Bool`; `DownloadRecord.video: VideoQuality?` (init parameter `video: VideoQuality? = nil`, last); `AddRequest.video: VideoQuality?`.

- [ ] **Step 1: Write the failing tests**

`Gom/GomCore/Tests/GomCoreTests/VideoTests.swift`:

```swift
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
}
```

Append inside `BridgeTests`:

```swift
    @Test func addCarriesVideoQuality() {
        let (response, add) = route(request("POST", "/add", body: #"{"url":"https://youtu.be/abc","video":"720p"}"#), token: "secret")
        #expect(response.status == 200)
        #expect(add?.video == .p720)
    }

    @Test func addRejectsUnknownVideoQuality() {
        #expect(route(request("POST", "/add", body: #"{"url":"https://youtu.be/abc","video":"4k"}"#), token: "secret").0.status == 400)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Gom/GomCore --filter "VideoTests|BridgeTests"`
Expected: compile failure, `cannot find 'isVideoPage' in scope`.

- [ ] **Step 3: Implement**

`Gom/GomCore/Sources/GomCore/Video.swift`:

```swift
import Foundation

/// What yt-dlp downloads. Raw values are what the extension sends and Settings stores.
public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    case best, p1080 = "1080p", p720 = "720p", audio

    public var label: String {
        switch self {
        case .best: "Best"
        case .p1080: "1080p"
        case .p720: "720p"
        case .audio: "Audio only"
        }
    }

    /// Prefers streams macOS plays natively (mp4/m4a) without giving up resolution.
    /// `res:1080` means the largest at or below 1080p.
    var formatArguments: [String] {
        switch self {
        case .best: ["-S", "res,ext:mp4:m4a", "--merge-output-format", "mp4"]
        case .p1080: ["-S", "res:1080,ext:mp4:m4a", "--merge-output-format", "mp4"]
        case .p720: ["-S", "res:720,ext:mp4:m4a", "--merge-output-format", "mp4"]
        case .audio: ["-f", "ba/b", "-x", "--audio-format", "m4a"]
        }
    }
}

private let videoHosts = [
    "youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "tiktok.com", "x.com", "twitter.com",
    "facebook.com", "instagram.com", "twitch.tv", "bilibili.com", "soundcloud.com",
]

/// Pasted links on these sites go to yt-dlp; anything else downloads as a file.
public func isVideoPage(_ url: URL) -> Bool {
    guard isDownloadableURL(url), let host = url.host()?.lowercased() else { return false }
    return videoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
}
```

`DownloadRecord.swift` – add the stored property after `categories`:

```swift
    /// Set for video pages downloaded with yt-dlp; nil for plain files.
    public var video: VideoQuality?
```

add `video: VideoQuality? = nil` as the last init parameter with `self.video = video` at the end of the init body, and replace `tempURL`:

```swift
    /// Includes part of the id so two downloads with the same name never share a temp file.
    /// Video downloads use a hidden folder instead: yt-dlp names its own files and keeps `.part` files there.
    public var tempURL: URL? {
        if video != nil { return directory.appending(path: ".gom-\(id.uuidString.prefix(8))", directoryHint: .isDirectory) }
        return filename.map { directory.appending(path: "\($0).\(id.uuidString.prefix(8)).gomdownload") }
    }
```

`Bridge.swift`, in `AddRequest` after `userAgent`:

```swift
    /// Set by the extension's "Download video with Gom" menu.
    public var video: VideoQuality?
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Gom/GomCore`
Expected: all tests pass (existing + 7 new).

- [ ] **Step 5: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/Video.swift Gom/GomCore/Sources/GomCore/DownloadRecord.swift Gom/GomCore/Sources/GomCore/Bridge.swift Gom/GomCore/Tests/GomCoreTests/VideoTests.swift Gom/GomCore/Tests/GomCoreTests/BridgeTests.swift
git commit -m "Add video quality, video host list and video fields on records"
```

---

### Task 2: yt-dlp output parser, progress accumulator, arguments, tool lookup

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/Video.swift`
- Test: `Gom/GomCore/Tests/GomCoreTests/VideoTests.swift`

**Interfaces:**
- Consumes: `VideoQuality.formatArguments` (Task 1).
- Produces:
  - `enum YtDlpEvent: Equatable, Sendable { case title(String), progress(downloaded: Int64, total: Int64?), file(String) }`
  - `func parseYtDlpLine(_ line: String) -> YtDlpEvent?`
  - `struct StreamProgress { mutating func update(downloaded: Int64, total: Int64?) -> (done: Int64, total: Int64?) }`
  - `func ytDlpArguments(url: URL, quality: VideoQuality, ffmpeg: URL, folder: URL, limitRate: Int, headers: [String: String]) -> [String]`
  - `public struct VideoTools: Equatable, Sendable` with `ytDlp`, `ffmpeg`, `brew: URL?`, `init(ytDlp:ffmpeg:brew:)` (all default nil), `static func locate(in: [URL]) -> VideoTools`, `var missing: [String]`
  - `public func locateTool(_ name: String, in directories: [URL], isExecutable: (URL) -> Bool = …) -> URL?`
  - `public func toolDirectories(loginShellPATH: String?) -> [URL]`
  - `public func runProcess(_ executable: URL, _ arguments: [String]) async throws -> (status: Int32, output: String)`

- [ ] **Step 1: Write the failing tests** (append inside `VideoTests`)

```swift
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
        let paths = toolDirectories(loginShellPATH: "/usr/local/bin:/Users/me/bin:").map { $0.path(percentEncoded: false) }
        #expect(Array(paths.prefix(2)) == ["/opt/homebrew/bin/", "/usr/local/bin/"])
        #expect(paths.last == "/Users/me/bin/")
        #expect(paths.filter { $0 == "/usr/local/bin/" }.count == 1)
    }

    @Test func missingTools() {
        #expect(VideoTools(ffmpeg: URL(filePath: "/f")).missing == ["yt-dlp"])
        #expect(VideoTools().missing == ["yt-dlp", "ffmpeg"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Gom/GomCore --filter VideoTests`
Expected: compile failure, `cannot find 'parseYtDlpLine' in scope`.

- [ ] **Step 3: Implement** (append to `Video.swift`)

```swift
/// One line of yt-dlp output that Gom understands. The format is set by `ytDlpArguments`.
enum YtDlpEvent: Equatable, Sendable {
    case title(String)
    case progress(downloaded: Int64, total: Int64?)
    case file(String)
}

/// `GOMNAME <title>`, `GOMFILE <path>`, or `GOM <downloaded> <total> <estimate> <speed>`
/// where any number may be `NA`. Everything else is yt-dlp chatter and returns nil.
func parseYtDlpLine(_ line: String) -> YtDlpEvent? {
    if line.hasPrefix("GOMNAME ") { return .title(String(line.dropFirst("GOMNAME ".count))) }
    if line.hasPrefix("GOMFILE ") { return .file(String(line.dropFirst("GOMFILE ".count))) }
    guard line.hasPrefix("GOM ") else { return nil }
    let fields = line.split(separator: " ").dropFirst().map(String.init)
    guard fields.count >= 3, let downloaded = byteCount(fields[0]) else { return nil }
    return .progress(downloaded: downloaded, total: byteCount(fields[1]) ?? byteCount(fields[2]))
}

/// yt-dlp prints integers, floats (estimates), `NA`, and occasionally `nan`/`inf`.
private func byteCount(_ field: String) -> Int64? {
    guard let value = Double(field), value.isFinite, value >= 0 else { return nil }
    return Int64(value)
}

/// yt-dlp downloads video and audio as separate streams, each counting from zero.
/// Keeps the byte count growing across them.
/// ponytail: the total only grows when the next stream starts, so the bar can jump back once.
struct StreamProgress {
    private var finished: Int64 = 0
    private var current: Int64 = 0
    private var currentTotal: Int64?

    mutating func update(downloaded: Int64, total: Int64?) -> (done: Int64, total: Int64?) {
        if downloaded < current { finished += currentTotal ?? current }
        current = downloaded
        currentTotal = total
        return (finished + downloaded, total.map { finished + $0 })
    }
}

func ytDlpArguments(url: URL, quality: VideoQuality, ffmpeg: URL, folder: URL, limitRate: Int, headers: [String: String]) -> [String] {
    var args = [
        "--quiet", "--no-simulate", "--progress", "--newline", "--no-playlist", "--no-mtime",
        "--progress-template", "download:GOM %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s",
        "--print", "before_dl:GOMNAME %(title)s",
        "--print", "after_move:GOMFILE %(filepath)s",
        "--ffmpeg-location", ffmpeg.path(percentEncoded: false),
    ]
    if limitRate > 0 { args += ["--limit-rate", String(limitRate)] }
    // No cookies: yt-dlp warns that a Cookie header leaks across redirects, and login-only videos are out of scope.
    for name in ["User-Agent", "Referer"] {
        if let value = headers[name] { args += ["--add-header", "\(name):\(value)"] }
    }
    args += quality.formatArguments
    args += ["-P", folder.path(percentEncoded: false), "-o", "%(title).200B [%(id)s].%(ext)s", "--", url.absoluteString]
    return args
}

/// Executables video downloads need. nil = not found.
public struct VideoTools: Equatable, Sendable {
    public var ytDlp: URL?
    public var ffmpeg: URL?
    public var brew: URL?

    public init(ytDlp: URL? = nil, ffmpeg: URL? = nil, brew: URL? = nil) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.brew = brew
    }

    public static func locate(in directories: [URL]) -> VideoTools {
        VideoTools(ytDlp: locateTool("yt-dlp", in: directories), ffmpeg: locateTool("ffmpeg", in: directories), brew: locateTool("brew", in: directories))
    }

    /// Homebrew formula names of the tools that weren't found.
    public var missing: [String] {
        [ytDlp == nil ? "yt-dlp" : nil, ffmpeg == nil ? "ffmpeg" : nil].compactMap { $0 }
    }
}

public func locateTool(
    _ name: String,
    in directories: [URL],
    isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
) -> URL? {
    directories.lazy.map { $0.appending(path: name) }.first(where: isExecutable)
}

/// Apps started from Finder don't get the shell's PATH, so the usual install folders come first,
/// then whatever the login shell adds (pass its `$PATH`).
public func toolDirectories(loginShellPATH: String?) -> [URL] {
    var paths = ["/opt/homebrew/bin", "/usr/local/bin", URL.homeDirectory.appending(path: ".local/bin").path(percentEncoded: false)]
    for path in (loginShellPATH ?? "").split(separator: ":").map(String.init) where !paths.contains(path) {
        paths.append(path)
    }
    return paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
}

/// Runs a command to completion and returns its exit status and combined stdout and stderr.
public func runProcess(_ executable: URL, _ arguments: [String]) async throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let exited = AsyncStream<Int32> { continuation in
        process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
    }
    try process.run()
    var output = Data()
    for try await byte in pipe.fileHandleForReading.bytes { output.append(byte) }
    var status: Int32 = -1
    for await code in exited { status = code }
    return (status, String(decoding: output, as: UTF8.self))
}
```

Note: `URL(filePath:directoryHint: .isDirectory)` adds a trailing `/` to `path(percentEncoded:)`, which is why the `toolDirectories` test expects `/opt/homebrew/bin/`. A PATH entry written with a trailing slash isn't deduplicated; searching a folder twice is harmless.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Gom/GomCore`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/Video.swift Gom/GomCore/Tests/GomCoreTests/VideoTests.swift
git commit -m "Parse yt-dlp progress output and locate video tools"
```

---

### Task 3: `runVideoDownload` engine

**Files:**
- Create: `Gom/GomCore/Sources/GomCore/VideoEngine.swift`
- Modify: `Gom/GomCore/Sources/GomCore/DownloadEngine.swift` (`private func moveToUniqueDestination` → `func moveToUniqueDestination`)
- Test: `Gom/GomCore/Tests/GomCoreTests/VideoEngineTests.swift`

**Interfaces:**
- Consumes: `parseYtDlpLine`, `StreamProgress`, `ytDlpArguments`, `VideoTools` (Task 2); `DownloadRecord.video`, `tempURL` (Task 1); `categoryFolder`, `sanitizeFilename`, `moveToUniqueDestination` (existing).
- Produces: `@concurrent public func runVideoDownload(_ record: DownloadRecord, tools: VideoTools, limitRate: Int = 0, onProgress: @escaping @Sendable (DownloadRecord) -> Void = { _ in }) async -> DownloadRecord`; `final class Locked<Value: Sendable>: Sendable` (`init(_:)`, `var value`, `func mutate<R: Sendable>(_: (inout Value) -> R) -> R`), because a `Mutex` can't be captured by escaping closures; test helpers `func fakeYtDlp(_ body: String) throws -> VideoTools` and `let successScript: String` in `VideoEngineTests.swift` (reused by Task 4).

- [ ] **Step 1: Write the failing tests**

`Gom/GomCore/Tests/GomCoreTests/VideoEngineTests.swift`:

```swift
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
        trap 'exit 1' INT
        printf 'part' > "$dir/Test Clip [abc].mp4.part"
        echo "GOM 10 100 NA NA"
        sleep 30 & wait
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Gom/GomCore --filter VideoEngineTests`
Expected: compile failure, `cannot find 'runVideoDownload' in scope`.

- [ ] **Step 3: Implement**

In `DownloadEngine.swift`, change `private func moveToUniqueDestination` to `func moveToUniqueDestination` (nothing else).

`Gom/GomCore/Sources/GomCore/VideoEngine.swift`:

```swift
import Foundation
import Synchronization

private struct VideoError: Error {
    let message: String
}

/// A value shared between concurrent closures. `Mutex` itself is noncopyable and can't be captured by
/// escaping closures (same reason as `ProgressBox`).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    var value: Value { mutex.withLock { $0 } }
    func mutate<R: Sendable>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

/// Downloads a video page with yt-dlp until it completes, fails, or the calling task is cancelled.
/// Cancellation stops yt-dlp with SIGINT and returns the record as `.paused`; its temp folder keeps the
/// `.part` files, and running again continues from them.
@concurrent
public func runVideoDownload(
    _ record: DownloadRecord,
    tools: VideoTools,
    limitRate: Int = 0,
    onProgress: @escaping @Sendable (DownloadRecord) -> Void = { _ in }
) async -> DownloadRecord {
    var r = record
    r.state = .downloading
    r.resumable = true   // yt-dlp continues from .part files; also hides the row's "can't resume" note
    guard let ytDlp = tools.ytDlp else { r.state = .failed("yt-dlp not installed"); return r }
    guard let ffmpeg = tools.ffmpeg else { r.state = .failed("ffmpeg not installed"); return r }
    let folder = r.tempURL!   // never nil for a video record
    let arguments = ytDlpArguments(url: r.url, quality: r.video ?? .best, ffmpeg: ffmpeg, folder: folder, limitRate: limitRate, headers: r.headers)
    // Updated by the output reader; read back so a paused record keeps its progress.
    let latest = Locked(r)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try await runYtDlp(ytDlp, arguments) { event in
            let snapshot: DownloadRecord? = latest.mutate { current in
                switch event {
                case .title(let title):
                    current.filename = sanitizeFilename(title)   // shown in the row until the real name is known
                    return nil
                case .progress(let done, let total):
                    current.totalBytes = total
                    current.segments = [Segment(start: 0, end: (total ?? .max) - 1, done: done)]
                    return current
                case .file:
                    return nil
                }
            }
            if let snapshot { onProgress(snapshot) }
        }
        r = latest.value
        try finishVideo(&r, file: file, folder: folder)
        return r
    } catch {
        r = latest.value
        r.state = Task.isCancelled || error is CancellationError
            ? .paused
            : .failed((error as? VideoError)?.message ?? error.localizedDescription)
        return r
    }
}

/// Runs yt-dlp and passes each understood stdout line to `onEvent`, with bytes accumulated across streams.
/// Returns the finished file's path (the `GOMFILE` line).
private func runYtDlp(_ executable: URL, _ arguments: [String], onEvent: @escaping @Sendable (YtDlpEvent) -> Void) async throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let exited = AsyncStream<Int32> { continuation in
        process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
    }
    // Launch before installing the cancel handler: interrupt() on an unlaunched Process raises.
    try process.run()
    // ponytail: SIGINT reaches yt-dlp only; an ffmpeg merge it started may run to the end. Signal the process group if that shows up.
    return try await withTaskCancellationHandler {
        async let lastError = lastErrorLine(stderr.fileHandleForReading)
        var progress = StreamProgress()
        var file: String?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            switch parseYtDlpLine(line) {
            case .progress(let downloaded, let total)?:
                let (done, sum) = progress.update(downloaded: downloaded, total: total)
                onEvent(.progress(downloaded: done, total: sum))
            case .file(let path)?:
                file = path
            case let event?:
                onEvent(event)
            case nil:
                break
            }
        }
        var status: Int32 = -1
        for await code in exited { status = code }
        let error = try await lastError
        try Task.checkCancellation()
        guard status == 0 else { throw VideoError(message: error ?? "yt-dlp exited with status \(status)") }
        guard let file else { throw VideoError(message: "yt-dlp finished without a file") }
        return file
    } onCancel: {
        process.interrupt()   // SIGINT: yt-dlp keeps its .part file
    }
}

/// The last `ERROR:` line yt-dlp wrote, without the prefix.
private func lastErrorLine(_ handle: FileHandle) async throws -> String? {
    var last: String?
    for try await line in handle.bytes.lines where line.hasPrefix("ERROR: ") {
        last = String(line.dropFirst("ERROR: ".count))
    }
    return last
}

/// Moves yt-dlp's file out of the temp folder into the download (or category) folder and removes the temp folder.
private func finishVideo(_ r: inout DownloadRecord, file: String, folder: URL) throws {
    let source = URL(filePath: file)
    let name = sanitizeFilename(source.lastPathComponent)
    if let categories = r.categories, let sub = categoryFolder(for: name, in: categories) {
        r.directory.append(path: sub, directoryHint: .isDirectory)
    }
    r.categories = nil
    try FileManager.default.createDirectory(at: r.directory, withIntermediateDirectories: true)
    r.filename = try moveToUniqueDestination(source, directory: r.directory, filename: name).lastPathComponent
    try? FileManager.default.removeItem(at: folder)
    r.totalBytes = r.downloadedBytes
    r.state = .completed
    r.headers = [:]   // same as file downloads: don't keep request headers once done
}
```

`folder` is captured before `finishVideo` changes `r.directory`, because `tempURL` is derived from the directory. If Swift 6 rejects capturing the non-`Sendable` `Process` in `onCancel`, add `nonisolated(unsafe) let running = process` before `withTaskCancellationHandler` and call `running.interrupt()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Gom/GomCore`
Expected: all pass. If `cancelPausesAndKeepsTempFolder` hangs for ~30 s, SIGINT isn't reaching the script: check that `onCancel` calls `interrupt()` and that the script's `trap` line is intact.

- [ ] **Step 5: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/VideoEngine.swift Gom/GomCore/Sources/GomCore/DownloadEngine.swift Gom/GomCore/Tests/GomCoreTests/VideoEngineTests.swift
git commit -m "Run yt-dlp as a download engine with pause and progress"
```

---

### Task 4: Queue integration

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/DownloadQueue.swift` (`add`, `start`, new `videoTools`, `retryMissingTools`)
- Test: `Gom/GomCore/Tests/GomCoreTests/VideoEngineTests.swift` (new `@MainActor` suite at the bottom)

**Interfaces:**
- Consumes: `runVideoDownload`, `VideoTools`, `fakeYtDlp`, `successScript` (Task 3); `MockServer.streamer()`, `makeTempDir`, `waitUntil` (existing test support).
- Produces: `DownloadQueue.videoTools: VideoTools` (public, settable); `add(url:headers:filename:directory:categories:video:) -> UUID` with `video: VideoQuality? = nil` last; `public func retryMissingTools()`.

- [ ] **Step 1: Write the failing tests** (append to `VideoEngineTests.swift`)

```swift
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

    @Test func removingVideoDeletesTempFolder() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        queue.videoTools = try fakeYtDlp("""
        trap 'exit 1' INT
        echo "GOM 10 100 NA NA"
        sleep 30 & wait
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Gom/GomCore --filter VideoQueueTests`
Expected: compile failure, `extra argument 'video' in call`.

- [ ] **Step 3: Implement** in `DownloadQueue.swift`

Add next to `onFinished`:

```swift
    /// Where yt-dlp and ffmpeg are. Set by the app at launch and after installing them.
    @ObservationIgnored public var videoTools = VideoTools()
```

Replace `add`:

```swift
    @discardableResult
    public func add(url: URL, headers: [String: String] = [:], filename: String? = nil, directory: URL, categories: [FileCategory]? = nil, video: VideoQuality? = nil) -> UUID {
        if let existing = items.first(where: { $0.url == url && $0.state != .completed }) {
            highlighted = existing.id
            return existing.id
        }
        let record = DownloadRecord(url: url, headers: headers, filename: filename.map(sanitizeFilename), directory: directory, categories: categories, video: video)
        items.append(record)
        persist()
        schedule()
        return record.id
    }
```

Add after `resume`:

```swift
    /// Re-queues video downloads that failed only because yt-dlp or ffmpeg was missing.
    public func retryMissingTools() {
        for item in items where item.video != nil {
            if case .failed(let reason) = item.state, reason.hasSuffix(" not installed") { resume(item.id) }
        }
    }
```

Replace `start`:

```swift
    private func start(_ record: DownloadRecord) {
        update(record.id) { $0.state = .downloading }
        let id = record.id
        let streamer = streamer
        let retryDelay = retryDelay
        let tools = videoTools
        let limit = bandwidthLimit
        running[id] = Task {
            let report: @Sendable (DownloadRecord) -> Void = { progress in
                Task { @MainActor in self.progress(progress) }
            }
            // ponytail: yt-dlp gets the limit at start and isn't part of the combined cap; a new limit applies on resume.
            let result = record.video == nil
                ? await runDownload(record, streamer: streamer, retryDelay: retryDelay, onProgress: report)
                : await runVideoDownload(record, tools: tools, limitRate: limit, onProgress: report)
            self.finished(id, result)
        }
    }
```

`remove` and `finished` already delete `tempURL` with `removeItem`, which removes folders too. No change there.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Gom/GomCore`
Expected: all pass, including the existing `DownloadQueueTests`.

- [ ] **Step 5: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/DownloadQueue.swift Gom/GomCore/Tests/GomCoreTests/VideoEngineTests.swift
git commit -m "Route video records through yt-dlp in the download queue"
```

---

### Task 5: App – tool setup, install offer, Settings, add paths

**Files:**
- Create: `Gom/App/VideoSetup.swift`
- Modify: `Gom/App/AppSettings.swift`, `Gom/App/ContentView.swift`, `Gom/App/GomApp.swift`, `Gom/App/SettingsView.swift`

**Interfaces:**
- Consumes: `VideoTools`, `toolDirectories`, `runProcess`, `isVideoPage`, `VideoQuality`, `DownloadQueue.videoTools`, `retryMissingTools()`, `add(…video:)`, `AddRequest.video`.
- Produces: `@MainActor @Observable final class VideoSetup` with `tools: VideoTools`, `ytDlpVersion: String?`, `installing: Bool`, `func refresh() async`, `func offerInstallIfNeeded()`, `func install() async`; `AppSettings.videoQuality: VideoQuality`.

The app has no unit-test target. This task is verified by a build, plus the manual checks in Task 7.

- [ ] **Step 1: `AppSettings.videoQuality`** – in `AppSettings.swift`, after `speedLimitKB`:

```swift
    /// Quality for pasted video links; the extension's menu picks its own.
    static var videoQuality: VideoQuality {
        defaults.string(forKey: "videoQuality").flatMap(VideoQuality.init(rawValue:)) ?? .best
    }
```

- [ ] **Step 2: `Gom/App/VideoSetup.swift`**

```swift
import AppKit
import GomCore
import Observation

/// Finds yt-dlp and ffmpeg, and installs them with Homebrew when the user agrees.
@MainActor
@Observable
final class VideoSetup {
    private(set) var tools = VideoTools()
    private(set) var ytDlpVersion: String?
    private(set) var installing = false
    private let queue: DownloadQueue

    init(queue: DownloadQueue) { self.queue = queue }

    /// Looks the tools up again and hands them to the queue.
    func refresh() async {
        let shell = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        let path = try? await runProcess(shell, ["-lc", "echo $PATH"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        tools = VideoTools.locate(in: toolDirectories(loginShellPATH: path))
        queue.videoTools = tools
        if let ytDlp = tools.ytDlp {
            ytDlpVersion = try? await runProcess(ytDlp, ["--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            ytDlpVersion = nil
        }
    }

    /// Called after a video is added and from Settings: asks to install whatever is missing.
    func offerInstallIfNeeded() {
        guard !tools.missing.isEmpty, !installing else { return }
        let alert = NSAlert()
        alert.messageText = "Video downloads need \(tools.missing.joined(separator: " and "))"
        if tools.brew != nil {
            alert.informativeText = "Gom can install them with Homebrew. Videos waiting for them start once it's done."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { Task { await install() } }
        } else {
            alert.informativeText = "Install Homebrew, then run this in Terminal:\n\nbrew install \(tools.missing.joined(separator: " "))"
            alert.addButton(withTitle: "Get Homebrew")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
        }
    }

    func install() async {
        guard let brew = tools.brew, !tools.missing.isEmpty, !installing else { return }
        installing = true
        defer { installing = false }
        do {
            let result = try await runProcess(brew, ["install"] + tools.missing)
            if result.status != 0 {
                showInstallError(result.output.split(separator: "\n").suffix(8).joined(separator: "\n"))
            }
        } catch {
            showInstallError(error.localizedDescription)
        }
        await refresh()
        queue.retryMissingTools()
    }

    private func showInstallError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Homebrew couldn't install the video tools"
        alert.informativeText = detail
        alert.runModal()
    }
}
```

- [ ] **Step 3: Wire `GomApp.swift`**

In `AppDelegate`, after `let queue = …`:

```swift
    lazy var videoSetup = VideoSetup(queue: queue)
```

At the end of `applicationDidFinishLaunching`:

```swift
        Task { await videoSetup.refresh() }
```

In `startBridge()`, add `let videoSetup = videoSetup` next to `let queue = queue`, and replace the `Task { @MainActor in … }` body in the server callback:

```swift
                Task { @MainActor in
                    Self.showMainWindow()
                    if let video = add.video {
                        // The menu item is the choice: no folder dialog. The file is sorted once yt-dlp names it.
                        queue.add(url: add.url, headers: add.headers, directory: AppSettings.downloadDirectory,
                                  categories: AppSettings.sortByType ? AppSettings.categories : nil, video: video)
                        videoSetup.offerInstallIfNeeded()
                    } else {
                        Self.chooseFolder(for: add) { directory in
                            queue.add(url: add.url, headers: add.headers, filename: add.filename, directory: directory)
                        }
                    }
                }
```

In `GomApp.body`, pass the setup to the views:

```swift
        Window("Gom", id: "main") {
            ContentView(queue: appDelegate.queue, videoSetup: appDelegate.videoSetup)
        }
```

```swift
        Settings {
            SettingsView(queue: appDelegate.queue, videoSetup: appDelegate.videoSetup)
        }
```

- [ ] **Step 4: `ContentView.swift`** – add `let videoSetup: VideoSetup` after `let queue: DownloadQueue`, and replace `add(_:)`:

```swift
    private func add(_ url: URL) {
        let video = isVideoPage(url) ? AppSettings.videoQuality : nil
        queue.add(url: url, directory: AppSettings.downloadDirectory, categories: AppSettings.sortByType ? AppSettings.categories : nil, video: video)
        if video != nil { videoSetup.offerInstallIfNeeded() }
    }
```

- [ ] **Step 5: `SettingsView.swift` Video section**

Add `let videoSetup: VideoSetup` after `let queue: DownloadQueue`, add `@AppStorage("videoQuality") private var videoQuality = VideoQuality.best` with the other `@AppStorage` lines, and insert this section between "Folders by File Type" and "Browser Extension":

```swift
            Section {
                Picker("Quality", selection: $videoQuality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.label) }
                }
                LabeledContent("yt-dlp") { toolStatus(videoSetup.tools.ytDlp, version: videoSetup.ytDlpVersion) }
                LabeledContent("ffmpeg") { toolStatus(videoSetup.tools.ffmpeg, version: nil) }
                if !videoSetup.tools.missing.isEmpty {
                    HStack {
                        Spacer()
                        if videoSetup.installing {
                            ProgressView().controlSize(.small)
                            Text("Installing…").foregroundStyle(.secondary)
                        } else {
                            Button("Install") { videoSetup.offerInstallIfNeeded() }
                        }
                    }
                }
            } header: {
                Text("Video")
            } footer: {
                Text("Links to YouTube, Vimeo and other video sites download with yt-dlp at this quality. In the browser, right-click a page and choose Download video with Gom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Add the helper below `checkNotifications()`:

```swift
    private func toolStatus(_ url: URL?, version: String?) -> some View {
        Text(url.map { [version, $0.deletingLastPathComponent().path(percentEncoded: false)].compactMap { $0 }.joined(separator: " – ") } ?? "Not installed")
            .foregroundStyle(url == nil ? .red : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
```

Add `.task { await videoSetup.refresh() }` after the existing `.task { await checkNotifications() }`, so opening Settings picks up a tool installed by hand in Terminal.

- [ ] **Step 6: Build**

Run (from `Gom/`): `xcodegen generate && xcodebuild -project Gom.xcodeproj -scheme Gom -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (`@AppStorage` accepts `VideoQuality` because it is `RawRepresentable` with a `String` raw value.)

- [ ] **Step 7: Commit**

```bash
git add Gom/App/VideoSetup.swift Gom/App/AppSettings.swift Gom/App/ContentView.swift Gom/App/GomApp.swift Gom/App/SettingsView.swift
git commit -m "Send video links to yt-dlp and offer to install it"
```

---

### Task 6: Extension – right-click "Download video with Gom"

**Files:**
- Modify: `extension/manifest.json`, `extension/background.js`, `extension/README.md`

**Interfaces:**
- Consumes: bridge `/add` accepting `video` (Task 1).

- [ ] **Step 1: Manifest** – add `"contextMenus"` to `permissions` and bump `"version"` to `"0.2.0"`.

- [ ] **Step 2: Split the POST out of `sendToGom`** – replace `sendToGom` in `background.js` with:

```js
// Resolves true only if Gom accepted the request within 2 seconds.
async function postToGom(body, settings) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2000);
  try {
    const res = await fetch(`http://127.0.0.1:${settings.port}/add`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Gom-Token": settings.token },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function sendToGom(item, settings) {
  const url = item.finalUrl || item.url;
  return postToGom(
    {
      url,
      filename: item.filename ? item.filename.split(/[\\/]/).pop() : undefined,
      referrer: item.referrer || undefined,
      cookies: await cookieHeader(url),
      userAgent: navigator.userAgent,
    },
    settings
  );
}
```

- [ ] **Step 3: The menu** (append to `background.js`)

```js
const VIDEO_QUALITIES = { best: "Best", "1080p": "1080p", "720p": "720p", audio: "Audio only" };

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "gom-video", title: "Download video with Gom", contexts: ["page", "link"] });
  for (const [quality, title] of Object.entries(VIDEO_QUALITIES)) {
    chrome.contextMenus.create({ id: `gom-video:${quality}`, parentId: "gom-video", title, contexts: ["page", "link"] });
  }
});

// No cookies: Gom doesn't pass them to yt-dlp (login-only videos are out of scope).
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const id = String(info.menuItemId);
  if (!id.startsWith("gom-video:")) return;
  const settings = await chrome.storage.local.get(DEFAULTS);
  const url = info.linkUrl || info.pageUrl;
  const ok =
    settings.token &&
    /^https?:/i.test(url) &&
    (await postToGom({ url, referrer: info.pageUrl, userAgent: navigator.userAgent, video: id.slice("gom-video:".length) }, settings));
  if (!ok) {
    // Gom isn't running or the token is wrong: flag it on the toolbar icon for a few seconds.
    chrome.action.setBadgeText({ text: "!", tabId: tab?.id });
    setTimeout(() => chrome.action.setBadgeText({ text: "", tabId: tab?.id }), 4000);
  }
});
```

- [ ] **Step 4: Syntax check**

Run: `node --check extension/background.js && python3 -m json.tool extension/manifest.json >/dev/null && echo ok`
Expected: `ok`.

- [ ] **Step 5: README** – in `extension/README.md`, add before "## Known limitations":

```markdown
## Videos

Right-click a video page (or a link to one) → **Download video with Gom** → Best / 1080p / 720p / Audio only. Gom downloads it with yt-dlp straight into the Video (or Music) folder, and offers to install yt-dlp and ffmpeg with Homebrew if they're missing. Login-only videos aren't supported: cookies aren't passed to yt-dlp.
```

and append to the manual checklist:

```markdown
- [ ] Right-click a YouTube page → Download video with Gom → 720p → it appears in Gom with progress and lands in Video.
- [ ] Quit Gom, use the menu again → the toolbar icon shows "!" for a few seconds.
```

- [ ] **Step 6: Commit**

```bash
git add extension/manifest.json extension/background.js extension/README.md
git commit -m "Add a Download video with Gom menu to the extension"
```

---

### Task 7: README and end-to-end check

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README**

In Features, after the sorting bullet, add:

```markdown
- Downloads videos from YouTube, Vimeo and other sites with [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Best / 1080p / 720p / Audio only): paste the link or right-click the page in Chrome. Gom finds an installed yt-dlp and ffmpeg, or offers to install them with Homebrew.
```

Replace the "No external dependencies" bullet with:

```markdown
- No external dependencies: Swift, SwiftUI and Network.framework only. Video downloads use yt-dlp and ffmpeg, installed on demand.
```

Replace the Roadmap list with:

```markdown
- ~~Phase 2: video downloads via `yt-dlp`.~~ Done.
- Phase 3: scheduled downloads.
```

- [ ] **Step 2: Full test run**

Run: `swift test --package-path Gom/GomCore 2>&1 | tail -3`
Expected: all tests passed.

- [ ] **Step 3: Manual end-to-end** (quit the installed Gom first; drive the debug build with cua-driver, never osascript keystrokes)

1. Quit the installed Gom, then open `Gom/build/Build/Products/Debug/Gom.app`.
2. Settings → Video: yt-dlp shows a version and folder. ffmpeg shows "Not installed" → **Install** → confirm → "Installing…" → the ffmpeg folder appears.
3. Quality 720p, paste `https://www.youtube.com/watch?v=jNQXAC9IVRw` → the row shows "Me at the zoo", then progress and speed, then Done. The file is in `<download folder>/Video/`.
4. Paste a longer video and Pause midway → the row shows Paused and a `.gom-xxxxxxxx` folder exists. Resume → it completes without restarting from zero.
5. Reload the extension, right-click the YouTube page → Download video with Gom → Audio only → an `.m4a` lands in `Music/`.
6. Remove a paused video → its `.gom-xxxxxxxx` folder is gone.

Fix anything that differs from the expected result before finishing (systematic-debugging).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Document video downloads and mark phase 2 done"
```
