import Foundation

/// Run with the shared models and AgendaMath.swift as a small command-line test.
@main
enum AgendaMathTests {
    static var calendar: Calendar = {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return result
    }()

    static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }

    static func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false) -> AgendaItem {
        AgendaItem(
            id: id, calendarID: "test", title: id,
            start: date(start), end: date(end), isAllDay: allDay,
            location: "", notes: "", colorHex: "336699"
        )
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }

    static func main() {
        let day = date("2026-11-02T12:00:00+01:00")
        let touching = [
            event("A", "2026-11-02T08:00:00+01:00", "2026-11-02T10:00:00+01:00"),
            event("B", "2026-11-02T10:00:00+01:00", "2026-11-02T12:00:00+01:00")
        ]
        let slots = AgendaMath.freeSlots(on: day, events: touching, minimumMinutes: 30, startHour: 8, endHour: 14, calendar: calendar)
        expect(slots.count == 1, "Touching appointments must not produce a false gap")
        expect(slots[0].start == date("2026-11-02T12:00:00+01:00"), "Free interval starts after the occupied union")
        expect(slots[0].end == date("2026-11-02T14:00:00+01:00"), "Free interval reaches visible end")
        let touchingLayout = AgendaMath.layout(on: day, events: touching, startHour: 8, endHour: 14, calendar: calendar)
        expect(touchingLayout.allSatisfy { $0.lane == 0 && $0.laneCount == 1 }, "Touching events use a full-width lane")

        let overlapping = [
            event("A", "2026-11-02T08:00:00+01:00", "2026-11-02T10:00:00+01:00"),
            event("B", "2026-11-02T09:00:00+01:00", "2026-11-02T11:00:00+01:00"),
            event("C", "2026-11-02T10:00:00+01:00", "2026-11-02T12:00:00+01:00"),
            event("D", "2026-11-02T13:00:00+01:00", "2026-11-02T14:00:00+01:00")
        ]
        let overlapSlots = AgendaMath.freeSlots(on: day, events: overlapping.reversed(), minimumMinutes: 60, startHour: 8, endHour: 14, calendar: calendar)
        expect(overlapSlots.count == 1 && overlapSlots[0].start == date("2026-11-02T12:00:00+01:00"), "Merge overlapping events independent of input order")
        let overlapLayout = AgendaMath.layout(on: day, events: overlapping, startHour: 8, endHour: 14, calendar: calendar)
        expect(overlapLayout.prefix(3).allSatisfy { $0.laneCount == 2 }, "Connected overlap group must use a common lane count")
        expect(overlapLayout[0].lane == overlapLayout[2].lane, "A lane can be reused when its preceding event ends")
        expect(overlapLayout[3].laneCount == 1, "A separate group returns to full width")
        expect(abs(overlapLayout[0].endFraction - (2.0 / 6.0)) < 0.000001, "Durations must retain their true scale")

        let overnight = [event("Night", "2026-11-01T22:00:00+01:00", "2026-11-02T09:00:00+01:00")]
        let overnightSlots = AgendaMath.freeSlots(on: day, events: overnight, minimumMinutes: 30, startHour: 7, endHour: 10, calendar: calendar)
        expect(overnightSlots.count == 1 && overnightSlots[0].start == date("2026-11-02T09:00:00+01:00"), "An overnight event occupies the following morning")
        let overnightLayout = AgendaMath.layout(on: day, events: overnight, startHour: 7, endHour: 10, calendar: calendar)
        expect(overnightLayout[0].startFraction == 0, "Clip overnight block to visible start")

        let allDay = [event("Holiday", "2026-11-02T00:00:00+01:00", "2026-11-03T00:00:00+01:00", allDay: true)]
        expect(AgendaMath.freeSlots(on: day, events: allDay, minimumMinutes: 30, calendar: calendar).isEmpty, "All-day commitments reserve their calendar day")
        expect(AgendaMath.layout(on: day, events: allDay, calendar: calendar).isEmpty, "All-day commitments belong to the separate header")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        expect(AgendaMath.freeSlots(on: tomorrow, events: allDay, minimumMinutes: 30, calendar: calendar).count == 1, "An all-day event ending at midnight must not occupy tomorrow")
        var birthday = allDay[0]
        birthday.blocksTime = false
        expect(AgendaMath.freeSlots(on: day, events: [birthday], minimumMinutes: 30, calendar: calendar).count == 1, "A free all-day reminder must not block the day")
        var informational = touching[0]
        informational.blocksTime = false
        expect(AgendaMath.freeSlots(on: day, events: [informational], minimumMinutes: 30, startHour: 8, endHour: 14, calendar: calendar).first?.start == date("2026-11-02T08:00:00+01:00"), "An event marked free must not occupy a slot")
        let afternoon = AgendaClock.date(day: "2026-11-02", time: "15:45")!
        expect(AgendaClock.timeString(afternoon) == "15:45", "Clock strings must use 24-hour format regardless of the device locale")
        expect(AgendaClock.date(day: "2026-11-02", time: "25:15") == nil, "Reject invalid hours")
        expect(AgendaClock.day("2026-02-30") == nil, "Reject nonexistent dates")

        let fallDay = date("2026-10-25T12:00:00+01:00")
        let fallWindow = AgendaMath.window(for: fallDay, startHour: 0, endHour: 24, calendar: calendar)
        expect(fallWindow.duration == 25 * 3600, "Madrid's autumn daylight-saving day is 25 elapsed hours")
        let fallEmpty = AgendaMath.freeSlots(on: fallDay, events: [], minimumMinutes: 24 * 60, startHour: 0, endHour: 24, calendar: calendar)
        expect(fallEmpty.count == 1 && fallEmpty[0].end == fallWindow.end, "Free slots must reach the next local midnight on a DST day")
        let repeatedHourEvent = event("DST", "2026-10-25T02:30:00+02:00", "2026-10-25T02:30:00+01:00")
        let fallLayout = AgendaMath.layout(on: fallDay, events: [repeatedHourEvent], startHour: 0, endHour: 24, calendar: calendar)
        expect(abs(fallLayout[0].endFraction - fallLayout[0].startFraction - 1.0 / 25.0) < 0.000001, "Repeated wall-clock times still form a one-hour event")
        let springDay = date("2026-03-29T12:00:00+02:00")
        expect(AgendaMath.window(for: springDay, startHour: 0, endHour: 24, calendar: calendar).duration == 23 * 3600, "Madrid's spring day is 23 elapsed hours")
        let springEvent = event("Spring", "2026-03-29T01:00:00+01:00", "2026-03-29T04:00:00+02:00")
        expect(AgendaMath.layout(on: springDay, events: [springEvent], startHour: 2, endHour: 3, calendar: calendar).isEmpty, "A nonexistent local-hour window must not produce NaN geometry")

        let ignored = [
            event("Zero", "2026-11-02T09:00:00+01:00", "2026-11-02T09:00:00+01:00"),
            event("Before", "2026-11-02T05:00:00+01:00", "2026-11-02T07:00:00+01:00"),
            event("After", "2026-11-02T23:00:00+01:00", "2026-11-03T00:00:00+01:00")
        ]
        expect(AgendaMath.layout(on: day, events: ignored, calendar: calendar).isEmpty, "Exclude zero-duration and boundary-touching events")
        expect(AgendaMath.freeSlots(on: day, events: [], minimumMinutes: 16 * 60 + 1, calendar: calendar).isEmpty, "Do not offer a shorter slot than requested")
        print("AgendaMath: all calendar, overlap, overnight, all-day and DST checks passed.")
    }
}
