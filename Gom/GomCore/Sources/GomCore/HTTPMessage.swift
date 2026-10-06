import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum ParseResult: Equatable, Sendable {
    case incomplete, invalid, tooLarge
    case complete(HTTPRequest)
}

public let maxRequestSize = 1024 * 1024

/// Minimal HTTP/1.1 request parser: request line, headers, body by Content-Length. No chunked encoding.
public func parseHTTPRequest(_ data: Data) -> ParseResult {
    if data.count > maxRequestSize { return .tooLarge }
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
    guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }

    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count == 3 else { return .invalid }

    var headers: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { return .invalid }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    let length = Int(headers["content-length"] ?? "0") ?? -1
    guard length >= 0 else { return .invalid }
    if length > maxRequestSize { return .tooLarge }   // checked first so the sum below can't overflow
    let bodyStart = headerEnd.upperBound
    if bodyStart - data.startIndex + length > maxRequestSize { return .tooLarge }
    guard data.endIndex - bodyStart >= length else { return .incomplete }

    return .complete(HTTPRequest(
        method: String(requestLine[0]),
        path: String(requestLine[1]),
        headers: headers,
        body: Data(data[bodyStart..<bodyStart + length])
    ))
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, json: String) {
        self.status = status
        self.body = Data(json.utf8)
    }

    public func serialized() -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found"]
        let head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
