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

    @Test func restoringExtensionAddsOnlyAMissingOne() {
        #expect(restoringExtension("bao-cao", from: "report.pdf") == "bao-cao.pdf")
        #expect(restoringExtension("bao-cao.", from: "report.pdf") == "bao-cao.pdf")
        #expect(restoringExtension("bao-cao.txt", from: "report.pdf") == "bao-cao.txt")
        #expect(restoringExtension("backup", from: "data.tar.gz") == "backup.gz")
        #expect(restoringExtension("notes", from: "README") == "notes")
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

    @Test func categoryFolderMatchesExtension() {
        let defaults = defaultFileCategories
        #expect(categoryFolder(for: "A5-convex-hulls.pdf", in: defaults) == "Documents")
        #expect(categoryFolder(for: "backup.tar.GZ", in: defaults) == "Compressed")
        #expect(categoryFolder(for: "Xcode.dmg", in: defaults) == "Programs")
        #expect(categoryFolder(for: "README", in: defaults) == nil)
        #expect(categoryFolder(for: "data.unknownext", in: defaults) == nil)
    }

    @Test func categoryFolderUsesEditedCategories() {
        let custom = [
            FileCategory(folder: "  ", extensions: "txt"),
            FileCategory(folder: "Sách", extensions: ".PDF, Epub"),
            FileCategory(folder: "../Escape", extensions: "zip"),
        ]
        #expect(categoryFolder(for: "a.pdf", in: custom) == "Sách")
        #expect(categoryFolder(for: "a.epub", in: custom) == "Sách")
        #expect(categoryFolder(for: "a.txt", in: custom) == nil)
        #expect(categoryFolder(for: "a.zip", in: custom) == "Escape")
        #expect(categoryFolder(for: "a.p", in: custom) == nil)
    }

    @Test func categoryFolderOfRecordFallsBackToURLAndVideo() {
        let dir = URL(filePath: "/tmp")
        let defaults = defaultFileCategories
        let named = DownloadRecord(url: URL(string: "https://x.com/download.php?id=1")!, filename: "book.epub", directory: dir)
        let unnamed = DownloadRecord(url: URL(string: "https://x.com/a/setup.dmg")!, directory: dir)
        let unknown = DownloadRecord(url: URL(string: "https://x.com/upload_file")!, directory: dir)
        let video = DownloadRecord(url: URL(string: "https://youtube.com/watch?v=1")!, directory: dir, video: .best)
        let audio = DownloadRecord(url: URL(string: "https://youtube.com/watch?v=2")!, directory: dir, video: .audio)
        #expect(categoryFolder(of: named, in: defaults) == "Documents")
        #expect(categoryFolder(of: unnamed, in: defaults) == "Programs")
        #expect(categoryFolder(of: unknown, in: defaults) == nil)
        #expect(categoryFolder(of: video, in: defaults) == "Video")
        #expect(categoryFolder(of: audio, in: defaults) == "Music")
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
