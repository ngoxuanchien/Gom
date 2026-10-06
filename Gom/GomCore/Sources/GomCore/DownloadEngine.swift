import Foundation
import Synchronization

public enum DownloadError: Error, Equatable {
    case httpStatus(Int)
    case fileChanged
    case incomplete

    var isFatal: Bool {
        switch self {
        case .httpStatus(let code): code == 401 || code == 403
        case .fileChanged: true
        case .incomplete: false
        }
    }
}

/// Segment progress shared by the concurrent segment tasks of one download.
final class ProgressBox: Sendable {
    private let segments: Mutex<[Segment]>
    private let lastReport = Mutex(ContinuousClock.now)

    init(_ segments: [Segment]) { self.segments = Mutex(segments) }

    var snapshot: [Segment] { segments.withLock { $0 } }
    func segment(_ index: Int) -> Segment { segments.withLock { $0[index] } }
    func add(_ count: Int64, to index: Int) { segments.withLock { $0[index].done += count } }

    /// True at most every 500ms so progress callbacks don't flood the UI.
    func shouldReport() -> Bool {
        lastReport.withLock { last in
            let now = ContinuousClock.now
            guard now - last >= .milliseconds(500) else { return false }
            last = now
            return true
        }
    }
}

/// 1s, 2s, 4s, 8s, 16s plus up to 50% jitter, so segments throttled together (HTTP 429)
/// don't all come back at the same instant.
public let defaultRetryDelay: @Sendable (Int) -> Duration = { attempt in
    let base = 1000 << attempt
    return .milliseconds(base + Int.random(in: 0...(base / 2)))
}

/// Downloads `record` until it completes, fails, or the calling task is cancelled.
/// Cancellation returns the record as `.paused` with its segment progress intact.
@concurrent
public func runDownload(
    _ record: DownloadRecord,
    streamer: HTTPStreamer,
    maxAttempts: Int = 6,   // first attempt + 5 retries (spec)
    retryDelay: @escaping @Sendable (Int) -> Duration = defaultRetryDelay,
    onProgress: @escaping @Sendable (DownloadRecord) -> Void = { _ in }
) async -> DownloadRecord {
    var r = record
    r.state = .downloading
    var restarted = false
    var singleConnection = false
    while true {
        do {
            if needsPrepare(r) {
                try await prepare(&r, streamer: streamer, maxAttempts: maxAttempts, retryDelay: retryDelay, singleConnection: singleConnection)
            }
            if r.resumable {
                try await transferSegments(&r, streamer: streamer, maxAttempts: maxAttempts, retryDelay: retryDelay, onProgress: onProgress)
            } else {
                try await transferSingle(&r, streamer: streamer, maxAttempts: maxAttempts, retryDelay: retryDelay, onProgress: onProgress)
            }
            try finish(&r)
            return r
        } catch DownloadError.fileChanged where !singleConnection {
            // First time the file may really have changed: start over. Second time the server
            // answers If-Range inconsistently (e.g. per-node ETags): stop splitting.
            if restarted { singleConnection = true } else { restarted = true }
            discardPartial(&r)
        } catch {
            r.state = Task.isCancelled || error is CancellationError ? .paused : .failed(describe(error))
            return r
        }
    }
}

private func needsPrepare(_ r: DownloadRecord) -> Bool {
    guard r.resumable, !r.segments.isEmpty, let temp = r.tempURL else { return true }
    return !FileManager.default.fileExists(atPath: temp.path(percentEncoded: false))
}

/// Probes the server and creates a fresh temp file sized for the download.
private func prepare(_ r: inout DownloadRecord, streamer: HTTPStreamer, maxAttempts: Int, retryDelay: @escaping @Sendable (Int) -> Duration, singleConnection: Bool) async throws {
    let current = r
    let info = try await withRetry(maxAttempts, retryDelay) { try await probe(current, streamer: streamer) }
    discardPartial(&r)
    r.filename = sanitizeFilename(r.filename ?? info.filename)
    r.totalBytes = info.totalBytes
    r.etag = info.validator
    r.resumable = !singleConnection && info.acceptsRanges && info.totalBytes != nil
    r.segments = r.resumable
        ? makeSegments(total: info.totalBytes!)
        : [Segment(start: 0, end: (info.totalBytes ?? .max) - 1)]

    let temp = r.tempURL!
    try FileManager.default.createDirectory(at: r.directory, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: temp.path(percentEncoded: false), contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    if r.resumable {
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(r.totalBytes!))
    }
}

private func probe(_ r: DownloadRecord, streamer: HTTPStreamer) async throws -> ProbeInfo {
    var request = makeRequest(r)
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    for try await event in streamer.stream(request) {
        guard case .response(let response) = event else { continue }
        // 416 = range not satisfiable (e.g. empty file): fall back to a plain GET.
        if response.statusCode >= 400 && response.statusCode != 416 {
            throw DownloadError.httpStatus(response.statusCode)
        }
        return parseProbe(response)
    }
    try Task.checkCancellation()
    throw DownloadError.incomplete
}

