import Foundation
import Testing
@testable import GomCore

@Suite struct HTTPStreamerTests {
    @Test func deliversResponseThenWholeBody() async throws {
        let data = testData(300_000)
        let (url, _) = MockServer.serve(.init(data: data))
        var status = 0
        var body = Data()
        for try await event in MockServer.streamer().stream(URLRequest(url: url)) {
            switch event {
            case .response(let response): status = response.statusCode
            case .data(let chunk): body.append(chunk)
            }
        }
        #expect(status == 200)
        #expect(body == data)
    }

    @Test func rangeRequestGetsPartialContent() async throws {
        let data = testData(1000)
        let (url, _) = MockServer.serve(.init(data: data))
        var request = URLRequest(url: url)
        request.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        var status = 0
        var body = Data()
        for try await event in MockServer.streamer().stream(request) {
            switch event {
            case .response(let response): status = response.statusCode
            case .data(let chunk): body.append(chunk)
            }
        }
        #expect(status == 206)
        #expect(body == data[100...199])
    }

    @Test func keepsCookieHeaderFromRequest() async throws {
        let (url, file) = MockServer.serve(.init(data: testData(10)))
        var request = URLRequest(url: url)
        request.setValue("a=1", forHTTPHeaderField: "Cookie")
        for try await _ in MockServer.streamer().stream(request) {}
        #expect(file.requests.first?.value(forHTTPHeaderField: "Cookie") == "a=1")
    }
}
