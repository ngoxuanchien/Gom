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
        let (url, file) = MockServer.serve(.init(data: testData(5_000_000), chunkDelay: 0.1))
        let id = queue.add(url: url, directory: dir, scheduled: true)
        try await waitUntil { (record(queue, id)?.downloadedBytes ?? 0) > 0 }

        queue.setScheduled(id, false)
        #expect(record(queue, id)?.state == .downloading)   // toggled mid-run, so progress writes follow
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
