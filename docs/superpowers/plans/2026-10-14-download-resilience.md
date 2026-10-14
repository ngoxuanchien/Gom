# Download Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Segments that keep making progress are retried indefinitely, downloads that can't fit on disk fail up front, and the Mac stays awake while anything downloads.

**Architecture:** `withRetry` in `DownloadEngine.swift` takes an optional progress reading and resets its attempt counter when progress grew; only segment fetches pass one. `prepare()` asks an injectable `freeSpace` closure before sizing the temp file and throws a new fatal `DownloadError.notEnoughSpace`. `DownloadQueue` begins a `ProcessInfo` activity when its `running` map becomes non-empty and ends it when it empties.

**Tech Stack:** Swift 6.2, Swift Testing, URLSession with `MockURLProtocol`, Foundation `ProcessInfo`.

**Spec:** `docs/superpowers/specs/2026-10-14-download-resilience-design.md`

## Global Constraints

- No new dependencies. Swift, SwiftUI and Network.framework only.
- Default attempt budget stays `maxAttempts = 6` (first attempt + 5 retries).
- Disk error text: `Not enough disk space: needs <size>, <size> free`, sizes via `ByteCountFormatter.string(fromByteCount:countStyle: .file)`.
- Activity: `ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Downloading files")`.
- Tests run from the repo root with `swift test --package-path Gom/GomCore`.
- Names, comments and docs in English.

## Review Focus

- A server that drops every connection after a fixed number of bytes → a single-connection download must still give up after 6 attempts, not loop forever (Task 1 keeps `transferSingle` on the fixed budget; test `singleConnectionDropsStillGiveUp`).
- A connection that drops before sending any byte, repeatedly → still gives up after 6 attempts (existing `persistentFailuresGiveUp` and `retriesFiveTimesAfterTheFirstAttempt` must keep passing).
- Unknown file size (no Content-Length, no ranges) on a tiny volume → no disk check, download proceeds (Task 2 test `unknownSizeSkipsDiskCheck`).
- Pausing a running download → the Mac may sleep again (Task 3 test checks pause, not only completion).
- Resuming a paused download on a now-full disk → not re-checked; the spec accepts this because the temp file already holds its full size (no test, documented in the spec).

---

### Task 1: Reset the retry budget when a segment makes progress

**Files:**
- Modify: `Gom/GomCore/Tests/GomCoreTests/MockServer.swift` (add `dropMidBody` to `MockFile.Config`, honour it in `startLoading` and `deliver`)
- Modify: `Gom/GomCore/Sources/GomCore/DownloadEngine.swift` (`withRetry`, `transferSegments`)
- Test: `Gom/GomCore/Tests/GomCoreTests/DownloadEngineTests.swift`

**Interfaces:**
- Produces: `MockFile.Config.dropMidBody: Int` (this many non-probe responses send half their body, then fail with `URLError(.networkConnectionLost)`).
- Produces: `withRetry(_:_:progress:_:)`, where `progress: () -> Int64` defaults to `{ 0 }`.

- [ ] **Step 1: Teach the mock to drop mid-body**

In `MockFile.Config`, after `failFirst`:

```swift
        var dropMidBody = 0            // this many non-probe responses send half their body, then the connection drops
```

In `MockURLProtocol.startLoading`, replace the `let (config, shouldFail) = ...` block and the delivery call so the lock also decides a drop:

```swift
        let (config, shouldFail, dropHalfway) = file.state.withLock { c -> (MockFile.Config, Bool, Bool) in
            c.requests.append(request)
            let isProbe = request.value(forHTTPHeaderField: "Range") == "bytes=0-0"
            if !isProbe && c.failFirst > 0 {
                c.failFirst -= 1
                return (c, true, false)
            }
            if !isProbe && c.dropMidBody > 0 {
                c.dropMidBody -= 1
                return (c, false, true)
            }
            return (c, false, false)
        }
```

```swift
        DispatchQueue.global().async { [self] in
            let sent = dropHalfway ? Data(body.prefix(body.count / 2)) : body
            deliver(sent, from: 0, chunkSize: config.chunkSize, delay: config.chunkDelay, thenDrop: dropHalfway)
        }
```

Change `deliver` to take `thenDrop: Bool` and pass it along in both recursive calls; at the end of the body:

