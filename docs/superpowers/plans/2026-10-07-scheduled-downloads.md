# Scheduled Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let downloads be marked "scheduled" so they only run inside a daily time window, pause when it closes, and optionally quit Gom or sleep the Mac when they are all done.

**Architecture:** A pure `ScheduleWindow` value in GomCore answers "is this time inside the window". `DownloadQueue` gains a `scheduled` gate in `schedule()`, an idempotent `refreshSchedule(now:)` that the app calls every 30 s and on wake, and an `onScheduleFinished` callback. The app stores the window and end action in `UserDefaults`, and shows the countdown alert and runs `pmset sleepnow`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-07-scheduled-downloads-design.md`

## Global Constraints

- macOS 27, Swift 6 strict concurrency; no new dependencies.
- `DownloadRecord.scheduled` is `Bool?`: `true` = scheduled, `nil` = not; never write `false`.
- Window settings: `UserDefaults` keys `scheduleStart`, `scheduleEnd` (minutes since midnight, defaults 60 and 360) and `scheduleAction` (`"none" | "quit" | "sleep"`, default `"none"`); add-bar toggle `scheduleNew` (default `false`).
- Start minute included, end minute excluded; `start > end` crosses midnight; `start == end` = open all day.
- Countdown is 60 seconds; sleep is `/usr/bin/pmset sleepnow`; quit is `NSApp.terminate(nil)`.
- Core tests: `swift test --package-path Gom/GomCore` from the worktree root. App build (from `Gom/`): `xcodegen generate && xcodebuild -project Gom.xcodeproj -scheme Gom -configuration Debug -derivedDataPath build build 2>&1 | tail -5`.
- Docs in English. Commits have no Claude attribution lines. Stage files by name, never `git add -A`.

## Review Focus

1. A "Start Now" / "Start in Schedule" toggle made while the download is running must stick. The engine writes back a copy taken at start, so progress and results must keep the live `scheduled` value. Test in Task 2.
2. Quitting Gom mid-run must not trigger the end action. `shutdown()` cancels downloads, which looks like "all finished". Test in Task 3.
3. When the window closes, a requeued download must not post a "Download complete/failed" notification (`onFinished`). Test in Task 2.
4. After a relaunch, persisted scheduled downloads must not start before the app has set the window. Test in Task 2.
5. A scheduled download the user paused by hand must not keep the Mac awake forever. Test in Task 3.

---

### Task 1: `ScheduleWindow`

**Files:**
- Create: `Gom/GomCore/Sources/GomCore/Schedule.swift`
- Test: `Gom/GomCore/Tests/GomCoreTests/ScheduleTests.swift`

**Interfaces:**
- Produces: `public struct ScheduleWindow: Equatable, Sendable { public var start: Int; public var end: Int; public init(start: Int, end: Int); public func contains(_ date: Date, calendar: Calendar = .current) -> Bool }`

- [ ] **Step 1: Write the failing test**

`Gom/GomCore/Tests/GomCoreTests/ScheduleTests.swift`:

```swift
import Foundation
import Testing
@testable import GomCore

