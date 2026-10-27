// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

import Foundation

/// One month of the taskbar clock's calendar flyout (Windows 11): six weeks of days starting on the calendar's first
/// weekday (the user's region), the days of the next and previous months included, and today marked.
public struct CalendarMonth: Equatable, Sendable {
    public struct Day: Equatable, Sendable, Identifiable {
        public let date: Date
        public let number: Int
        public let inMonth: Bool
        public let isToday: Bool
        /// `yyyy-MM-dd` in the calendar's time zone (stable ids for views and tests).
        public let id: String
    }

    /// The first moment of the month shown.
    public let month: Date
    /// "October 2026", in the locale.
    public let title: String
    /// The weekday column headers, starting on the first weekday ("Mo", "Tu", …).
    public let weekdays: [String]
    /// Six rows of seven days.
    public let weeks: [[Day]]

    public init(containing date: Date, today: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        var calendar = calendar
        calendar.locale = locale
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        self.month = month
        let title = DateFormatter()
        title.calendar = calendar
        title.locale = locale
        title.timeZone = calendar.timeZone
        title.setLocalizedDateFormatFromTemplate("yMMMM")
        self.title = title.string(from: month)
        let symbols = calendar.shortStandaloneWeekdaySymbols // Sunday first, as Calendar numbers them
        let first = calendar.firstWeekday - 1
        weekdays = (0..<7).map { symbols[(first + $0) % 7] }
        // Back to the first weekday on or before the 1st.
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: month) ?? month
        let id = DateFormatter()
        id.calendar = calendar
        id.locale = Locale(identifier: "en_US_POSIX")
        id.timeZone = calendar.timeZone
        id.dateFormat = "yyyy-MM-dd"
        let thisMonth = calendar.component(.month, from: month)
        let days: [Day] = (0..<42).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return Day(date: day, number: calendar.component(.day, from: day), inMonth: calendar.component(.month, from: day) == thisMonth,
                       isToday: calendar.isDate(day, inSameDayAs: today), id: id.string(from: day))
        }
        weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    /// The month before or after (`by` months).
    public func moved(by months: Int, today: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> CalendarMonth {
        CalendarMonth(containing: calendar.date(byAdding: .month, value: months, to: month) ?? month, today: today, calendar: calendar, locale: locale)
    }

    /// The flyout's header, the full date of `date` ("Tuesday, October 27"), in the locale.
    public static func header(for date: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return f.string(from: date)
    }
}
