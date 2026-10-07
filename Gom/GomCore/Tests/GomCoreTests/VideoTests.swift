import Foundation
import Testing
@testable import GomCore

@Suite struct VideoTests {
    @Test func recognizesVideoHostsAndSubdomains() {
        #expect(isVideoPage(URL(string: "https://www.youtube.com/watch?v=abc")!))
        #expect(isVideoPage(URL(string: "https://m.youtube.com/watch?v=abc")!))
        #expect(isVideoPage(URL(string: "https://youtu.be/abc")!))
        #expect(isVideoPage(URL(string: "https://VIMEO.com/123")!))
    }

    @Test func rejectsLookalikesAndOtherHosts() {
        #expect(!isVideoPage(URL(string: "https://notyoutube.com/watch")!))
        #expect(!isVideoPage(URL(string: "https://youtube.com.evil.example/x")!))
        #expect(!isVideoPage(URL(string: "https://example.com/video.mp4")!))
        #expect(!isVideoPage(URL(string: "ftp://youtube.com/x")!))
    }

    @Test func qualityArguments() {
        #expect(VideoQuality.best.formatArguments == ["-S", "res,ext:mp4:m4a", "--merge-output-format", "mp4"])
        #expect(VideoQuality.p1080.formatArguments == ["-S", "res:1080,ext:mp4:m4a", "--merge-output-format", "mp4"])
        #expect(VideoQuality.p720.formatArguments == ["-S", "res:720,ext:mp4:m4a", "--merge-output-format", "mp4"])
        #expect(VideoQuality.audio.formatArguments == ["-f", "ba/b", "-x", "--audio-format", "m4a"])
        #expect(VideoQuality(rawValue: "1080p") == .p1080)
    }

    @Test func fileRecordEncodesWithoutVideoKeyAndRoundTrips() throws {
        // Records saved before phase 2 have no "video" key; nil must encode the same way and decode back.
        let record = DownloadRecord(url: URL(string: "https://example.com/a.zip")!, directory: URL(filePath: "/tmp"))
        let data = try JSONEncoder().encode(record)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"video\""))
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: data) == record)
    }

    @Test func videoRecordTempURLIsHiddenFolder() {
        let id = UUID(uuidString: "12345678-0000-0000-0000-000000000000")!
        let record = DownloadRecord(url: URL(string: "https://youtu.be/x")!, directory: URL(filePath: "/tmp/dl"), id: id, video: .best)
        #expect(record.tempURL?.path(percentEncoded: false) == "/tmp/dl/.gom-12345678/")
    }
}
