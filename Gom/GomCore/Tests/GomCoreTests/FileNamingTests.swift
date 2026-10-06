import Foundation
import Testing
@testable import GomCore

@Suite struct FileNamingTests {
    @Test func sanitizeFilenameStripsPaths() {
        #expect(sanitizeFilename("report.pdf") == "report.pdf")
        #expect(sanitizeFilename("../../etc/passwd") == "passwd")
        #expect(sanitizeFilename("a\\b\\c.txt") == "c.txt")
        #expect(sanitizeFilename("time 10:30.txt") == "time 10-30.txt")
        #expect(sanitizeFilename("  ") == "download")
        #expect(sanitizeFilename("..") == "download")
        #expect(sanitizeFilename("") == "download")
        #expect(sanitizeFilename("bad\u{0}name\n.bin") == "badname.bin")
    }

    @Test func contentDispositionPrefersFilenameStar() {
        #expect(filenameFromContentDisposition(#"attachment; filename="report.pdf""#) == "report.pdf")
        #expect(filenameFromContentDisposition("attachment; filename=plain.zip") == "plain.zip")
        #expect(filenameFromContentDisposition(#"attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf; filename="resume.pdf""#) == "résumé.pdf")
        #expect(filenameFromContentDisposition("inline") == nil)
    }

    @Test func uniqueDestinationAppendsCounter() throws {
        let dir = try makeTempDir()
        func touch(_ name: String) {
            FileManager.default.createFile(atPath: dir.appending(path: name).path(percentEncoded: false), contents: Data())
        }
        #expect(uniqueDestination(in: dir, filename: "a.iso").lastPathComponent == "a.iso")
        touch("a.iso")
        #expect(uniqueDestination(in: dir, filename: "a.iso").lastPathComponent == "a (1).iso")
        touch("a (1).iso")
        #expect(uniqueDestination(in: dir, filename: "a.iso").lastPathComponent == "a (2).iso")
        touch("README")
        #expect(uniqueDestination(in: dir, filename: "README").lastPathComponent == "README (1)")
    }

    @Test func parseURLListKeepsOnlyHTTP() {
        let text = """
        https://example.com/a.iso
          http://example.com/b.zip  

        file:///etc/passwd
        javascript:alert(1)
        not a url
        """
        #expect(parseURLList(text).map(\.absoluteString) == ["https://example.com/a.iso", "http://example.com/b.zip"])
    }
}