private func transferSegments(
    _ r: inout DownloadRecord,
    streamer: HTTPStreamer,
    maxAttempts: Int,
    retryDelay: @escaping @Sendable (Int) -> Duration,
    onProgress: @escaping @Sendable (DownloadRecord) -> Void
) async throws {
    let base = r
    let box = ProgressBox(r.segments)
    defer { r.segments = box.snapshot }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in base.segments.indices where !base.segments[index].isComplete {
            group.addTask {
                try await withRetry(maxAttempts, retryDelay) {
                    try await fetchSegment(index, of: base, box: box, streamer: streamer, onProgress: onProgress)
                }
            }
        }
        try await group.waitForAll()
    }
}

private func fetchSegment(
    _ index: Int,
    of base: DownloadRecord,
    box: ProgressBox,
    streamer: HTTPStreamer,
    onProgress: @Sendable (DownloadRecord) -> Void
) async throws {
    let segment = box.segment(index)
    guard !segment.isComplete, let temp = base.tempURL else { return }
    var request = makeRequest(base)
    request.setValue("bytes=\(segment.nextOffset)-\(segment.end)", forHTTPHeaderField: "Range")
    if let etag = base.etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }

    let handle = try FileHandle(forWritingTo: temp)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(segment.nextOffset))
    var offset = segment.nextOffset

    for try await event in streamer.stream(request) {
        switch event {
        case .response(let response):
            // 200 to a range request: the file changed (If-Range failed) or ranges stopped working.
            if response.statusCode == 200 { throw DownloadError.fileChanged }
            guard response.statusCode == 206 else { throw DownloadError.httpStatus(response.statusCode) }
        case .data(let data):
            let chunk = data.prefix(Int(segment.end + 1 - offset))
            try handle.write(contentsOf: chunk)
            offset += Int64(chunk.count)
            box.add(Int64(chunk.count), to: index)
            if box.shouldReport() {
                var snapshot = base
                snapshot.segments = box.snapshot
                onProgress(snapshot)
            }
        }
    }
    try Task.checkCancellation()
    if offset <= segment.end { throw DownloadError.incomplete }
}

/// Servers without range support: one GET, restarted from zero on every attempt.
private func transferSingle(
    _ r: inout DownloadRecord,
    streamer: HTTPStreamer,
    maxAttempts: Int,
    retryDelay: @escaping @Sendable (Int) -> Duration,
    onProgress: @escaping @Sendable (DownloadRecord) -> Void
) async throws {
    guard let temp = r.tempURL else { throw DownloadError.incomplete }
    try await withRetry(maxAttempts, retryDelay) {
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        r.segments[0].done = 0
        var lastReport = ContinuousClock.now
        for try await event in streamer.stream(makeRequest(r)) {
            switch event {
            case .response(let response):
                guard (200..<300).contains(response.statusCode) else { throw DownloadError.httpStatus(response.statusCode) }
            case .data(let data):
                try handle.write(contentsOf: data)
                r.segments[0].done += Int64(data.count)
                if ContinuousClock.now - lastReport >= .milliseconds(500) {
                    lastReport = .now
                    onProgress(r)
                }
            }
        }
        try Task.checkCancellation()
        if let total = r.totalBytes, r.segments[0].done != total { throw DownloadError.incomplete }
    }
    r.totalBytes = r.segments[0].done
}

private func finish(_ r: inout DownloadRecord) throws {
    guard let temp = r.tempURL, let filename = r.filename else { throw DownloadError.incomplete }
    r.filename = try moveToUniqueDestination(temp, directory: r.directory, filename: filename).lastPathComponent
    r.state = .completed
    r.headers = [:]   // don't keep cookies around once they're no longer needed
}

/// Retries when another download claims the same name between the check and the move.
private func moveToUniqueDestination(_ source: URL, directory: URL, filename: String) throws -> URL {
    while true {
        let destination = uniqueDestination(in: directory, filename: filename)
        // RENAME_EXCL fails instead of silently replacing a file another download just moved here.
        if renamex_np(source.path(percentEncoded: false), destination.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 {
            return destination
        }
        if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

private func discardPartial(_ r: inout DownloadRecord) {
    if let temp = r.tempURL { try? FileManager.default.removeItem(at: temp) }
    r.segments = []
    r.resumable = false
    r.etag = nil
}

private func withRetry<T>(_ maxAttempts: Int, _ retryDelay: (Int) -> Duration, _ body: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await body()
        } catch let error as DownloadError where error.isFatal {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            attempt += 1
            if attempt >= maxAttempts { throw error }
            try await Task.sleep(for: retryDelay(attempt - 1))
        }
    }
}

private func makeRequest(_ r: DownloadRecord) -> URLRequest {
    var request = URLRequest(url: r.url)
    for (name, value) in r.headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
}

private func describe(_ error: any Error) -> String {
    switch error {
    case DownloadError.httpStatus(let code) where code == 401 || code == 403:
        "HTTP \(code) – login or cookie may have expired"
    case DownloadError.httpStatus(let code): "HTTP \(code)"
    case DownloadError.fileChanged: "File changed on the server"
    case DownloadError.incomplete: "Connection closed before the download finished"
    default: error.localizedDescription
    }
}
