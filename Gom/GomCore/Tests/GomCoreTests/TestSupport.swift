import Foundation
import Testing

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "gom-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Deterministic bytes; a different `seed` gives different content of the same length.
func testData(_ count: Int, seed: UInt8 = 0) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 9)) &+ seed })
}

/// Polls `condition` every 20ms; records a test failure on timeout.
@MainActor
func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("waitUntil timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
