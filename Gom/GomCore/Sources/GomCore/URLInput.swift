import Foundation

/// Only http(s) URLs with a host may be downloaded; blocks file://, javascript:, etc.
public func isDownloadableURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    return url.host() != nil
}

/// One URL per line; blank lines and anything not downloadable are dropped.
public func parseURLList(_ text: String) -> [URL] {
    text.split(whereSeparator: \.isNewline)
        .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        .filter(isDownloadableURL)
}
