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

    static func ensureToken() {
        if token.isEmpty { defaults.set(generateToken(), forKey: "token") }
    }
}
