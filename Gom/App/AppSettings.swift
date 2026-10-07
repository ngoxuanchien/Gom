import Foundation
import GomCore

/// Keys shared with SettingsView's @AppStorage.
enum AppSettings {
    static let defaultPort = 47615
    private static var defaults: UserDefaults { .standard }

    static var port: Int { defaults.object(forKey: "port") as? Int ?? defaultPort }
    static var token: String { defaults.string(forKey: "token") ?? "" }

    static var downloadDirectory: URL {
        let path = defaults.string(forKey: "downloadDirectory") ?? ""
        return path.isEmpty ? .downloadsDirectory : URL(filePath: path, directoryHint: .isDirectory)
    }

    static var sortByType: Bool { defaults.object(forKey: "sortByType") as? Bool ?? true }
    static var notifications: Bool { defaults.object(forKey: "notifications") as? Bool ?? true }
    /// Combined download speed cap in KB/s (1 KB = 1000 bytes, like the speeds shown); 0 = unlimited.
    static var speedLimitKB: Int { defaults.integer(forKey: "speedLimitKB") }
    /// Quality for pasted video links; the extension's menu picks its own.
    static var videoQuality: VideoQuality {
        defaults.string(forKey: "videoQuality").flatMap(VideoQuality.init(rawValue:)) ?? .best
    }
    /// Daily window for scheduled downloads, in minutes since midnight; 01:00–06:00 by default.
    static var scheduleWindow: ScheduleWindow {
        ScheduleWindow(start: defaults.object(forKey: "scheduleStart") as? Int ?? 60,
                       end: defaults.object(forKey: "scheduleEnd") as? Int ?? 360)
    }
    static var scheduleAction: ScheduleAction {
        defaults.string(forKey: "scheduleAction").flatMap(ScheduleAction.init(rawValue:)) ?? .none
    }

    /// Edited in SettingsView; stored as JSON.
    static var categories: [FileCategory] {
        get { defaults.data(forKey: "fileCategories").flatMap { try? JSONDecoder().decode([FileCategory].self, from: $0) } ?? defaultFileCategories }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "fileCategories") }
    }

    /// Where `filename` is saved: its type's subfolder when sorting is on, else the download folder.
    static func directory(for filename: String) -> URL {
        guard sortByType, let folder = categoryFolder(for: filename, in: categories) else { return downloadDirectory }
        return downloadDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    static func ensureToken() {
        if token.isEmpty { defaults.set(generateToken(), forKey: "token") }
    }
}

/// What Gom does once scheduled downloads finish.
enum ScheduleAction: String, CaseIterable {
    case none, quit, sleep

    var label: String {
        switch self {
        case .none: "Do Nothing"
        case .quit: "Quit Gom"
        case .sleep: "Sleep Mac"
        }
    }
}
