import Foundation
import Synchronization
import Testing
@testable import GomCore

final class Collector: Sendable {
    let items = Mutex<[AddRequest]>([])
    func append(_ item: AddRequest) { items.withLock { $0.append(item) } }
    var all: [AddRequest] { items.withLock { $0 } }
}

@Suite struct BridgeServerTests {
    func send(_ method: String, _ path: String, port: UInt16, token: String?, body: String? = nil) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.setValue("chrome-extension://abcdef", forHTTPHeaderField: "Origin")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Gom-Token") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    @Test func acceptsValidAddOverTCP() async throws {
        let collector = Collector()
        let server = try BridgeServer(port: 0, token: "secret") { collector.append($0) }
        let port = try await server.start()
        defer { server.stop() }

        let status = try await send("POST", "/add", port: port, token: "secret", body: #"{"url":"https://example.com/a.iso"}"#)

        #expect(status == 200)
        #expect(collector.all.map(\.url.absoluteString) == ["https://example.com/a.iso"])
    }

    @Test func rejectsMissingTokenOverTCP() async throws {
        let collector = Collector()
        let server = try BridgeServer(port: 0, token: "secret") { collector.append($0) }
        let port = try await server.start()
        defer { server.stop() }

        #expect(try await send("POST", "/add", port: port, token: nil, body: #"{"url":"https://example.com/a.iso"}"#) == 401)
        #expect(try await send("GET", "/ping", port: port, token: "secret") == 200)
        #expect(collector.all.isEmpty)
    }
}
