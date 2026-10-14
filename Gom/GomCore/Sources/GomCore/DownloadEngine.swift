import Foundation
import Synchronization

public enum DownloadError: Error, Equatable {
    case httpStatus(Int)
    case fileChanged
    case incomplete
    case notEnoughSpace(needed: Int64, available: Int64)

    var isFatal: Bool {
        switch self {
        case .httpStatus(let code): code == 401 || code == 403
        case .fileChanged, .notEnoughSpace: true
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
    func end(of index: Int) -> Int64 { segments.withLock { $0[index].end } }

    /// Adds `count` written bytes to segment `index`, never past its end: a split may have moved the end
    /// below bytes already in flight (they are the same bytes the new segment fetches, so writing them is harmless).
    /// If this completes the segment, the largest remainder is split in the same critical section, so a snapshot
    /// never shows a freed connection that is about to be taken again. Returns the new segment's index to fetch next.
    func add(_ count: Int64, to index: Int) -> Int? {
        segments.withLock { segments in
            let wasComplete = segments[index].isComplete
            segments[index].done = min(segments[index].done + count, segments[index].end - segments[index].start + 1)
            guard !wasComplete, segments[index].isComplete else { return nil }
            return splitLargest(&segments)
        }
    }

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
    freeSpace: @escaping @Sendable (URL) -> Int64? = availableCapacity,
    onProgress: @escaping @Sendable (DownloadRecord) -> Void = { _ in }
) async -> DownloadRecord {
    var r = record
    r.state = .downloading
    var restarted = false
    var singleConnection = false
    while true {
        do {
            if needsPrepare(r) {
                try await prepare(&r, streamer: streamer, maxAttempts: maxAttempts, retryDelay: retryDelay, singleConnection: singleConnection, freeSpace: freeSpace)
                onProgress(r)   // the queue learns the segment count, and so the connections used, before the first chunk
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
private func prepare(_ r: inout DownloadRecord, streamer: HTTPStreamer, maxAttempts: Int, retryDelay: @escaping @Sendable (Int) -> Duration, singleConnection: Bool, freeSpace: (URL) -> Int64?) async throws {
    let current = r
    let info = try await withRetry(maxAttempts, retryDelay) { try await probe(current, streamer: streamer) }
    discardPartial(&r)
    r.filename = sanitizeFilename(r.filename ?? info.filename)
    // The name may only be known now (Content-Disposition). Sort once so a later restart keeps the folder.
    if let categories = r.categories {
        if let folder = categoryFolder(for: r.filename!, in: categories) {
            r.directory.append(path: folder, directoryHint: .isDirectory)
        }
        r.categories = nil
    }
    r.totalBytes = info.totalBytes
    r.etag = info.validator
    r.resumable = !singleConnection && info.acceptsRanges && info.totalBytes != nil
    r.segments = r.resumable
        ? makeSegments(total: info.totalBytes!)
        : [Segment(start: 0, end: (info.totalBytes ?? .max) - 1)]

    let temp = r.tempURL!
    try FileManager.default.createDirectory(at: r.directory, withIntermediateDirectories: true)
    if let needed = r.totalBytes, let available = freeSpace(r.directory), needed > available {
        throw DownloadError.notEnoughSpace(needed: needed, available: available)
    }
    guard FileManager.default.createFile(atPath: temp.path(percentEncoded: false), contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    if r.resumable {
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(r.totalBytes!))
    }
}

/// The name the server gives `url` (Content-Disposition, else the final URL), or nil if it can't be asked.
public func serverFilename(url: URL, headers: [String: String], streamer: HTTPStreamer) async -> String? {
    let record = DownloadRecord(url: url, headers: headers, directory: .temporaryDirectory)
    return try? await sanitizeFilename(probe(record, streamer: streamer).filename)
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
            // One task per connection: when its segment completes, it fetches the split it was handed.
            group.addTask {
                var current: Int? = index
                while let segment = current {
                    current = try await withRetry(maxAttempts, retryDelay, progress: { box.segment(segment).done }) {
                        try await fetchSegment(segment, of: base, box: box, streamer: streamer, onProgress: onProgress)
                    }
                }
            }
        }
        try await group.waitForAll()
    }
}

/// Fetches what is left of segment `index`. Returns the segment split off for this connection
/// when it finished, or nil when there was nothing left to split.
private func fetchSegment(
    _ index: Int,
    of base: DownloadRecord,
    box: ProgressBox,
    streamer: HTTPStreamer,
    onProgress: @Sendable (DownloadRecord) -> Void
) async throws -> Int? {
    let segment = box.segment(index)
    guard !segment.isComplete, let temp = base.tempURL else { return nil }
    let handle = try FileHandle(forWritingTo: temp)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(segment.nextOffset))
    var offset = segment.nextOffset
    let limiter = streamer.limiter

    // Under a speed limit the range is fetched in pieces, each request sent only once the shared
    // bucket has room for it, so the network never runs ahead of the cap. Unlimited: one request.
    // The end is reread throughout: another connection may take over the second half of this segment.
    while offset <= box.end(of: index) {
        let rate = limiter.bytesPerSecond
        let end = box.end(of: index)
        let last = rate > 0 ? min(end, offset + Int64(pieceSize(for: rate)) - 1) : end
        if rate > 0 { try await limiter.acquire(Int(last - offset + 1)) }
        var request = makeRequest(base)
        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
        if let etag = base.etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }

        var limitArrived = false
        response: for try await event in streamer.stream(request) {
            switch event {
            case .response(let response):
                // 200 to a range request: the file changed (If-Range failed) or ranges stopped working.
                if response.statusCode == 200 { throw DownloadError.fileChanged }
                guard response.statusCode == 206 else { throw DownloadError.httpStatus(response.statusCode) }
            case .data(let data):
                let chunk = data.prefix(max(0, Int(min(last, box.end(of: index)) + 1 - offset)))
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
                let next = box.add(Int64(chunk.count), to: index)
                if box.shouldReport() {
                    var snapshot = base
                    snapshot.segments = box.snapshot
                    onProgress(snapshot)
                }
                // Leaving the loop ends the stream, which cancels the request.
                if let next { return next }
                if offset > box.end(of: index) { break response }   // the rest of this range was split off
                // A limit set during an unlimited request: carry on in paced pieces from here.
                if rate == 0, limiter.bytesPerSecond > 0 {
                    limitArrived = true
                    break response
                }
            }
        }
        try Task.checkCancellation()
        if offset <= min(last, box.end(of: index)) && !limitArrived { throw DownloadError.incomplete }
    }
    return nil
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
                // ponytail: no ranges to split, so this only paces the reader; URLSession keeps reading
                // ahead into memory. Pause/resume the response (or a pull-based client) if that bites.
                try await streamer.limiter.acquire(data.count)
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
    if r.replaceExisting == true {
        // rename(2) swaps the file in atomically, so the old one stays until the new one is complete.
        let destination = r.directory.appending(path: filename)
        if rename(temp.path(percentEncoded: false), destination.path(percentEncoded: false)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    } else {
        r.filename = try moveToUniqueDestination(temp, directory: r.directory, filename: filename).lastPathComponent
    }
    r.state = .completed
    r.headers = [:]   // don't keep cookies around once they're no longer needed
}

/// Retries when another download claims the same name between the check and the move.
func moveToUniqueDestination(_ source: URL, directory: URL, filename: String) throws -> URL {
    while true {
        let destination = uniqueDestination(in: directory, filename: filename)
        // RENAME_EXCL fails instead of silently replacing a file another download just moved here.
        if renamex_np(source.path(percentEncoded: false), destination.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0 {
            return destination
        }
        if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Free bytes on `directory`'s volume as macOS counts them for user-requested files; nil if it can't say.
public func availableCapacity(_ directory: URL) -> Int64? {
    try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
}

private func discardPartial(_ r: inout DownloadRecord) {
    if let temp = r.tempURL { try? FileManager.default.removeItem(at: temp) }
    r.segments = []
    r.resumable = false
    r.etag = nil
}

/// Retries `body` up to `maxAttempts` times in a row. With `progress`, an attempt that moved it forward
/// before failing doesn't count: a long download over a flaky link only gives up once it stops getting anywhere.
private func withRetry<T>(_ maxAttempts: Int, _ retryDelay: (Int) -> Duration, progress: () -> Int64 = { 0 }, _ body: () async throws -> T) async throws -> T {
    var attempt = 0
    var reached = progress()
    while true {
        do {
            return try await body()
        } catch let error as DownloadError where error.isFatal {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let now = progress()
            if now > reached {
                reached = now
                attempt = 0
            }
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
    case DownloadError.notEnoughSpace(let needed, let available):
        "Not enough disk space: needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free"
    default: error.localizedDescription
    }
}