```swift
        guard offset < body.count else {
            if thenDrop {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
```

- [ ] **Step 2: Write the failing tests**

Add to `DownloadEngineTests`, after `retriesFiveTimesAfterTheFirstAttempt`:

```swift
    @Test func dropsThatMakeProgressDontUseUpRetries() async throws {
        let dir = try makeTempDir()
        let data = testData(1_000_000)   // under minSegmentedSize: one segment, so every drop hits the same one
        let (url, file) = MockServer.serve(.init(data: data, dropMidBody: 8))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)
        #expect(result.state == .completed)
        #expect(try contents(result) == data)
        #expect(file.requests.count == 1 + 9)   // probe + 8 dropped + 1 that finished
    }

    @Test func singleConnectionDropsStillGiveUp() async throws {
        let dir = try makeTempDir()
        // No ranges: every attempt restarts from zero, so a drop proves nothing and keeps counting.
        let (url, file) = MockServer.serve(.init(data: testData(1_000_000), supportsRanges: false, dropMidBody: 1000))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)
        guard case .failed = result.state else {
            Issue.record("expected failed, got \(result.state)")
            return
        }
        #expect(file.requests.count == 1 + 6)
    }
```

- [ ] **Step 3: Run them to see the first fail**

Run: `swift test --package-path Gom/GomCore --filter "dropsThatMakeProgress|singleConnectionDropsStillGiveUp"`
Expected: `dropsThatMakeProgressDontUseUpRetries` FAILS (state is `.failed("…network connection was lost…")` after 6 attempts); `singleConnectionDropsStillGiveUp` PASSES (it pins current behavior).

- [ ] **Step 4: Implement**

In `DownloadEngine.swift`, replace `withRetry`:

```swift
/// Retries `body` up to `maxAttempts` times in a row. With `progress`, an attempt that moved it forward
/// before failing doesn't count: a long download over a flaky link only gives up once it stops getting anywhere.
private func withRetry<T>(_ maxAttempts: Int, _ retryDelay: (Int) -> Duration, progress: () -> Int64 = { 0 }, _ body: () async throws -> T) async throws -> T {
    var attempt = 0
    var reached = progress()
    while true {
        do {
            return try await body()
        } catch let error as DownloadError where error.isFatal {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let now = progress()
            if now > reached {
                reached = now
                attempt = 0
            }
            attempt += 1
            if attempt >= maxAttempts { throw error }
            try await Task.sleep(for: retryDelay(attempt - 1))
        }
    }
}
```

In `transferSegments`, pass the segment's progress (only here; `probe` and `transferSingle` keep the default):

```swift
                try await withRetry(maxAttempts, retryDelay, progress: { box.segment(index).done }) {
                    try await fetchSegment(index, of: base, box: box, streamer: streamer, onProgress: onProgress)
                }
```

- [ ] **Step 5: Run the whole suite**

Run: `swift test --package-path Gom/GomCore`
Expected: all PASS, including `retriesFiveTimesAfterTheFirstAttempt` and `persistentFailuresGiveUp`.

- [ ] **Step 6: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/DownloadEngine.swift Gom/GomCore/Tests/GomCoreTests/MockServer.swift Gom/GomCore/Tests/GomCoreTests/DownloadEngineTests.swift
git commit -m "Don't count segment retries that made progress"
```

---

### Task 2: Fail up front when the file can't fit

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/DownloadEngine.swift` (`DownloadError`, `runDownload`, `prepare`, `describe`, new `availableCapacity`)
- Modify: `Gom/GomCore/Tests/GomCoreTests/MockServer.swift` (add `omitContentLength`)
- Test: `Gom/GomCore/Tests/GomCoreTests/DownloadEngineTests.swift`

**Interfaces:**
- Produces: `DownloadError.notEnoughSpace(needed: Int64, available: Int64)`, fatal.
- Produces: `runDownload(..., freeSpace: @escaping @Sendable (URL) -> Int64? = availableCapacity, ...)`.
- Produces: `func availableCapacity(_ directory: URL) -> Int64?` (internal).

- [ ] **Step 1: Write the failing tests**

In `MockFile.Config` add:

```swift
        var omitContentLength = false  // send 200 responses without Content-Length, like a streamed body
```