@Suite struct ScheduleWindowTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour, minute: minute))!
    }

    func open(_ window: ScheduleWindow, _ hour: Int, _ minute: Int) -> Bool {
        window.contains(at(hour, minute), calendar: calendar)
    }

    @Test func sameDayWindowIncludesStartExcludesEnd() {
        let window = ScheduleWindow(start: 60, end: 360)   // 01:00–06:00
        #expect(open(window, 1, 0))
        #expect(open(window, 5, 59))
        #expect(!open(window, 6, 0))
        #expect(!open(window, 0, 59))
        #expect(!open(window, 12, 0))
    }

    @Test func windowCrossingMidnight() {
        let window = ScheduleWindow(start: 22 * 60, end: 6 * 60)   // 22:00–06:00
        #expect(open(window, 22, 0))
        #expect(open(window, 23, 0))
        #expect(open(window, 0, 0))
        #expect(open(window, 3, 0))
        #expect(!open(window, 6, 0))
        #expect(!open(window, 12, 0))
        #expect(!open(window, 21, 59))
    }

    @Test func equalStartAndEndIsOpenAllDay() {
        let window = ScheduleWindow(start: 120, end: 120)
        #expect(open(window, 0, 0))
        #expect(open(window, 2, 0))
        #expect(open(window, 23, 59))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Gom/GomCore --filter ScheduleWindowTests`
Expected: FAIL to compile with "cannot find 'ScheduleWindow' in scope".

- [ ] **Step 3: Write minimal implementation**

`Gom/GomCore/Sources/GomCore/Schedule.swift`:

```swift
import Foundation

/// The daily time window scheduled downloads run in, in minutes since local midnight.
public struct ScheduleWindow: Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Start minute included, end excluded. `start > end` crosses midnight; `start == end` is open all day.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (time.hour ?? 0) * 60 + (time.minute ?? 0)
        if start == end { return true }
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Gom/GomCore --filter ScheduleWindowTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/Schedule.swift Gom/GomCore/Tests/GomCoreTests/ScheduleTests.swift
git commit -m "Add ScheduleWindow for scheduled downloads"
```

---

### Task 2: Scheduled flag and window gating in `DownloadQueue`

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/DownloadRecord.swift` (add property after `video`)
- Modify: `Gom/GomCore/Sources/GomCore/DownloadQueue.swift` (`add`, `schedule`, `start`, `progress`, `finished`; new `scheduleWindow`, `refreshSchedule`, `setScheduled`, `requeue`)
- Test: `Gom/GomCore/Tests/GomCoreTests/ScheduleTests.swift` (append a suite)

**Interfaces:**
- Consumes: `ScheduleWindow` from Task 1.
- Produces:
  - `DownloadRecord.scheduled: Bool?`
  - `DownloadQueue.scheduleWindow: ScheduleWindow?` (nil = scheduled downloads never start)
  - `DownloadQueue.refreshSchedule(now: Date = .now)`
  - `DownloadQueue.setScheduled(_ id: UUID, _ scheduled: Bool)`
  - `DownloadQueue.add(url:headers:filename:directory:categories:video:scheduled:)`, where `scheduled: Bool = false` is the last parameter
  - private `scheduledRunPending: Bool`, set in `start` (Task 3 reads it)

- [ ] **Step 1: Write the failing tests**

Append to `Gom/GomCore/Tests/GomCoreTests/ScheduleTests.swift`:

```swift
@MainActor
@Suite struct ScheduledQueueTests {
    let window = ScheduleWindow(start: 10 * 60, end: 14 * 60)
    // Midday times, so a DST change can't shift them.
    let inside = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
    let outside = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: .now)!

    func makeQueue(_ dir: URL) -> DownloadQueue {
        let queue = DownloadQueue(store: DownloadStore(fileURL: dir.appending(path: "downloads.json")), streamer: MockServer.streamer(), retryDelay: { _ in .zero })
        queue.scheduleWindow = window
        return queue
    }

    func record(_ queue: DownloadQueue, _ id: UUID) -> DownloadRecord? {
        queue.items.first { $0.id == id }
    }

    @Test func scheduledWaitsForWindowUnscheduledStartsNow() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        queue.refreshSchedule(now: outside)
        let (slow, _) = MockServer.serve(.init(data: testData(3_000_000), chunkDelay: 0.05), path: "/a.bin")
        let (fast, _) = MockServer.serve(.init(data: testData(100_000)), path: "/b.bin")

        let scheduled = queue.add(url: slow, directory: dir, scheduled: true)
        let now = queue.add(url: fast, directory: dir)
        try await waitUntil { record(queue, now)?.state == .completed }
        #expect(record(queue, scheduled)?.state == .queued)
        #expect(record(queue, scheduled)?.scheduled == true)
        #expect(record(queue, now)?.scheduled == nil)

        queue.refreshSchedule(now: inside)
        #expect(record(queue, scheduled)?.state == .downloading)
        queue.pauseAll()
    }

    @Test func closingWindowRequeuesScheduledOnlyAndReopeningFinishes() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        var finished: [DownloadRecord] = []
        queue.onFinished = { finished.append($0) }
        queue.refreshSchedule(now: inside)
        let data = testData(5_000_000)
        let (slow, file) = MockServer.serve(.init(data: data, chunkDelay: 0.1), path: "/a.bin")
        let (other, _) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.5), path: "/b.bin")
        let scheduled = queue.add(url: slow, directory: dir, scheduled: true)
        let unscheduled = queue.add(url: other, directory: dir)
        try await waitUntil { (record(queue, scheduled)?.downloadedBytes ?? 0) > 0 }

        queue.refreshSchedule(now: outside)
        try await waitUntil { record(queue, scheduled)?.state == .queued && queue.activeCount == 1 }
        #expect((record(queue, scheduled)?.downloadedBytes ?? 0) > 0)
        #expect(record(queue, unscheduled)?.state == .downloading)
        #expect(finished.isEmpty)

        file.state.withLock { $0.chunkDelay = 0 }
        queue.refreshSchedule(now: inside)
        try await waitUntil { record(queue, scheduled)?.state == .completed }
        #expect(try Data(contentsOf: #require(record(queue, scheduled)?.fileURL)) == data)
        queue.pauseAll()
    }

    @Test func startNowRunsOutsideWindow() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        queue.refreshSchedule(now: outside)
        let (url, _) = MockServer.serve(.init(data: testData(100_000)))
        let id = queue.add(url: url, directory: dir, scheduled: true)
        #expect(record(queue, id)?.state == .queued)

        queue.setScheduled(id, false)
        try await waitUntil { record(queue, id)?.state == .completed }
        #expect(record(queue, id)?.scheduled == nil)
    }

    @Test func toggleWhileRunningIsNotOverwrittenByProgress() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        queue.refreshSchedule(now: inside)
        let (url, file) = MockServer.serve(.init(data: testData(3_000_000), chunkDelay: 0.05))
        let id = queue.add(url: url, directory: dir, scheduled: true)
        try await waitUntil { (record(queue, id)?.downloadedBytes ?? 0) > 0 }

        queue.setScheduled(id, false)
        file.state.withLock { $0.chunkDelay = 0 }
        try await waitUntil { record(queue, id)?.state == .completed }
        #expect(record(queue, id)?.scheduled == nil)
    }

    @Test func schedulingRunningDownloadOutsideWindowRequeuesIt() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        queue.refreshSchedule(now: outside)
        let (url, _) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.1))
        let id = queue.add(url: url, directory: dir)
        try await waitUntil { (record(queue, id)?.downloadedBytes ?? 0) > 0 }

        queue.setScheduled(id, true)
        try await waitUntil { record(queue, id)?.state == .queued && queue.activeCount == 0 }
        #expect(record(queue, id)?.scheduled == true)
    }

    @Test func flagSurvivesRelaunchAndWaitsForWindow() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        queue.refreshSchedule(now: outside)
        let (url, _) = MockServer.serve(.init(data: testData(100_000)))
        queue.add(url: url, directory: dir, scheduled: true)

        // No window set yet, as at app launch before AppDelegate applies the settings.
        let relaunched = DownloadQueue(store: DownloadStore(fileURL: dir.appending(path: "downloads.json")), streamer: MockServer.streamer())
        #expect(relaunched.items.first?.scheduled == true)
        #expect(relaunched.items.first?.state == .queued)
        #expect(relaunched.activeCount == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Gom/GomCore --filter ScheduledQueueTests`
