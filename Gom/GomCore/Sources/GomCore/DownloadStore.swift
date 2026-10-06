import Foundation

public struct DownloadStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static var appSupport: DownloadStore {
        DownloadStore(fileURL: URL.applicationSupportDirectory.appending(path: "Gom/downloads.json"))
    }

    /// Missing file → []. A corrupt file is moved aside (never overwritten) and [] is returned.
    public func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([DownloadRecord].self, from: data)
        } catch {
            let aside = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return []
        }
    }

    /// Atomic write, owner-only permissions (the file holds cookies).
    public func save(_ records: [DownloadRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))
    }
}
