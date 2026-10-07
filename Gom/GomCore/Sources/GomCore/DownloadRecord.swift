import Foundation

public enum DownloadState: Codable, Equatable, Sendable {
    case queued, downloading, paused, completed
    case failed(String)
}

public struct DownloadRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var url: URL
    public var headers: [String: String]
    public var filename: String?
    public var directory: URL
    /// Set when the file goes into a category subfolder of `directory` once its name is known; cleared after.
    public var categories: [FileCategory]?
    /// Set for video pages downloaded with yt-dlp; nil for plain files.
    public var video: VideoQuality?
    /// True when the download only runs inside the schedule window; nil otherwise (never false).
    public var scheduled: Bool?
    /// True when the user chose Replace in the save panel: the finished file overwrites one with the same name
    /// instead of getting a "(1)" suffix. Nil otherwise (never false).
    public var replaceExisting: Bool?
    public var totalBytes: Int64?
    public var etag: String?
    public var resumable: Bool
    public var segments: [Segment]
    public var state: DownloadState
    public var addedAt: Date
    /// When the download finished; nil until then, and for downloads finished before this was recorded.
    public var completedAt: Date?
    /// True from completion until the file is opened or marked seen; nil otherwise (never false), so older records count as seen.
    public var unseen: Bool?

    public init(url: URL, headers: [String: String] = [:], filename: String? = nil, directory: URL, categories: [FileCategory]? = nil, id: UUID = UUID(), addedAt: Date = .now, video: VideoQuality? = nil) {
        self.id = id
        self.url = url
        self.headers = headers
        self.filename = filename
        self.directory = directory
        self.categories = categories
        self.video = video
        self.totalBytes = nil
        self.etag = nil
        self.resumable = false
        self.segments = []
        self.state = .queued
        self.addedAt = addedAt
    }

    public var downloadedBytes: Int64 { segments.reduce(0) { $0 + $1.done } }

    /// Includes part of the id so two downloads with the same name never share a temp file.
    /// Video downloads use a hidden folder instead: yt-dlp names its own files and keeps `.part` files there.
    public var tempURL: URL? {
        if video != nil { return directory.appending(path: ".gom-\(id.uuidString.prefix(8))", directoryHint: .isDirectory) }
        return filename.map { directory.appending(path: "\($0).\(id.uuidString.prefix(8)).gomdownload") }
    }

    public var fileURL: URL? { filename.map { directory.appending(path: $0) } }
}

/// Groups the list by the day each download finished (or was added, if that wasn't recorded), newest day first,
/// keeping the given order inside a day. Anything not finished stays under today so an old paused or failed
/// download isn't tucked away.
public func daySections(_ items: [DownloadRecord], now: Date = .now, calendar: Calendar = .current) -> [(day: Date, items: [DownloadRecord])] {
    let today = calendar.startOfDay(for: now)
    var sections: [(day: Date, items: [DownloadRecord])] = []
    for item in items {
        let day = item.state == .completed ? min(calendar.startOfDay(for: item.completedAt ?? item.addedAt), today) : today
        if let i = sections.firstIndex(where: { $0.day == day }) {
            sections[i].items.append(item)
        } else {
            sections.append((day, [item]))
        }
    }
    return sections.sorted { $0.day > $1.day }
}