Expected: FAIL to compile: "value of type 'DownloadQueue' has no member 'scheduleWindow'" and "extra argument 'scheduled'".

- [ ] **Step 3: Add the record property**

In `DownloadRecord.swift`, after `public var video: VideoQuality?`:

```swift
    /// True when the download only runs inside the schedule window; nil otherwise (never false).
    public var scheduled: Bool?
```

`init` needs no change (an optional stored property starts as nil).

- [ ] **Step 4: Implement queue gating**

In `DownloadQueue.swift`:

New stored properties, after `public var videoTools`:

```swift
    /// Daily window scheduled downloads run in; nil = they never start. Set by the app, then call `refreshSchedule()`.
    @ObservationIgnored public var scheduleWindow: ScheduleWindow?
```

and with the other private properties:

```swift
    @ObservationIgnored private var windowOpen = false
    /// Downloads stopped because the window closed: they go back to queued, not paused.
    @ObservationIgnored private var requeueing: Set<UUID> = []
    /// A scheduled download has started since the end action last fired.
    @ObservationIgnored private var scheduledRunPending = false
```

`add`: add the parameter and set the flag:

```swift
    @discardableResult
    public func add(url: URL, headers: [String: String] = [:], filename: String? = nil, directory: URL, categories: [FileCategory]? = nil, video: VideoQuality? = nil, scheduled: Bool = false) -> UUID {
        if let existing = items.first(where: { $0.url == url && $0.video == video && $0.state != .completed }) {
            highlighted = existing.id
            return existing.id
        }
        var record = DownloadRecord(url: url, headers: headers, filename: filename.map(sanitizeFilename), directory: directory, categories: categories, video: video)
        record.scheduled = scheduled ? true : nil
        items.append(record)
        persist()
        schedule()
        return record.id
    }
```

