import Foundation
import Testing
@testable import GomCore

@Suite struct ProbeTests {
    let url = URL(string: "https://example.com/files/ubuntu.iso")!

    func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func partialContentMeansRangesSupported() {
        let info = parseProbe(response(206, ["Content-Range": "bytes 0-0/123456789", "ETag": #""abc""#]))
        #expect(info == ProbeInfo(totalBytes: 123_456_789, acceptsRanges: true, validator: #""abc""#, filename: "ubuntu.iso"))
    }

    @Test func fullResponseMeansSingleConnection() {
        let info = parseProbe(response(200, ["Content-Length": "500"]))
        #expect(info.acceptsRanges == false)
        #expect(info.totalBytes == 500)
    }

    @Test func unknownTotalIsNotRanged() {
        let info = parseProbe(response(206, ["Content-Range": "bytes 0-0/*"]))
        #expect(info.acceptsRanges == false)
        #expect(info.totalBytes == nil)
    }

    @Test func weakETagFallsBackToLastModified() {
        let info = parseProbe(response(206, [
            "Content-Range": "bytes 0-0/10",
            "ETag": #"W/"weak""#,
            "Last-Modified": "Tue, 06 Oct 2026 10:00:00 GMT",
        ]))
        #expect(info.validator == "Tue, 06 Oct 2026 10:00:00 GMT")
    }

    @Test func contentDispositionWinsOverURLAndIsSanitized() {
        let info = parseProbe(response(206, [
            "Content-Range": "bytes 0-0/10",
            "Content-Disposition": #"attachment; filename="../real.iso""#,
        ]))
        #expect(info.filename == "real.iso")
    }
}
