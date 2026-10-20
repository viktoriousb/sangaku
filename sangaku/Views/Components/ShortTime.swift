import Foundation

/// Times in Review and Compare: the time alone today, the day and time otherwise.
enum ShortTime {
    static func text(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