New public methods, after `resumeAll()`:

```swift
    /// Re-checks the window at `now`: starts scheduled downloads while it is open, moves running ones back to queued when it is closed.
    public func refreshSchedule(now: Date = .now) {
        windowOpen = scheduleWindow?.contains(now) ?? false
        if !windowOpen {
            for record in items where record.scheduled == true { requeue(record.id) }
        }
        schedule()
    }

    /// "Start in Schedule" / "Start Now". Scheduling a running download while the window is closed puts it back in the queue.
    public func setScheduled(_ id: UUID, _ scheduled: Bool) {
        update(id) { $0.scheduled = scheduled ? true : nil }
        if scheduled && running[id] != nil {
            if windowOpen { scheduledRunPending = true } else { requeue(id) }
        }
        persist()
        schedule()
    }
```

`schedule()`: gate scheduled records on the window:

```swift
    private func schedule() {
        guard !shuttingDown else { return }
        for record in items where record.state == .queued && (record.scheduled != true || windowOpen) && running.count < maxConcurrent {
            start(record)
        }
    }
```

`start(_:)`: first line becomes:

```swift
        if record.scheduled == true { scheduledRunPending = true }
        update(record.id) { $0.state = .downloading }
```

New private helper, after `start`:

```swift
    /// Stops a running download; finished() puts it back to queued with its progress.
    private func requeue(_ id: UUID) {
        guard let task = running[id] else { return }
        requeueing.insert(id)
        task.cancel()
    }
```

`progress(_:)`: keep the live flag. Replace `update(record.id) { $0 = record }` with:

```swift
        // The engine's copy predates any schedule toggle made since the start.
        update(record.id) { var record = record; record.scheduled = $0.scheduled; $0 = record }
```

`finished(_:_:)`: the requeue state and the flag:

