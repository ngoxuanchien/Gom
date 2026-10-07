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
        let file = try await runYtDlp(ytDlp, arguments, path: tools.processPATH) { event in
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

/// Runs yt-dlp and passes each understood output line to `onEvent`, with bytes accumulated across streams.
/// Returns the finished file's path (the `GOMFILE` line).
private func runYtDlp(_ executable: URL, _ arguments: [String], path: String, onEvent: @escaping @Sendable (YtDlpEvent) -> Void) async throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    // Python block-buffers stdout when it's a pipe, which would make progress arrive in bursts.
    process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1", "PATH": path]) { $1 }
    // One pipe for both streams: two concurrent FileHandle.bytes readers share a blocking reader, which held stdout back until stderr closed.
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    let exited = AsyncStream<Int32> { continuation in
        process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
    }
    // Launch before installing the cancel handler: interrupt() on an unlaunched Process raises.
    try process.run()
    // ponytail: SIGINT reaches yt-dlp only; an ffmpeg merge it started may run to the end. Signal the process group if that shows up.
    // A yt-dlp that ignores SIGINT is killed after 5 s so pause and quit can't hang.
    return try await withTaskCancellationHandler {
        var progress = StreamProgress()
        var file: String?
        var error: String?
        for try await line in output.fileHandleForReading.bytes.lines {
            if line.hasPrefix("ERROR: ") { error = String(line.dropFirst("ERROR: ".count)) }
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
        try Task.checkCancellation()
        guard status == 0 else { throw VideoError(message: error ?? "yt-dlp exited with status \(status)") }
        guard let file else { throw VideoError(message: "yt-dlp finished without a file") }
        return file
    } onCancel: {
        process.interrupt()   // SIGINT: yt-dlp keeps its .part file
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
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
    let destination = try moveToUniqueDestination(source, directory: r.directory, filename: name)
    r.filename = destination.lastPathComponent
    try? FileManager.default.removeItem(at: folder)
    // After a resume yt-dlp only reports the streams it fetched this run, so use the real size.
    let size = (try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64) ?? r.downloadedBytes
    r.totalBytes = size
    r.segments = [Segment(start: 0, end: size - 1, done: size)]
    r.state = .completed
    r.headers = [:]   // same as file downloads: don't keep request headers once done
}
