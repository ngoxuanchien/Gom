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
