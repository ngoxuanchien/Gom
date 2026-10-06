import Foundation
import Synchronization
@testable import GomCore

/// One file served by the mock. Tests mutate `state` to change behavior mid-test.
final class MockFile: Sendable {
    struct Config: Sendable {
        var data: Data
        var etag: String? = #""v1""#
        var extraHeaders: [String: String] = [:]
        var supportsRanges = true
        var failFirst = 0              // fail this many non-probe requests with a network error
        var status: Int? = nil         // force this status on every request (e.g. 403)
        var chunkSize = 64 * 1024
        var chunkDelay: TimeInterval = 0
        var requests: [URLRequest] = []
        var rotateETag = false         // every response carries a new ETag, like a server farm with per-node ETags
    }

    let state: Mutex<Config>
    init(_ config: Config) { state = Mutex(config) }
    var requests: [URLRequest] { state.withLock { $0.requests } }
}

final class MockRegistry: Sendable {
    let files = Mutex<[String: MockFile]>([:])
}

/// Each `serve` call gets its own random host, so tests can run in parallel.
enum MockServer {
    static let registry = MockRegistry()

    static func serve(_ config: MockFile.Config, path: String = "/file.bin") -> (URL, MockFile) {
        let host = "\(UUID().uuidString.lowercased()).test"
        let file = MockFile(config)
        registry.files.withLock { $0[host] = file }
        return (URL(string: "https://\(host)\(path)")!, file)
    }

    static func streamer() -> HTTPStreamer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return HTTPStreamer(configuration: configuration)
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private let cancelled = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { cancelled.withLock { $0 = true } }

    override func startLoading() {
        let request = self.request
        guard let host = request.url?.host(), let file = MockServer.registry.files.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (config, shouldFail) = file.state.withLock { c -> (MockFile.Config, Bool) in
            c.requests.append(request)
            let isProbe = request.value(forHTTPHeaderField: "Range") == "bytes=0-0"
            if !isProbe && c.failFirst > 0 {
                c.failFirst -= 1
                return (c, true)
            }
            return (c, false)
        }
        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        let (status, headers, body) = Self.respond(to: request, config: config)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        DispatchQueue.global().async { [self] in
            deliver(body, from: 0, chunkSize: config.chunkSize, delay: config.chunkDelay)
        }
    }

    /// Sends one chunk, then schedules the next. asyncAfter instead of sleeping keeps
    /// many slow parallel downloads from starving the thread pool.
    private func deliver(_ body: Data, from offset: Int, chunkSize: Int, delay: TimeInterval) {
        if cancelled.withLock({ $0 }) { return }
        guard offset < body.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let end = min(offset + chunkSize, body.count)
        client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                deliver(body, from: end, chunkSize: chunkSize, delay: delay)
            }
        } else {
            deliver(body, from: end, chunkSize: chunkSize, delay: delay)
        }
    }

    static func respond(to request: URLRequest, config: MockFile.Config) -> (Int, [String: String], Data) {
        var headers = config.extraHeaders
        var config = config
        if config.rotateETag { config.etag = "\"\(UUID().uuidString)\"" }
        if let etag = config.etag { headers["ETag"] = etag }
        if let status = config.status { return (status, headers, Data()) }
        let total = config.data.count
        if config.supportsRanges,
           let range = request.value(forHTTPHeaderField: "Range"),
           let (low, high) = parseRange(range, total: total) {
            let ifRange = request.value(forHTTPHeaderField: "If-Range")
            if ifRange == nil || ifRange == config.etag || ifRange == config.extraHeaders["Last-Modified"] {
                headers["Content-Range"] = "bytes \(low)-\(high)/\(total)"
                headers["Content-Length"] = "\(high - low + 1)"
                return (206, headers, Data(config.data[low...high]))
            }
        }
        headers["Content-Length"] = "\(total)"
        return (200, headers, config.data)
    }

    static func parseRange(_ header: String, total: Int) -> (Int, Int)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let low = Int(parts[0]) else { return nil }
        let high = Int(parts[1]).map { min($0, total - 1) } ?? total - 1
        return low <= high ? (low, high) : nil
    }
}
