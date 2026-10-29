# Dynamic Segments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a connection finishes its segment, it takes over the second half of the largest range still left, so a download no longer waits on one slow connection while the others sit idle.

**Architecture:** A pure `splitLargest(_:)` in `Segment.swift` cuts the unfinished segment with the most bytes left and appends the second half. `ProgressBox.add` clamps progress at a segment's (possibly shrunk) end and, in the same critical section that completes a segment, calls `splitLargest` and hands the new index back. Each task in `transferSegments` becomes a connection loop that keeps fetching the segment it was handed; `fetchSegment` rereads its segment's end per chunk and stops a running request at it.

**Tech Stack:** Swift 6.2, Swift Testing, `Synchronization.Mutex`, URLSession with `MockURLProtocol`.

**Spec:** `docs/superpowers/specs/2026-10-14-dynamic-segments-design.md`

## Global Constraints

- Base: `main` **after** the `download-resilience` branch has merged. `withRetry` must already have the `progress:` parameter. If it doesn't, stop and ask.
- `minSplitRemainder = 1 MiB` (`1024 * 1024`): split only a segment with at least that much left; split point `nextOffset + remaining / 2`; ties go to the lowest index.
- `Segment`, `DownloadRecord`, `DownloadQueue`: no changes. The persisted format must not change.
- A download never runs more connection tasks than it had unfinished segments when `transferSegments` started.
- No new dependencies.
- Tests run from the repo root with `swift test --package-path Gom/GomCore`.
- Names, comments and docs in English. Commit messages carry no AI attribution lines.

## Review Focus

- A split lands while the victim's chunk is in flight, so bytes past the new end get written → progress must clamp at the new end and the file must still be byte-identical (Task 2: `addClampsAtAShrunkEnd…` unit test plus the engine test's byte comparison).
- The queue sees a snapshot between "segment done" and "split made" and starts another download on the same server → it must never happen; the unfinished count must stay the same through a split (Task 2: `completingASegmentSplits…` asserts the count).
- Pause right after a split, persist, relaunch → resume must fetch only what is left and finish identical (Task 3: `resumeAfterSplitFetchesOnlyWhatIsLeft`).
- Speed limit set while splits happen → the new half must go through paced pieces and never ask for more than one piece (Task 3: `splitSegmentsArePacedToo`).
- Files under 8 MiB → no split, the same 9 requests as today (existing `segmentedDownloadProducesIdenticalFile` asserts `1 + 8` requests for 5 MB; it must keep passing unchanged).

---

### Task 1: `splitLargest`

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/Segment.swift` (after `isComplete`, and at the end of the file)
- Modify: `Gom/GomCore/Tests/GomCoreTests/TestSupport.swift` (add `coversContiguously`)
- Test: `Gom/GomCore/Tests/GomCoreTests/SegmentTests.swift`

**Interfaces:**
- Produces: `public let minSplitRemainder: Int64`; `Segment.remaining: Int64` (internal, `end - nextOffset + 1`); `func splitLargest(_ segments: inout [Segment]) -> Int?` (internal; returns the appended segment's index or nil); test helper `func coversContiguously(_ segments: [Segment], total: Int64) -> Bool`.

- [ ] **Step 1: Add the test helper**

In `TestSupport.swift`, add `import GomCore` under the existing imports, then append:

```swift
/// True if `segments`, ordered by start, sit back to back and cover `[0, total)`.
func coversContiguously(_ segments: [Segment], total: Int64) -> Bool {
    let sorted = segments.sorted { $0.start < $1.start }
    return sorted.first?.start == 0 && sorted.last?.end == total - 1
        && zip(sorted, sorted.dropFirst()).allSatisfy { $1.start == $0.end + 1 }
}
```

- [ ] **Step 2: Write the failing tests**

Append inside `SegmentTests` in `SegmentTests.swift`:

```swift
    let mib: Int64 = 1024 * 1024

    @Test func splitTakesTheSecondHalfOfTheLargestRemainder() {
        var segments = [
            Segment(start: 0, end: 4 * mib - 1, done: 4 * mib),         // complete
            Segment(start: 4 * mib, end: 8 * mib - 1, done: mib),      // 3 MiB left
            Segment(start: 8 * mib, end: 12 * mib - 1, done: 2 * mib), // 2 MiB left
        ]
        let new = splitLargest(&segments)

        #expect(new == 3)
        let mid = 5 * mib + 3 * mib / 2
        #expect(segments[1] == Segment(start: 4 * mib, end: mid - 1, done: mib))
        #expect(segments[3] == Segment(start: mid, end: 8 * mib - 1))
        #expect(coversContiguously(segments, total: 12 * mib))
    }

    @Test func splitBreaksTiesByLowestIndex() {
        var segments = [Segment(start: 0, end: 2 * mib - 1), Segment(start: 2 * mib, end: 4 * mib - 1)]
        #expect(splitLargest(&segments) == 2)
        #expect(segments[0].end == mib - 1)
        #expect(segments[1].end == 4 * mib - 1)
    }

    @Test func splitNeedsOneMebibyteLeft() {
        var small = [Segment(start: 0, end: minSplitRemainder - 2)]   // 1 MiB - 1 byte left
        #expect(splitLargest(&small) == nil)
        #expect(small.count == 1)

        var exact = [Segment(start: 0, end: minSplitRemainder - 1)]
        #expect(splitLargest(&exact) == 1)
        #expect(exact[0].remaining == minSplitRemainder / 2)
        #expect(exact[1].remaining == minSplitRemainder / 2)
    }

    @Test func completedSegmentsAreNeverSplit() {
        var segments = [Segment(start: 0, end: 4 * mib - 1, done: 4 * mib)]
        #expect(splitLargest(&segments) == nil)
    }
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path Gom/GomCore --filter SegmentTests`
Expected: compile error, `cannot find 'splitLargest' in scope`.

- [ ] **Step 4: Implement**

In `Segment.swift`, inside `struct Segment` after `isComplete`:

```swift
    var remaining: Int64 { end - nextOffset + 1 }