```swift
    private func finished(_ id: UUID, _ result: DownloadRecord) {
        running[id] = nil
        speeds[id] = nil
        lastSample[id] = nil
        var result = result
        let requeued = requeueing.remove(id) != nil && result.state == .paused
        if requeued { result.state = .queued }   // the window closed: wait for it to open again
        if items.contains(where: { $0.id == id }) {
            update(id) { result.scheduled = $0.scheduled; $0 = result }
            if result.state != .paused && !requeued { onFinished?(result) }
        } else if result.state != .completed, let temp = result.tempURL {
            try? FileManager.default.removeItem(at: temp)   // removed while running
        }
        persist()
        schedule()
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Gom/GomCore --filter ScheduledQueueTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the whole core suite**

Run: `swift test --package-path Gom/GomCore`
Expected: all tests pass. `DownloadQueueTests` covers the unchanged pause/resume, shutdown and removal paths.

- [ ] **Step 7: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/DownloadRecord.swift Gom/GomCore/Sources/GomCore/DownloadQueue.swift Gom/GomCore/Tests/GomCoreTests/ScheduleTests.swift
git commit -m "Gate scheduled downloads on the schedule window"
```

---

### Task 3: `onScheduleFinished`

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/DownloadQueue.swift`
- Test: `Gom/GomCore/Tests/GomCoreTests/ScheduleTests.swift` (append to `ScheduledQueueTests`)

**Interfaces:**
- Consumes: `scheduledRunPending`, `refreshSchedule(now:)`, `add(..., scheduled:)` from Task 2.
- Produces: `DownloadQueue.onScheduleFinished: (() -> Void)?`

- [ ] **Step 1: Write the failing tests**

Append inside `ScheduledQueueTests`:

```swift
    @Test func endActionFiresOnceAfterScheduledAndOtherDownloadsFinish() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        var fired = 0
        queue.onScheduleFinished = { fired += 1 }
        queue.refreshSchedule(now: inside)
        let (other, otherFile) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.5), path: "/other.bin")
        let (first, _) = MockServer.serve(.init(data: testData(100_000)), path: "/one.bin")
        let (second, _) = MockServer.serve(.init(data: testData(200_000)), path: "/two.bin")
        let unscheduled = queue.add(url: other, directory: dir)
        let a = queue.add(url: first, directory: dir, scheduled: true)
        let b = queue.add(url: second, directory: dir, scheduled: true)

        try await waitUntil { record(queue, a)?.state == .completed && record(queue, b)?.state == .completed }
        #expect(fired == 0)   // an unscheduled download is still running

        otherFile.state.withLock { $0.chunkDelay = 0 }
        try await waitUntil { record(queue, unscheduled)?.state == .completed }
        #expect(fired == 1)
        queue.refreshSchedule(now: inside)
        #expect(fired == 1)
    }

    @Test func closingWindowWithWorkLeftDoesNotFire() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        var fired = 0
        queue.onScheduleFinished = { fired += 1 }
        queue.refreshSchedule(now: inside)
        let (url, _) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.1))
        let id = queue.add(url: url, directory: dir, scheduled: true)
        try await waitUntil { (record(queue, id)?.downloadedBytes ?? 0) > 0 }

        queue.refreshSchedule(now: outside)
        try await waitUntil { record(queue, id)?.state == .queued && queue.activeCount == 0 }
        #expect(fired == 0)
    }

    @Test func manuallyPausedScheduledDownloadDoesNotBlock() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        var fired = 0
        queue.onScheduleFinished = { fired += 1 }
        queue.refreshSchedule(now: inside)
        let (slow, _) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.5), path: "/slow.bin")
        let (fast, _) = MockServer.serve(.init(data: testData(100_000)), path: "/fast.bin")
        let paused = queue.add(url: slow, directory: dir, scheduled: true)
        let done = queue.add(url: fast, directory: dir, scheduled: true)

        queue.pause(paused)
        try await waitUntil { record(queue, paused)?.state == .paused && record(queue, done)?.state == .completed }
        #expect(fired == 1)
    }

    @Test func shutdownDoesNotFire() async throws {
        let dir = try makeTempDir()
        let queue = makeQueue(dir)
        var fired = 0
        queue.onScheduleFinished = { fired += 1 }
        queue.refreshSchedule(now: inside)
        let (url, _) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.1))
        let id = queue.add(url: url, directory: dir, scheduled: true)
        try await waitUntil { (record(queue, id)?.downloadedBytes ?? 0) > 0 }

        await queue.shutdown()
        #expect(fired == 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Gom/GomCore --filter ScheduledQueueTests`
