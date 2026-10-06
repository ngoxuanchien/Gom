import Foundation

public struct ProbeInfo: Equatable, Sendable {
    public var totalBytes: Int64?
    public var acceptsRanges: Bool
    public var validator: String?
    public var filename: String
}

/// Interprets the response to a `Range: bytes=0-0` request.
public func parseProbe(_ response: HTTPURLResponse) -> ProbeInfo {
    var total: Int64?
    var ranged = false
    if response.statusCode == 206,
       let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
       let slash = contentRange.lastIndex(of: "/"),
       let size = Int64(contentRange[contentRange.index(after: slash)...]) {
        total = size
        ranged = true
    } else if response.statusCode == 200, response.expectedContentLength >= 0 {
        total = response.expectedContentLength
    }
    // If-Range only works with strong validators; a weak ETag would make every resume restart.
    let etag = response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
    let validator = etag ?? response.value(forHTTPHeaderField: "Last-Modified")
    let name = response.value(forHTTPHeaderField: "Content-Disposition").flatMap(filenameFromContentDisposition)
        ?? response.url?.lastPathComponent
        ?? ""
    return ProbeInfo(totalBytes: total, acceptsRanges: ranged, validator: validator, filename: sanitizeFilename(name))
}