```

At the end of the file:

```swift
/// A segment is split only when at least this much of it is left, so each half gets 512 KiB or more.
public let minSplitRemainder: Int64 = 1024 * 1024

/// Cuts the unfinished segment with the most bytes left in two and appends the second half.
/// Returns the new segment's index, or nil if no segment has `minSplitRemainder` left.
/// Existing indexes don't change, so a connection working on the shrunk segment keeps its index.
func splitLargest(_ segments: inout [Segment]) -> Int? {
    // max(by:) keeps the first of equal elements: ties go to the lowest index.
    guard let victim = segments.indices.max(by: { segments[$0].remaining < segments[$1].remaining }),
          segments[victim].remaining >= minSplitRemainder else { return nil }
    let mid = segments[victim].nextOffset + segments[victim].remaining / 2
    segments.append(Segment(start: mid, end: segments[victim].end))
    segments[victim].end = mid - 1
    return segments.count - 1
}
```

- [ ] **Step 5: Run them to see them pass**

Run: `swift test --package-path Gom/GomCore --filter SegmentTests`
Expected: all `SegmentTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/Segment.swift Gom/GomCore/Tests/GomCoreTests/SegmentTests.swift Gom/GomCore/Tests/GomCoreTests/TestSupport.swift
git commit -m "Add splitLargest for dynamic segments"
```

---

### Task 2: Connections take over half of the largest range left

**Files:**
- Modify: `Gom/GomCore/Tests/GomCoreTests/MockServer.swift` (`MockFile.Config.delayOnlyAt`, used in `startLoading`)
- Modify: `Gom/GomCore/Sources/GomCore/DownloadEngine.swift` (`ProgressBox`, `transferSegments`, `fetchSegment`)
- Test: `Gom/GomCore/Tests/GomCoreTests/DownloadEngineTests.swift`

**Interfaces:**
- Consumes: `splitLargest(_:)`, `Segment.remaining`, `minSplitRemainder`, `coversContiguously(_:total:)` from Task 1.
- Produces: `ProgressBox.add(_ count: Int64, to index: Int) -> Int?` (clamps; returns a split index when this add completed the segment and a split was possible); `ProgressBox.end(of index: Int) -> Int64`; `MockFile.Config.delayOnlyAt: Int?` (if set, `chunkDelay` applies only to range requests starting at that byte offset).

- [ ] **Step 1: Add `delayOnlyAt` to the mock**

In `MockServer.swift`, add to `MockFile.Config` after `chunkDelay`:

```swift
        var delayOnlyAt: Int? = nil    // if set, chunkDelay applies only to the range request starting at this offset
```

In `MockURLProtocol.startLoading`, replace

```swift
        DispatchQueue.global().async { [self] in
            deliver(body, from: 0, chunkSize: config.chunkSize, delay: config.chunkDelay)
        }
```

with

```swift
        let rangeStart = request.value(forHTTPHeaderField: "Range").flatMap { Self.parseRange($0, total: config.data.count)?.0 }
        let delay = config.delayOnlyAt.map { $0 == rangeStart ? config.chunkDelay : 0 } ?? config.chunkDelay
        DispatchQueue.global().async { [self] in
            deliver(body, from: 0, chunkSize: config.chunkSize, delay: delay)
        }
