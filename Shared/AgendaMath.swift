import Foundation

/// Calendar calculations use half-open intervals: an event ending at 10:00
/// does not conflict with one beginning at 10:00.
enum AgendaMath {
    static func window(
        for day: Date,
        startHour: Int = 7,
        endHour: Int = 23,
        calendar: Calendar = .current
    ) -> DateInterval {
        let dayStart = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let firstHour = min(max(startHour, 0), 23)
        let lastHour = min(max(endHour, firstHour + 1), 24)
        let start = calendar.date(
            bySettingHour: firstHour, minute: 0, second: 0, of: dayStart,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first
        )!
        let end = lastHour == 24 ? nextDay : calendar.date(
            bySettingHour: lastHour, minute: 0, second: 0, of: dayStart,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first
        )!
        return DateInterval(start: start, end: end)
    }

    static func freeSlots(
        on day: Date,
        events: [AgendaItem],
        minimumMinutes: Int,
        startHour: Int = 7,
        endHour: Int = 23,
        calendar: Calendar = .current
    ) -> [FreeSlot] {
        let visible = window(for: day, startHour: startHour, endHour: endHour, calendar: calendar)
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        // All-day events are displayed separately, but still reserve the day.
        if events.contains(where: {
            $0.blocksTime && $0.isAllDay && $0.start < $0.end && $0.start < dayEnd && $0.end > dayStart
        }) {
            return []
        }

        let occupied = clippedEvents(events.filter(\.blocksTime), to: visible)
        let minimumDuration = Double(max(minimumMinutes, 1)) * 60
        var result: [FreeSlot] = []
        var cursor = visible.start

        for item in occupied {
            if item.start > cursor, item.start.timeIntervalSince(cursor) >= minimumDuration {
                result.append(FreeSlot(start: cursor, end: item.start))
            }
            cursor = max(cursor, item.end)
        }
        if visible.end > cursor, visible.end.timeIntervalSince(cursor) >= minimumDuration {
            result.append(FreeSlot(start: cursor, end: visible.end))
        }
        return result
    }

    /// Timed items only. The interface puts all-day items in a separate header.
    /// Fractions reflect actual duration, including a daylight-saving transition.
    static func layout(
        on day: Date,
        events: [AgendaItem],
        startHour: Int = 7,
        endHour: Int = 23,
        calendar: Calendar = .current
    ) -> [PositionedItem] {
        let visible = window(for: day, startHour: startHour, endHour: endHour, calendar: calendar)
        guard visible.duration > 0 else { return [] }
        let items = clippedEvents(events.filter { !$0.isAllDay }, to: visible)
        var result: [PositionedItem] = []
        var group: [ClippedItem] = []
        var groupEnd: Date?

        func positionedGroup(_ group: [ClippedItem]) -> [PositionedItem] {
            var laneEnds: [Date] = []
            var assigned: [(item: ClippedItem, lane: Int)] = []
            for item in group {
                let lane: Int
                if let reusable = laneEnds.firstIndex(where: { $0 <= item.start }) {
                    lane = reusable
                    laneEnds[reusable] = item.end
                } else {
                    lane = laneEnds.count
                    laneEnds.append(item.end)
                }
                assigned.append((item: item, lane: lane))
            }
            return assigned.map {
                PositionedItem(
                    event: $0.item.event,
                    startFraction: $0.item.start.timeIntervalSince(visible.start) / visible.duration,
                    endFraction: $0.item.end.timeIntervalSince(visible.start) / visible.duration,
                    lane: $0.lane,
                    laneCount: laneEnds.count
                )
            }
        }

        for item in items {
            if let previousEnd = groupEnd, item.start >= previousEnd {
                result.append(contentsOf: positionedGroup(group))
                group.removeAll(keepingCapacity: true)
                groupEnd = nil
            }
            group.append(item)
            groupEnd = max(groupEnd ?? item.end, item.end)
        }
        result.append(contentsOf: positionedGroup(group))
        return result
    }

    private struct ClippedItem {
        let event: AgendaItem
        let start: Date
        let end: Date
    }

    private static func clippedEvents(_ events: [AgendaItem], to window: DateInterval) -> [ClippedItem] {
        events.compactMap { event -> ClippedItem? in
            guard event.end > event.start, event.start < window.end, event.end > window.start else {
                return nil
            }
            let start = max(event.start, window.start)
            let end = min(event.end, window.end)
            guard end > start else { return nil }
            return ClippedItem(event: event, start: start, end: end)
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.event.id < $1.event.id
        }
    }
}