Expected: FAIL to compile: "value of type 'DownloadQueue' has no member 'onScheduleFinished'".

- [ ] **Step 3: Implement**

In `DownloadQueue.swift`, after `onFinished`:

```swift
    /// Called once all scheduled downloads that ran are completed or failed and nothing else is downloading.
    @ObservationIgnored public var onScheduleFinished: (() -> Void)?
```

At the end of `finished(_:_:)`, after `schedule()`:

```swift
        checkScheduleFinished()
```

New private method, after `finished`:

```swift
    /// Scheduled downloads paused by hand don't count as pending; ones requeued at window close do.
    private func checkScheduleFinished() {
        guard scheduledRunPending, !shuttingDown, running.isEmpty,
              !items.contains(where: { $0.scheduled == true && ($0.state == .queued || $0.state == .downloading) }) else { return }
        scheduledRunPending = false
        onScheduleFinished?()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Gom/GomCore --filter ScheduledQueueTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Run the whole core suite**

Run: `swift test --package-path Gom/GomCore`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Gom/GomCore/Sources/GomCore/DownloadQueue.swift Gom/GomCore/Tests/GomCoreTests/ScheduleTests.swift
git commit -m "Report when scheduled downloads have finished"
```

---

### Task 4: App: settings, timer, end action, row and add bar

**Files:**
- Modify: `Gom/App/AppSettings.swift`
- Modify: `Gom/App/GomApp.swift` (`AppDelegate`)
- Modify: `Gom/App/SettingsView.swift`
- Modify: `Gom/App/DownloadRow.swift`
- Modify: `Gom/App/ContentView.swift`

**Interfaces:**
- Consumes: `ScheduleWindow`, `DownloadQueue.scheduleWindow`, `refreshSchedule()`, `setScheduled(_:_:)`, `add(..., scheduled:)`, `onScheduleFinished`, `DownloadRecord.scheduled`.
- Produces: `enum ScheduleAction: String, CaseIterable { case none, quit, sleep }` with `label`; `AppSettings.scheduleWindow: ScheduleWindow`; `AppSettings.scheduleAction: ScheduleAction`.

App code has no unit tests in this repo. Verification is the build plus the manual run in Task 5.

- [ ] **Step 1: Settings keys**

In `AppSettings.swift`, inside `enum AppSettings` after `videoQuality`:

```swift
    /// Daily window for scheduled downloads, in minutes since midnight; 01:00–06:00 by default.
    static var scheduleWindow: ScheduleWindow {
        ScheduleWindow(start: defaults.object(forKey: "scheduleStart") as? Int ?? 60,
                       end: defaults.object(forKey: "scheduleEnd") as? Int ?? 360)
    }
    static var scheduleAction: ScheduleAction {
        defaults.string(forKey: "scheduleAction").flatMap(ScheduleAction.init(rawValue:)) ?? .none
    }
```

At the end of the file:

```swift
/// What Gom does once scheduled downloads finish.
enum ScheduleAction: String, CaseIterable {
    case none, quit, sleep

    var label: String {
        switch self {
        case .none: "Do Nothing"
        case .quit: "Quit Gom"
        case .sleep: "Sleep Mac"
        }
    }
}
```

- [ ] **Step 2: AppDelegate wiring**

In `GomApp.swift`, in `applicationDidFinishLaunching` after `queue.bandwidthLimit = ...`:

```swift
        queue.onScheduleFinished = { [weak self] in self?.scheduleFinished() }
        queue.scheduleWindow = AppSettings.scheduleWindow
        queue.refreshSchedule()
        // ponytail: polls every 30 s, so the window opens and closes up to 30 s late; exact timers would need DST/wake handling.
        _ = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [queue] _ in
            MainActor.assumeIsolated { queue.refreshSchedule() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [queue] _ in
            MainActor.assumeIsolated { queue.refreshSchedule() }
        }
```