```

- [ ] **Step 2: Write the failing tests**

In `DownloadEngineTests.swift`, append inside the suite:

```swift
    @Test func completingASegmentSplitsTheLargestRemainderAtOnce() {
        let mib: Int64 = 1024 * 1024
        let box = ProgressBox([Segment(start: 0, end: mib - 1), Segment(start: mib, end: 5 * mib - 1)])
        #expect(box.add(mib / 2, to: 0) == nil)
        let unfinished = { box.snapshot.filter { !$0.isComplete }.count }
        #expect(unfinished() == 2)

        #expect(box.add(mib, to: 0) == 2)   // completes segment 0 and splits segment 1 in one step
        #expect(box.segment(0).done == mib) // clamped at the end
        #expect(unfinished() == 2)          // one finished, one new: the queue never sees a free connection
        #expect(box.segment(1).end == 3 * mib - 1)
        #expect(box.segment(2) == Segment(start: 3 * mib, end: 5 * mib - 1))
        #expect(box.end(of: 1) == 3 * mib - 1)
    }

    @Test func addClampsAtAShrunkEndAndDoesNotSplitSmallRemainders() {
        let box = ProgressBox([Segment(start: 0, end: 99), Segment(start: 100, end: 199)])
        #expect(box.add(150, to: 0) == nil)   // segment 1 has 100 bytes left: too small to split
        #expect(box.segment(0).done == 100)
        #expect(box.snapshot.filter { !$0.isComplete }.count == 1)
        #expect(box.add(10, to: 0) == nil)    // already complete: no second split
        #expect(box.snapshot.count == 2)
    }

    @Test func idleConnectionTakesOverHalfOfASlowSegment() async throws {
        let dir = try makeTempDir()
        let data = testData(16 * 1024 * 1024)   // 2 MiB segments, large enough to split
        let slowStart = 7 * data.count / 8
        let (url, file) = MockServer.serve(.init(data: data, chunkDelay: 0.05, delayOnlyAt: slowStart))

        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: MockServer.streamer(), retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(try contents(result) == data)
        #expect(result.segments.count > 8)
        #expect(result.segments.allSatisfy(\.isComplete))
        #expect(coversContiguously(result.segments, total: Int64(data.count)))
        let starts = file.requests.compactMap { $0.value(forHTTPHeaderField: "Range") }
            .compactMap { MockURLProtocol.parseRange($0, total: data.count)?.0 }
        #expect(starts.contains { $0 > slowStart })   // another connection fetched part of the slow segment
        #expect(try leftoverTempFiles(dir).isEmpty)
    }
```

- [ ] **Step 3: Run them to see them fail**

Run: `swift test --package-path Gom/GomCore --filter "completingASegmentSplits|addClampsAtAShrunkEnd|idleConnectionTakesOver"`
Expected: compile error. `add` returns `Void` today, so `== nil` doesn't type-check, and `end(of:)` doesn't exist.

- [ ] **Step 4: Implement `ProgressBox`**

In `DownloadEngine.swift`, replace

```swift
    func add(_ count: Int64, to index: Int) { segments.withLock { $0[index].done += count } }
```

with

```swift
    func end(of index: Int) -> Int64 { segments.withLock { $0[index].end } }

    /// Adds `count` written bytes to segment `index`, never past its end: a split may have moved the end
    /// below bytes already in flight (they are the same bytes the new segment fetches, so writing them is harmless).
    /// If this completes the segment, the largest remainder is split in the same critical section, so a snapshot
    /// never shows a freed connection that is about to be taken again. Returns the new segment's index to fetch next.
    func add(_ count: Int64, to index: Int) -> Int? {
        segments.withLock { segments in
            let wasComplete = segments[index].isComplete
            segments[index].done = min(segments[index].done + count, segments[index].end - segments[index].start + 1)
            guard !wasComplete, segments[index].isComplete else { return nil }
            return splitLargest(&segments)
        }
    }
```

- [ ] **Step 5: Turn each task into a connection loop**

In `transferSegments`, replace the `group.addTask { … }` body (the resilience version shown here):

```swift
            group.addTask {
                try await withRetry(maxAttempts, retryDelay, progress: { box.segment(index).done }) {
                    try await fetchSegment(index, of: base, box: box, streamer: streamer, onProgress: onProgress)
                }
            }
