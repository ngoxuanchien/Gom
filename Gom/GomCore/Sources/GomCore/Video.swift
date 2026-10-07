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
    return Int64(exactly: value.rounded(.down))
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
        "--quiet", "--no-simulate", "--progress", "--newline", "--no-playlist", "-I", "1", "--no-mtime",
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
    /// JavaScript runtime yt-dlp needs for YouTube. Optional: the engine runs without it.
    public var deno: URL?

    public init(ytDlp: URL? = nil, ffmpeg: URL? = nil, brew: URL? = nil, deno: URL? = nil) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
        self.brew = brew
        self.deno = deno
    }

    public static func locate(in directories: [URL]) -> VideoTools {
        VideoTools(ytDlp: locateTool("yt-dlp", in: directories), ffmpeg: locateTool("ffmpeg", in: directories), brew: locateTool("brew", in: directories), deno: locateTool("deno", in: directories))
    }

    /// Homebrew formula names of the tools that weren't found.
    public var missing: [String] {
        [ytDlp == nil ? "yt-dlp" : nil, ffmpeg == nil ? "ffmpeg" : nil, deno == nil ? "deno" : nil].compactMap { $0 }
    }

    /// PATH for the yt-dlp process: the tools' folders (so it finds deno and ffmpeg), then the system ones.
    var processPATH: String {
        var folders: [String] = []
        for tool in [ytDlp, ffmpeg, deno] {
            guard var folder = tool?.deletingLastPathComponent().path(percentEncoded: false) else { continue }
            if folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
            if !folders.contains(folder) { folders.append(folder) }
        }
        return (folders + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
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
    for path in (loginShellPATH ?? "").split(separator: ":").map(String.init) where path.hasPrefix("/") && !paths.contains(path) {
        paths.append(path)
    }
    return paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
}

/// Runs a command to completion and returns its exit status and combined stdout and stderr.
/// ponytail: reads until pipe EOF (grandchild keeping pipe open causes hang); no cancellation on caller task cancellation.
public func runProcess(_ executable: URL, _ arguments: [String]) async throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
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
