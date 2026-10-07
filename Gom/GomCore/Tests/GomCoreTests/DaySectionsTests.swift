import Foundation
import Testing
@testable import GomCore

@Suite struct DaySectionsTests {
    @Test func unfinishedStayInTodayAndFinishedGoToTheirDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10))!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: today)!
        func record(_ name: String, _ added: Date, _ state: DownloadState, completed: Date? = nil) -> DownloadRecord {
            var r = DownloadRecord(url: URL(string: "https://example.com/\(name)")!, directory: URL(filePath: "/tmp"), addedAt: added)
            r.state = state
            r.completedAt = completed ?? (state == .completed ? added : nil)
            return r
        }
        let items = [   // newest first, like the list
            record("today-done", today.addingTimeInterval(3600), .completed),
            record("old-paused", yesterday.addingTimeInterval(60), .paused),
            record("yesterday-done", yesterday.addingTimeInterval(30), .completed),
            record("lastweek-added-done-today", lastWeek.addingTimeInterval(90), .completed, completed: today.addingTimeInterval(60)),
            record("old-failed", lastWeek.addingTimeInterval(60), .failed("x")),
            record("lastweek-done", lastWeek, .completed),
        ]
        let sections = daySections(items, now: now, calendar: calendar)
        #expect(sections.map(\.day) == [today, yesterday, lastWeek])
        #expect(sections.map { $0.items.map(\.url.lastPathComponent) } == [
            ["today-done", "old-paused", "lastweek-added-done-today", "old-failed"],
            ["yesterday-done"],
            ["lastweek-done"],
        ])
        #expect(daySections([], now: now, calendar: calendar).isEmpty)
    }
}