```

with

```swift
            // One task per connection: when its segment completes, it fetches the split it was handed.
            group.addTask {
                var current: Int? = index
                while let segment = current {
                    current = try await withRetry(maxAttempts, retryDelay, progress: { box.segment(segment).done }) {
                        try await fetchSegment(segment, of: base, box: box, streamer: streamer, onProgress: onProgress)
                    }
                }
            }
```

- [ ] **Step 6: Make `fetchSegment` follow the live end and return the claimed split**

Replace the whole `fetchSegment` function with:

```swift
/// Fetches what is left of segment `index`. Returns the segment split off for this connection
/// when it finished, or nil when there was nothing left to split.
private func fetchSegment(
    _ index: Int,
    of base: DownloadRecord,
    box: ProgressBox,
    streamer: HTTPStreamer,
    onProgress: @Sendable (DownloadRecord) -> Void
) async throws -> Int? {
    let segment = box.segment(index)
    guard !segment.isComplete, let temp = base.tempURL else { return nil }
    let handle = try FileHandle(forWritingTo: temp)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(segment.nextOffset))
    var offset = segment.nextOffset
    let limiter = streamer.limiter

    // Under a speed limit the range is fetched in pieces, each request sent only once the shared
    // bucket has room for it, so the network never runs ahead of the cap. Unlimited: one request.
    // The end is reread throughout: another connection may take over the second half of this segment.
    while offset <= box.end(of: index) {
        let rate = limiter.bytesPerSecond
        let end = box.end(of: index)
        let last = rate > 0 ? min(end, offset + Int64(pieceSize(for: rate)) - 1) : end
        if rate > 0 { try await limiter.acquire(Int(last - offset + 1)) }
        var request = makeRequest(base)
        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
        if let etag = base.etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }

        var limitArrived = false
        response: for try await event in streamer.stream(request) {
            switch event {
            case .response(let response):
                // 200 to a range request: the file changed (If-Range failed) or ranges stopped working.
                if response.statusCode == 200 { throw DownloadError.fileChanged }
                guard response.statusCode == 206 else { throw DownloadError.httpStatus(response.statusCode) }
            case .data(let data):
                let chunk = data.prefix(max(0, Int(min(last, box.end(of: index)) + 1 - offset)))
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
                let next = box.add(Int64(chunk.count), to: index)
                if box.shouldReport() {
                    var snapshot = base
                    snapshot.segments = box.snapshot
                    onProgress(snapshot)
                }
                // Leaving the loop ends the stream, which cancels the request.
                if let next { return next }
                if offset > box.end(of: index) { break response }   // the rest of this range was split off
                // A limit set during an unlimited request: carry on in paced pieces from here.
                if rate == 0, limiter.bytesPerSecond > 0 {
                    limitArrived = true
                    break response
                }
            }
        }
        try Task.checkCancellation()
        if offset <= min(last, box.end(of: index)) && !limitArrived { throw DownloadError.incomplete }
    }
    return nil
}
```

- [ ] **Step 7: Run the new tests to see them pass**

Run: `swift test --package-path Gom/GomCore --filter "completingASegmentSplits|addClampsAtAShrunkEnd|idleConnectionTakesOver"`
Expected: 3 tests pass.

- [ ] **Step 8: Run the whole suite**

Run: `swift test --package-path Gom/GomCore`
Expected: everything passes, including `segmentedDownloadProducesIdenticalFile` (still `1 + 8` requests: a 5 MB file never splits) and `pauseThenResumeContinuesWhereItStopped`.

- [ ] **Step 9: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/DownloadEngine.swift Gom/GomCore/Tests/GomCoreTests/MockServer.swift Gom/GomCore/Tests/GomCoreTests/DownloadEngineTests.swift
git commit -m "Let a connection that finishes early take over half of the largest range left"
```

---

### Task 3: Speed limit and resume after a split, README

These tests pin behaviour Task 2 should already have; they are expected to pass on the first run. If one fails, the bug is in Task 2's code: fix it there, not in the test.

**Files:**
- Test: `Gom/GomCore/Tests/GomCoreTests/BandwidthLimitTests.swift`
- Test: `Gom/GomCore/Tests/GomCoreTests/DownloadEngineTests.swift` (add `import Synchronization`)
- Modify: `README.md:14`

**Interfaces:**
- Consumes: `MockFile.Config.delayOnlyAt` (Task 2), `requestedLengths(_:)` (existing in `BandwidthLimitTests`), `pieceSize(for:)` (existing), `coversContiguously` (Task 1).

- [ ] **Step 1: Speed-limit test**

Append inside `BandwidthLimitTests`:

