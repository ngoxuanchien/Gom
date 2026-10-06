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
