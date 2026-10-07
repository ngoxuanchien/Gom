import Foundation

/// Reduces any server- or browser-supplied name to a single safe path component.
public func sanitizeFilename(_ raw: String) -> String {
    let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    let visible = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    let name = visible.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
    return name.isEmpty || name == "." || name == ".." ? "download" : name
}

/// RFC 6266: `filename*=UTF-8''…` wins over `filename=…`.
/// ponytail: splits on ";" so a quoted name containing ";" is cut short; use a real parser if that shows up.
public func filenameFromContentDisposition(_ header: String) -> String? {
    let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    for part in parts where part.lowercased().hasPrefix("filename*=") {
        let value = part.dropFirst("filename*=".count)
        if let marker = value.range(of: "''"), let decoded = String(value[marker.upperBound...]).removingPercentEncoding {
            return decoded
        }
    }
    for part in parts where part.lowercased().hasPrefix("filename=") {
        let value = part.dropFirst("filename=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !value.isEmpty { return value }
    }
    return nil
}

/// `directory/filename`, or Finder-style `name (1).ext`, `name (2).ext`… if taken.
public func uniqueDestination(in directory: URL, filename: String) -> URL {
    let first = directory.appending(path: filename)
    guard FileManager.default.fileExists(atPath: first.path(percentEncoded: false)) else { return first }
    let ext = first.pathExtension
    let stem = first.deletingPathExtension().lastPathComponent
    var counter = 1
    while true {
        let name = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
        let candidate = directory.appending(path: name)
        if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        counter += 1
    }
}

/// A subfolder of the download folder and the extensions sorted into it.
public struct FileCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var folder: String
    /// As typed in Settings: separated by spaces or commas, leading dots allowed.
    public var extensions: String

    public init(folder: String, extensions: String, id: UUID = UUID()) {
        self.id = id
        self.folder = folder
        self.extensions = extensions
    }
}

/// Default folder tree inside the download folder.
public let defaultFileCategories: [FileCategory] = [
    FileCategory(folder: "Documents", extensions: "pdf doc docx xls xlsx ppt pptx odt ods odp rtf txt csv md epub pages numbers key"),
    FileCategory(folder: "Compressed", extensions: "zip rar 7z tar gz tgz bz2 xz zst"),
    FileCategory(folder: "Music", extensions: "mp3 m4a aac flac wav ogg opus"),
    FileCategory(folder: "Video", extensions: "mp4 mkv mov avi webm m4v flv wmv"),
    FileCategory(folder: "Programs", extensions: "dmg pkg exe msi deb rpm apk iso"),
    FileCategory(folder: "Images", extensions: "jpg jpeg png gif webp heic svg bmp tiff"),
]

/// The first category subfolder listing `filename`'s extension, or nil to keep it at the top of the download folder.
public func categoryFolder(for filename: String, in categories: [FileCategory]) -> String? {
    let ext = (filename as NSString).pathExtension.lowercased()
    guard !ext.isEmpty else { return nil }
    let match = categories.first { category in
        category.extensions.lowercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." }).contains { $0 == ext }
    }
    guard let folder = match?.folder.trimmingCharacters(in: .whitespaces), !folder.isEmpty else { return nil }
    return sanitizeFilename(folder)   // typed by the user, but must stay one level inside the download folder
}

/// The category a download belongs to in the sidebar. Before the name is known it guesses from the URL;
/// a video page counts as the format yt-dlp will produce.
public func categoryFolder(of record: DownloadRecord, in categories: [FileCategory]) -> String? {
    let name = record.filename ?? record.video.map { $0 == .audio ? "x.m4a" : "x.mp4" } ?? record.url.lastPathComponent
    return categoryFolder(for: name, in: categories)
}