```swift
    @Test func splitSegmentsArePacedToo() async throws {
        let dir = try makeTempDir()
        let data = testData(16 * 1024 * 1024)
        // The slow segment's first request runs at ~320 KB/s; the others finish in ~2 s at the cap, then split it.
        let (url, file) = MockServer.serve(.init(data: data, chunkDelay: 0.2, delayOnlyAt: 7 * data.count / 8))
        let streamer = MockServer.streamer()
        streamer.bytesPerSecond = 8_000_000

        let result = await runDownload(DownloadRecord(url: url, directory: dir), streamer: streamer, retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(try Data(contentsOf: #require(result.fileURL)) == data)
        #expect(result.segments.count > 8)
        #expect(requestedLengths(file).allSatisfy { $0 <= pieceSize(for: 8_000_000) })
    }
```

- [ ] **Step 2: Resume-after-split test**

Add `import Synchronization` to the imports of `DownloadEngineTests.swift`, then append inside the suite:

```swift
    @Test func resumeAfterSplitFetchesOnlyWhatIsLeft() async throws {
        let dir = try makeTempDir()
        let data = testData(16 * 1024 * 1024)
        let (url, file) = MockServer.serve(.init(data: data, chunkDelay: 0.05, delayOnlyAt: 7 * data.count / 8))
        let streamer = MockServer.streamer()
        let noDelay = noDelay
        let split = Mutex(false)
        let task = Task {
            await runDownload(DownloadRecord(url: url, directory: dir), streamer: streamer, retryDelay: noDelay) { progress in
                if progress.segments.count > 8 { split.withLock { $0 = true } }
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !split.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        // As the queue would: through downloads.json and back.
        let paused = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(await task.value))

        #expect(paused.state == .paused)
        #expect(paused.segments.count > 8)
        let unfinished = paused.segments.filter { !$0.isComplete }
        #expect(!unfinished.isEmpty)

        file.state.withLock { $0.chunkDelay = 0 }
        let before = file.requests.count
        let result = await runDownload(paused, streamer: streamer, retryDelay: noDelay)

        #expect(result.state == .completed)
        #expect(try contents(result) == data)
        #expect(coversContiguously(result.segments, total: Int64(data.count)))
        let resumed = file.requests[before...].compactMap { $0.value(forHTTPHeaderField: "Range") }
            .compactMap { MockURLProtocol.parseRange($0, total: data.count) }
        let ranges = Set(resumed.map { "\($0.0)-\($0.1)" })
        for segment in unfinished { #expect(ranges.contains("\(segment.nextOffset)-\(segment.end)")) }
        let written = paused.segments.map { $0.start..<$0.nextOffset }
        #expect(resumed.allSatisfy { range in !written.contains { $0.contains(Int64(range.0)) } })
    }
```

- [ ] **Step 3: Run both**

Run: `swift test --package-path Gom/GomCore --filter "splitSegmentsArePacedToo|resumeAfterSplitFetchesOnlyWhatIsLeft"`
Expected: 2 tests pass (the speed-limit one takes about 4–6 s).

- [ ] **Step 4: README**

In `README.md`, replace

```
- Multi-connection HTTP downloads (8 segments) with pause/resume and automatic retry.
```

with

```
- Multi-connection HTTP downloads (8 connections; one that finishes early takes over half of the largest range left) with pause/resume and automatic retry.
```

- [ ] **Step 5: Whole suite**

Run: `swift test --package-path Gom/GomCore`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Gom/GomCore/Tests/GomCoreTests/BandwidthLimitTests.swift Gom/GomCore/Tests/GomCoreTests/DownloadEngineTests.swift README.md
git commit -m "Test split segments under a speed limit and across resume"
```

---

### Task 4: Manual check against a real server

No code. This step finds what `MockURLProtocol` can't show: socket behaviour when a request is cancelled mid-body.

- [ ] **Step 1:** Serve a 300 MB file from a local Range-capable server that throttles one range. For example, a small Python `http.server` subclass that sleeps between writes when the `Range` start equals `7 * size // 8`.
- [ ] **Step 2:** Quit the installed Gom and run the debug build (drive it with cua-driver, not osascript keystrokes). Add the URL and watch the row: after the fast segments finish, the speed should stay well above one connection's.
- [ ] **Step 3:** Pause after the speed holds up, check `downloads.json` shows more than 8 segments, resume, and compare `shasum -a 256` of the result with the source.
- [ ] **Step 4:** Record the measurements in the spec's §6 "Manual" line and set the spec status to `implemented`; commit only those two files.
