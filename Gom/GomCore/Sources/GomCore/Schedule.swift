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
