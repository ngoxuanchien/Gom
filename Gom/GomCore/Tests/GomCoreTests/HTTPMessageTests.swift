import Foundation
import Testing
@testable import GomCore

@Suite struct HTTPMessageTests {
    func raw(_ text: String) -> Data { Data(text.utf8) }

    @Test func parsesCompleteRequest() {
        let result = parseHTTPRequest(raw("POST /add HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\nX-Gom-Token: abc\r\n\r\nhello"))
        #expect(result == .complete(HTTPRequest(
            method: "POST",
            path: "/add",
            headers: ["host": "127.0.0.1", "content-length": "5", "x-gom-token": "abc"],
            body: Data("hello".utf8)
        )))
    }

    @Test func waitsForHeadersAndBody() {
        #expect(parseHTTPRequest(raw("POST /add HTTP/1.1\r\nContent-Le")) == .incomplete)
        #expect(parseHTTPRequest(raw("POST /add HTTP/1.1\r\nContent-Length: 10\r\n\r\nhello")) == .incomplete)
    }

    @Test func rejectsGarbage() {
        #expect(parseHTTPRequest(raw("NONSENSE\r\n\r\n")) == .invalid)
        #expect(parseHTTPRequest(raw("GET / HTTP/1.1\r\nno-colon-here\r\n\r\n")) == .invalid)
        #expect(parseHTTPRequest(raw("GET / HTTP/1.1\r\nContent-Length: -3\r\n\r\n")) == .invalid)
    }

    @Test func rejectsOversizedRequests() {
        #expect(parseHTTPRequest(raw("POST /add HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n")) == .tooLarge)
        #expect(parseHTTPRequest(Data(count: maxRequestSize + 1)) == .tooLarge)
    }

    @Test func serializesResponse() {
        let text = String(decoding: HTTPResponse(status: 401, json: #"{"ok":false}"#).serialized(), as: UTF8.self)
        #expect(text == "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"ok\":false}")
    }
}
