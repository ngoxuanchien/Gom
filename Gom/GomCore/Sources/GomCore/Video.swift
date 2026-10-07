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