New property next to `server`:

```swift
    private var countdown: (alert: NSAlert, verb: String, deadline: Date)?
```

New methods in `AppDelegate`, after `notify`. (Revised after the manual run: a countdown `Task` never ticks while `runModal` holds the main actor, and calling `terminate` from inside a main-actor job deadlocks against `applicationShouldTerminate`'s reply task. So the alert runs from a run-loop callout, and a `.modalPanel` timer drives the countdown.)

```swift
    /// Counts down 60 s in an alert, then quits or sleeps the Mac unless the user cancels.
    private func scheduleFinished() {
        let action = AppSettings.scheduleAction
        guard action != .none else { return }
        // A run-loop callout, not a Task or main-queue block: inside those, runModal and terminate's
        // wait for applicationShouldTerminate's reply would hold the main actor and deadlock.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.showCountdown(action) }
        }
    }

    private func showCountdown(_ action: ScheduleAction) {
        let verb = action == .quit ? "quit" : "put the Mac to sleep"
        let alert = NSAlert()
        alert.messageText = "Scheduled downloads finished"
        alert.informativeText = "Gom will \(verb) in 60 seconds."
        alert.addButton(withTitle: action == .quit ? "Quit Now" : "Sleep Now")
        alert.addButton(withTitle: "Cancel")
        countdown = (alert, verb, .now + 60)
        // A run-loop timer, not a Task: main-actor tasks don't run while runModal holds the main actor.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCountdown() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()
        countdown = nil
        guard response == .alertFirstButtonReturn || response == .abort else { return }
        if action == .quit { NSApp.terminate(nil) } else { Self.sleepMac() }
    }

    private func tickCountdown() {
        guard let countdown else { return }
        let left = Int(countdown.deadline.timeIntervalSinceNow.rounded())
        if left <= 0 {
            NSApp.abortModal()   // unlike stopModal, works from a timer
        } else {
            countdown.alert.informativeText = "Gom will \(countdown.verb) in \(left) seconds."
        }
    }

    private static func sleepMac() {
        let pmset = Process()
        pmset.executableURL = URL(filePath: "/usr/bin/pmset")
        pmset.arguments = ["sleepnow"]
        pmset.terminationHandler = { if $0.terminationStatus != 0 { print("Gom: pmset sleepnow exited with \($0.terminationStatus)") } }
        do {
            try pmset.run()
        } catch {
            print("Gom: pmset sleepnow failed: \(error)")
        }
    }
```

- [ ] **Step 3: Settings section**

In `SettingsView.swift`, new properties after `speedLimitKB`:

```swift
    @AppStorage("scheduleStart") private var scheduleStart = 60
    @AppStorage("scheduleEnd") private var scheduleEnd = 360
    @AppStorage("scheduleAction") private var scheduleAction = ScheduleAction.none
```

A new `Section` after the "Folders by File Type" section (after its `.disabled(!sortByType)`):

```swift
            Section {
                DatePicker("Start at", selection: time($scheduleStart), displayedComponents: .hourAndMinute)
                DatePicker("Pause at", selection: time($scheduleEnd), displayedComponents: .hourAndMinute)
                Picker("When scheduled downloads finish", selection: $scheduleAction) {
                    ForEach(ScheduleAction.allCases, id: \.self) { Text($0.label) }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Scheduled downloads only run between these times and pause outside them. Right-click a download and choose Start in Schedule, or turn on Schedule before adding links. Gom must be running and the Mac awake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Next to the other `onChange` modifiers:

```swift
        .onChange(of: scheduleStart) { applySchedule() }
        .onChange(of: scheduleEnd) { applySchedule() }
```

New private helpers, after `checkNotifications()`:

```swift
    private func applySchedule() {
        queue.scheduleWindow = AppSettings.scheduleWindow
        queue.refreshSchedule()
    }

    /// Edits minutes-since-midnight with a time picker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: {
                let time = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (time.hour ?? 0) * 60 + (time.minute ?? 0)
            }
        )
    }