and in `MockURLProtocol.respond`, replace the last two lines:

```swift
        if !config.omitContentLength { headers["Content-Length"] = "\(total)" }
        return (200, headers, config.data)
```

Add to `DownloadEngineTests`:

```swift
    @Test func tooLittleSpaceFailsBeforeDownloading() async throws {
        let dir = try makeTempDir()
        let (url, file) = MockServer.serve(.init(data: testData(5_000_000)))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay, freeSpace: { _ in 1_000_000 })
        guard case .failed(let message) = result.state else {
            Issue.record("expected failed, got \(result.state)")
            return
        }
        #expect(message.hasPrefix("Not enough disk space: needs "))
        #expect(file.requests.count == 1)   // the probe only
        #expect(try leftoverTempFiles(dir).isEmpty)
    }

    @Test func unknownSizeSkipsDiskCheck() async throws {
        let dir = try makeTempDir()
        let data = testData(5_000)
        // No ranges and no Content-Length: the size is only known once the body has arrived.
        let (url, _) = MockServer.serve(.init(data: data, supportsRanges: false, omitContentLength: true))
        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay, freeSpace: { _ in 0 })
        #expect(result.state == .completed)
        #expect(try contents(result) == data)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path Gom/GomCore --filter "tooLittleSpace|unknownSizeSkipsDiskCheck"`
Expected: compile error, `extra argument 'freeSpace' in call`.

- [ ] **Step 3: Implement**

Add the case and make it fatal:

```swift
public enum DownloadError: Error, Equatable {
    case httpStatus(Int)
    case fileChanged
    case incomplete
    case notEnoughSpace(needed: Int64, available: Int64)

    var isFatal: Bool {
        switch self {
        case .httpStatus(let code): code == 401 || code == 403
        case .fileChanged, .notEnoughSpace: true
        case .incomplete: false
        }
    }
}
```

Add the default reader next to `discardPartial`:

```swift
/// Free bytes on `directory`'s volume as macOS counts them for user-requested files; nil if it can't say.
func availableCapacity(_ directory: URL) -> Int64? {
    try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
}
```

Add the parameter to `runDownload` after `retryDelay`, and pass it to `prepare`:

```swift
    retryDelay: @escaping @Sendable (Int) -> Duration = defaultRetryDelay,
    freeSpace: @escaping @Sendable (URL) -> Int64? = availableCapacity,
    onProgress: @escaping @Sendable (DownloadRecord) -> Void = { _ in }
```

```swift
                try await prepare(&r, streamer: streamer, maxAttempts: maxAttempts, retryDelay: retryDelay, singleConnection: singleConnection, freeSpace: freeSpace)
```

In `prepare`, add `freeSpace: (URL) -> Int64?` as the last parameter, and check right after `createDirectory` (the volume must exist to be asked) and before creating the temp file:

```swift
    try FileManager.default.createDirectory(at: r.directory, withIntermediateDirectories: true)
    if let needed = r.totalBytes, let available = freeSpace(r.directory), needed > available {
        throw DownloadError.notEnoughSpace(needed: needed, available: available)
    }
```

In `describe`, before `default`:

```swift
    case DownloadError.notEnoughSpace(let needed, let available):
        "Not enough disk space: needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free"
```

`runDownload`'s generic `catch` already turns the thrown error into `.failed(describe(error))`; the `fileChanged` catch doesn't match this case.

- [ ] **Step 4: Run the whole suite**

Run: `swift test --package-path Gom/GomCore`
Expected: all PASS. Existing tests use the real `availableCapacity`, which reports far more than their few MB.

- [ ] **Step 5: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/DownloadEngine.swift Gom/GomCore/Tests/GomCoreTests/MockServer.swift Gom/GomCore/Tests/GomCoreTests/DownloadEngineTests.swift
git commit -m "Fail downloads that can't fit on disk before they start"
```

---

### Task 3: Keep the Mac awake while downloading, and document all three

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/DownloadQueue.swift` (`start`, `finished`, new `sleepGuard`)
- Modify: `README.md` (Downloading section)
- Test: `Gom/GomCore/Tests/GomCoreTests/DownloadQueueTests.swift`

