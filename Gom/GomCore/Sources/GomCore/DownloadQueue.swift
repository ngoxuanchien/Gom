import Foundation
import Observation

@MainActor
@Observable
public final class DownloadQueue {
    public private(set) var items: [DownloadRecord] = []
    public private(set) var speeds: [UUID: Double] = [:]
    public var highlighted: UUID?
    /// Called when a download ends completed or failed; not on pause, removal or shutdown.
    @ObservationIgnored public var onFinished: ((DownloadRecord) -> Void)?
    /// Where yt-dlp, ffmpeg and deno are. Set by the app at launch and after installing them.
    @ObservationIgnored public var videoTools: VideoTools

    let store: DownloadStore
    let streamer: HTTPStreamer
    let maxConcurrent: Int
    let retryDelay: @Sendable (Int) -> Duration
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastSave = ContinuousClock.now
    @ObservationIgnored private var lastSample: [UUID: (bytes: Int64, at: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var shuttingDown = false

    public init(
        store: DownloadStore,
        streamer: HTTPStreamer = HTTPStreamer(),
        maxConcurrent: Int = 3,
        retryDelay: @escaping @Sendable (Int) -> Duration = defaultRetryDelay,
        videoTools: VideoTools = VideoTools()
    ) {
        self.store = store
        self.streamer = streamer
        self.maxConcurrent = maxConcurrent
        self.retryDelay = retryDelay
        self.videoTools = videoTools   // before schedule(): a persisted video must not see "not installed"
        // A record still marked downloading was interrupted by a crash: queue it again.
        items = store.load().map { record in
            var record = record
            if record.state == .downloading { record.state = .queued }
            return record
        }
        schedule()
    }

    public var activeCount: Int { running.count }

    /// Combined speed cap for all downloads in bytes/s; 0 = unlimited. Applies to running downloads at once.
    public var bandwidthLimit: Int {
        get { streamer.bytesPerSecond }
        set { streamer.bytesPerSecond = newValue }
    }

    @discardableResult
    public func add(url: URL, headers: [String: String] = [:], filename: String? = nil, directory: URL, categories: [FileCategory]? = nil, video: VideoQuality? = nil) -> UUID {
        if let existing = items.first(where: { $0.url == url && $0.video == video && $0.state != .completed }) {
            highlighted = existing.id
            return existing.id
        }
        let record = DownloadRecord(url: url, headers: headers, filename: filename.map(sanitizeFilename), directory: directory, categories: categories, video: video)
        items.append(record)
        persist()
        schedule()
        return record.id
    }

    public func pause(_ id: UUID) {
        if let task = running[id] {
            task.cancel()   // runDownload returns .paused; finished() stores it
        } else {
            update(id) { if $0.state == .queued { $0.state = .paused } }
            persist()
        }
    }

    /// Resume a paused download or retry a failed one.
    public func resume(_ id: UUID) {
        update(id) { record in
            switch record.state {
            case .paused, .failed: record.state = .queued
            default: break
            }
        }
        persist()
        schedule()
    }

    /// Re-queues video downloads that failed only because yt-dlp or ffmpeg was missing.
    public func retryMissingTools() {
        for item in items where item.video != nil {
            if case .failed(let reason) = item.state, reason.hasSuffix(" not installed") { resume(item.id) }
        }
    }

    public func pauseAll() {
        for record in items where record.state == .queued || record.state == .downloading { pause(record.id) }
    }

    /// Resumes paused downloads only; failed ones are retried one by one.
    public func resumeAll() {
        for record in items where record.state == .paused { resume(record.id) }
    }

    /// Unfinished downloads always lose their temp file; `deleteFile` also deletes a finished file.
    public func remove(_ id: UUID, deleteFile: Bool) {
        guard let record = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        if let task = running[id] {
            task.cancel()   // finished() deletes the temp file once the engine has stopped writing
        } else if record.state == .completed {
            if deleteFile, let file = record.fileURL { try? FileManager.default.removeItem(at: file) }
        } else if let temp = record.tempURL {
            try? FileManager.default.removeItem(at: temp)
        }
        persist()
    }

    /// Called on app quit: stops running downloads and saves them as queued so they resume on next launch.
    public func shutdown() async {
        shuttingDown = true
        let tasks = running
        for task in tasks.values { task.cancel() }
        for task in tasks.values { await task.value }
        for id in tasks.keys { update(id) { if $0.state == .paused { $0.state = .queued } } }
        persist()
    }

    private func schedule() {
        guard !shuttingDown else { return }
        for record in items where record.state == .queued && running.count < maxConcurrent {
            start(record)
        }
    }

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

    private func progress(_ record: DownloadRecord) {
        // Progress can arrive after the download already finished or was paused; ignore it then.
        guard running[record.id] != nil, items.first(where: { $0.id == record.id })?.state == .downloading else { return }
        let now = ContinuousClock.now
        if let last = lastSample[record.id] {
            let seconds = (now - last.at) / .seconds(1)
            if seconds > 0 { speeds[record.id] = Double(record.downloadedBytes - last.bytes) / seconds }
        }
        lastSample[record.id] = (record.downloadedBytes, now)
        update(record.id) { $0 = record }
        if now - lastSave >= .seconds(2) { persist() }
    }

    private func finished(_ id: UUID, _ result: DownloadRecord) {
        running[id] = nil
        speeds[id] = nil
        lastSample[id] = nil
        if items.contains(where: { $0.id == id }) {
            update(id) { $0 = result }
            if result.state != .paused { onFinished?(result) }
        } else if result.state != .completed, let temp = result.tempURL {
            try? FileManager.default.removeItem(at: temp)   // removed while running
        }
        persist()
        schedule()
    }

    private func update(_ id: UUID, _ change: (inout DownloadRecord) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func persist() {
        lastSave = .now
        do {
            try store.save(items)
        } catch {
            print("Gom: failed to save downloads: \(error)")
        }
    }
}