```

- [ ] **Step 4: Row status and context menu**

In `DownloadRow.swift`, in `.contextMenu`, before `Button("Remove from List")`:

```swift
            if item.state != .completed {
                if item.scheduled == true {
                    Button("Start Now") { queue.setScheduled(item.id, false) }
                } else {
                    Button("Start in Schedule") { queue.setScheduled(item.id, true) }
                }
            }
```

In `detail`, replace `case .queued: parts.append("Queued")` with:

```swift
        case .queued:
            if item.scheduled == true {
                let start = AppSettings.scheduleWindow.start
                parts.append("Scheduled · starts \(String(format: "%02d:%02d", start / 60, start % 60))")
            } else {
                parts.append("Queued")
            }
```

- [ ] **Step 5: Add-bar toggle**

In `ContentView.swift`, new property after `input`:

```swift
    @AppStorage("scheduleNew") private var scheduleNew = false
```

Before the `Button("Add", ...)` in the input `HStack`:

```swift
                Toggle("Schedule", isOn: $scheduleNew)
                    .help("Add links as scheduled downloads; they run in the window set in Settings")
```

In `addAll`, pass the flag:

```swift
            queue.add(url: url, directory: AppSettings.downloadDirectory, categories: AppSettings.sortByType ? AppSettings.categories : nil, video: video, scheduled: scheduleNew)
```

- [ ] **Step 6: Build**

Run (from `Gom/`): `xcodegen generate && xcodebuild -project Gom.xcodeproj -scheme Gom -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` with no new warnings in the changed files. Don't add `@unchecked Sendable` wrappers; the timer closure captures only the `@MainActor` delegate.

- [ ] **Step 7: Commit**

```bash
git add Gom/App/AppSettings.swift Gom/App/GomApp.swift Gom/App/SettingsView.swift Gom/App/DownloadRow.swift Gom/App/ContentView.swift
git commit -m "Add schedule settings, row actions and end-of-schedule countdown"
```

---

### Task 5: README and manual check

**Files:**
- Modify: `README.md` (Features list, Roadmap)

- [ ] **Step 1: README**

In Features, after the speed-limit bullet:

```markdown
- Scheduled downloads: mark downloads (right-click → Start in Schedule, or the Schedule toggle when adding) to run only in a daily window (Settings → Schedule, e.g. 01:00–06:00). They pause when the window closes and continue the next time it opens. Optionally quit Gom or put the Mac to sleep once they finish, after a 60-second countdown you can cancel.
```

Replace the Roadmap's `- Phase 3: scheduled downloads.` with:

```markdown
- ~~Phase 3: scheduled downloads.~~ Done.
```

- [ ] **Step 2: Manual run** (see the `gom-gui-testing` memory: quit the installed Gom, drive the debug build with cua-driver, never osascript keystrokes)

1. Settings → Schedule: Start at = now + 2 min, Pause at = now + 4 min, end action Quit Gom.
2. Turn on Schedule in the add bar and paste a large-file URL. Expected: the row shows "Scheduled · starts HH:MM" and doesn't download.
3. Wait until the start time. Expected: within 30 s it starts downloading.
4. Wait until the pause time. Expected: within 30 s it goes back to "Scheduled", progress kept, and no failure notification appears.
5. Right-click → Start Now. Expected: it downloads right away. When it finishes, the countdown alert appears and the seconds count down. Press Cancel and Gom stays running.
6. Repeat with a small file and let the countdown reach 0. Expected: Gom quits. Relaunch and check the list is intact.
7. Optional, with the user's OK: the Sleep Mac action, pressing "Sleep Now".

Record what was observed in the PR description.

- [ ] **Step 3: Full test suite once more**

Run: `swift test --package-path Gom/GomCore`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Document scheduled downloads; mark phase 3 done"
```