**Interfaces:**
- Consumes: `DownloadQueue.pause(_ id: UUID)`, `DownloadQueue.activeCount` (existing).
- Produces: `DownloadQueue.keepsMacAwake: Bool` (internal, read by tests).

- [ ] **Step 1: Write the failing test**

Add to `DownloadQueueTests`:

```swift
    @Test func keepsMacAwakeOnlyWhileDownloading() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        #expect(!queue.keepsMacAwake)

        let (slowURL, _) = MockServer.serve(.init(data: testData(3_000_000), chunkDelay: 0.05))
        let slow = queue.add(url: slowURL, directory: dir)
        #expect(queue.keepsMacAwake)
        queue.pause(slow)
        try await waitUntil { queue.activeCount == 0 }
        #expect(!queue.keepsMacAwake)

        let (fastURL, _) = MockServer.serve(.init(data: testData(100_000)))
        let fast = queue.add(url: fastURL, directory: dir)
        #expect(queue.keepsMacAwake)
        try await waitUntil { queue.items.first { $0.id == fast }?.state == .completed }
        try await waitUntil { queue.activeCount == 0 }
        #expect(!queue.keepsMacAwake)
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --package-path Gom/GomCore --filter keepsMacAwakeOnlyWhileDownloading`
Expected: compile error, `value of type 'DownloadQueue' has no member 'keepsMacAwake'`.

- [ ] **Step 3: Implement**

In `DownloadQueue`, next to the other `@ObservationIgnored` state:

```swift
    /// Held while any download runs, so the Mac doesn't idle-sleep mid-download; the display may still sleep.
    @ObservationIgnored private var sleepGuard: (any NSObjectProtocol)?

    var keepsMacAwake: Bool { sleepGuard != nil }

    private func updateSleepGuard() {
        if running.isEmpty, let activity = sleepGuard {
            ProcessInfo.processInfo.endActivity(activity)
            sleepGuard = nil
        } else if !running.isEmpty, sleepGuard == nil {
            sleepGuard = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Downloading files")
        }
    }
```

`running` changes in exactly two places. In `start(_:)`, after the `running[id] = Task { ... }` assignment:

```swift
        updateSleepGuard()
```

In `finished(_:_:)`, right after `running[id] = nil`:

```swift
        updateSleepGuard()
```

Verify there is no other writer: `grep -n "running\[.*\] = \|running.remove" Gom/GomCore/Sources/GomCore/DownloadQueue.swift` should list only those two lines.

- [ ] **Step 4: Run the whole suite**

Run: `swift test --package-path Gom/GomCore`
Expected: all PASS.

- [ ] **Step 5: Document**

In `README.md`, under `### Downloading`, after the "Multi-connection HTTP downloads" bullet:

```markdown
- Long downloads over flaky connections keep going: a connection that drops after making progress is retried without using up its retries. A download that can't fit on the disk fails before it starts, saying how much space it needs.
- Keeps the Mac from idle-sleeping while anything downloads (the display can still sleep).
```

- [ ] **Step 6: Build the app**

Run: `cd Gom && xcodegen generate && xcodebuild -project Gom.xcodeproj -scheme Gom -configuration Debug build | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/DownloadQueue.swift Gom/GomCore/Tests/GomCoreTests/DownloadQueueTests.swift README.md
git commit -m "Keep the Mac awake while downloading"
```

---

### Task 4: Manual verification

- [ ] In the scratchpad, create a 500 MB file and serve it with ranges: `mkfile 500m big.bin && python3 -m http.server 8765`.
- [ ] Launch the built app, add `http://127.0.0.1:8765/big.bin`. While it runs, `pmset -g assertions | grep -i "Downloading files"` shows a `PreventUserIdleSystemSleep` assertion. Pause it: the assertion is gone.
- [ ] Create a 100 MB disk image (`hdiutil create -size 100m -fs APFS -volname GomTiny tiny.dmg && hdiutil attach tiny.dmg`), add the same URL with `/Volumes/GomTiny` as the folder: the row fails at once with "Not enough disk space: needs 524.3 MB, … free". Detach the image afterwards.
- [ ] Stop the Python server mid-download, start it again after 10 s, repeat 7 times: the download is still running (retrying), not failed, and finishes once the server stays up.
