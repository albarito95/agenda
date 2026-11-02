import Foundation

struct AgendaItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let calendarID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String
    var notes: String
    var colorHex: String
    var blocksTime: Bool = true
}

struct FreeSlot: Identifiable, Equatable, Sendable {
    let start: Date
    let end: Date
    var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
}

struct PositionedItem: Identifiable, Sendable {
    let event: AgendaItem
    let startFraction: Double
    let endFraction: Double
    let lane: Int
    let laneCount: Int
    var id: String { event.id }
}

enum AgendaClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "es_ES")
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func day(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), dayString(date) == value else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func date(day value: String, time: String) -> Date? {
        guard let base = day(value) else { return nil }
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        guard let result = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base,
                                         matchingPolicy: .strict, repeatedTimePolicy: .first,
                                         direction: .forward),
              let last = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base,
                                       matchingPolicy: .strict, repeatedTimePolicy: .last,
                                       direction: .forward), result == last,
              calendar.isDate(result, inSameDayAs: base),
              calendar.component(.hour, from: result) == hour,
              calendar.component(.minute, from: result) == minute else { return nil }
        return result
    }
}
