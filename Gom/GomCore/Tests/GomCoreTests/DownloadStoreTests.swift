import Foundation
import Testing
@testable import GomCore

@Suite struct DownloadStoreTests {
    @Test func roundTrip() throws {
        let dir = try makeTempDir()
        let store = DownloadStore(fileURL: dir.appending(path: "nested/downloads.json"))
        var record = DownloadRecord(url: URL(string: "https://example.com/a.iso")!, headers: ["Cookie": "x=1"], directory: dir)
        record.segments = [Segment(start: 0, end: 99, done: 40)]
        record.state = .failed("HTTP 500")

        try store.save([record])

        #expect(store.load() == [record])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path(percentEncoded: false))
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func missingFileLoadsEmpty() throws {
        let store = DownloadStore(fileURL: try makeTempDir().appending(path: "downloads.json"))
        #expect(store.load().isEmpty)
    }

    @Test func corruptFileIsMovedAside() throws {
        let dir = try makeTempDir()
        let store = DownloadStore(fileURL: dir.appending(path: "downloads.json"))
        try Data("{not json".utf8).write(to: store.fileURL)

        #expect(store.load().isEmpty)

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(!names.contains("downloads.json"))
        let movedAside = names.contains { $0.hasPrefix("downloads.json.corrupt-") }
        #expect(movedAside)
    }
}
