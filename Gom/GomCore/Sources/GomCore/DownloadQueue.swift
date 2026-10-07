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
    /// Called once all scheduled downloads that ran are completed or failed and nothing else is downloading.
    @ObservationIgnored public var onScheduleFinished: (() -> Void)?
    /// Where yt-dlp, ffmpeg and deno are. Set by the app at launch and after installing them.
    @ObservationIgnored public var videoTools: VideoTools
    /// Daily window scheduled downloads run in; nil = they never start. Set by the app, then call `refreshSchedule()`.
    @ObservationIgnored public var scheduleWindow: ScheduleWindow?

    let store: DownloadStore
    let streamer: HTTPStreamer
    let maxConcurrent: Int
    let retryDelay: @Sendable (Int) -> Duration
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastSave = ContinuousClock.now
    @ObservationIgnored private var lastSample: [UUID: (bytes: Int64, at: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var windowOpen = false
    /// Downloads stopped because the window closed: they go back to queued, not paused.
    @ObservationIgnored private var requeueing: Set<UUID> = []
    /// A scheduled download has completed or failed since the end action last fired.
    @ObservationIgnored private var scheduledRunPending = false

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

    /// Asks the server what the file is called before it is queued, e.g. to open the save panel in its category folder.
    public func serverFilename(for url: URL, headers: [String: String]) async -> String? {
        await GomCore.serverFilename(url: url, headers: headers, streamer: streamer)
    }

    @discardableResult
    public func add(url: URL, headers: [String: String] = [:], filename: String? = nil, directory: URL, categories: [FileCategory]? = nil, video: VideoQuality? = nil, scheduled: Bool = false, replaceExisting: Bool = false) -> UUID {
        if let existing = items.first(where: { $0.url == url && $0.video == video && $0.state != .completed }) {
            highlighted = existing.id
            return existing.id
        }
        var record = DownloadRecord(url: url, headers: headers, filename: filename.map(sanitizeFilename), directory: directory, categories: categories, video: video)
        record.scheduled = scheduled ? true : nil
        record.replaceExisting = replaceExisting ? true : nil
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

    /// Re-checks the window at `now`: starts scheduled downloads while it is open, moves running ones back to queued when it is closed.
    public func refreshSchedule(now: Date = .now) {
        windowOpen = scheduleWindow?.contains(now) ?? false
        if !windowOpen {
            // Work left for the next window: this run is not finished, so its end action is dropped.
            if items.contains(where: { $0.scheduled == true && ($0.state == .queued || $0.state == .downloading) }) {
                scheduledRunPending = false
            }
            for record in items where record.scheduled == true { requeue(record.id) }
        }
        schedule()
    }

    /// "Start in Schedule" / "Start Now". Scheduling a running download while the window is closed puts it back in the queue.
    public func setScheduled(_ id: UUID, _ scheduled: Bool) {
        update(id) { $0.scheduled = scheduled ? true : nil }
        if scheduled && !windowOpen { requeue(id) }
        persist()
        schedule()
    }

    /// Drops the downloads from the sidebar's unseen counts.
    public func markSeen(_ ids: [UUID]) {
        for id in ids { update(id) { $0.unseen = nil } }
        persist()
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
        for record in items where record.state == .queued && (record.scheduled != true || windowOpen) && running.count < maxConcurrent {
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

    /// Stops a running download; finished() puts it back to queued with its progress.
    private func requeue(_ id: UUID) {
        guard let task = running[id] else { return }
        requeueing.insert(id)
        task.cancel()
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
        // The engine's copy predates any schedule toggle made since the start.
        update(record.id) { var record = record; record.scheduled = $0.scheduled; $0 = record }
        if now - lastSave >= .seconds(2) { persist() }
    }

    private func finished(_ id: UUID, _ result: DownloadRecord) {
        running[id] = nil
        speeds[id] = nil
        lastSample[id] = nil
        var result = result
        let requeued = requeueing.remove(id) != nil && result.state == .paused
        if requeued { result.state = .queued }   // the window closed: wait for it to open again
        if result.state == .completed {
            result.completedAt = .now
            result.unseen = true
        }
        if items.contains(where: { $0.id == id }) {
            update(id) { result.scheduled = $0.scheduled; $0 = result }
            if result.state != .paused && !requeued {
                onFinished?(result)
                if result.scheduled == true { scheduledRunPending = true }   // pausing is not finishing
            }
        } else if result.state != .completed, let temp = result.tempURL {
            try? FileManager.default.removeItem(at: temp)   // removed while running
        }
        persist()
        schedule()
        checkScheduleFinished()
    }

    /// Scheduled downloads paused by hand don't count as pending; ones requeued at window close do.
    private func checkScheduleFinished() {
        guard scheduledRunPending, !shuttingDown, running.isEmpty,
              !items.contains(where: { $0.scheduled == true && ($0.state == .queued || $0.state == .downloading) }) else { return }
        scheduledRunPending = false
        onScheduleFinished?()
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
