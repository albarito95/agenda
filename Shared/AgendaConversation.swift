import Foundation

/// References always come from real calendar results, never from generated IDs.
struct AgendaReferences {
    private(set) var lastEvent: AgendaItem?
    private(set) var listedEvents: [AgendaItem] = []

    mutating func recordMutation(_ item: AgendaItem?) {
        lastEvent = item
        listedEvents = []
    }

    mutating func recordList(_ items: [AgendaItem]) {
        listedEvents = Array(items.prefix(12))
        lastEvent = items.count == 1 ? items[0] : nil
    }

    func item(forPointer pointer: String) -> AgendaItem? {
        guard pointer.first == "#", let number = Int(pointer.dropFirst()),
              pointer == "#\(number)", number > 0, number <= listedEvents.count else { return nil }
        return listedEvents[number - 1]
    }
}

enum AgendaConversationControl {
    static func isCancellation(_ text: String) -> Bool {
        let value = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                 locale: Locale(identifier: "es_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["cancelar", "cancela", "olvidalo", "olvida lo anterior", "dejalo", "para"].contains(value)
    }
}

/// Mutations are validated together before committing. A query followed by a
/// mutation could otherwise resolve an ordinal against a previous result set.
enum AgendaBatchOrder {
    enum Step { case query, mutation }

    static func canPrepareChangesFirst(_ steps: [Step]) -> Bool {
        var hasQuery = false
        for step in steps {
            switch step {
            case .query: hasQuery = true
            case .mutation: if hasQuery { return false }
            }
        }
        return true
    }
}

/// Calendar-day arithmetic keeps all-day events at midnight across DST changes.
enum AgendaAllDayInterval {
    static func moved(originalStart: Date, originalEnd: Date, wasAllDay: Bool,
                      destination: Date?, through: Date?, shiftMinutes: Int,
                      calendar: Calendar) -> DateInterval? {
        guard (-525_600...525_600).contains(shiftMinutes), shiftMinutes % 1_440 == 0 else { return nil }
        let originalDay = calendar.startOfDay(for: originalStart)
        let count = wasAllDay ? calendar.dateComponents([.day], from: originalDay,
                                                        to: calendar.startOfDay(for: originalEnd)).day ?? 0 : 1
        guard count > 0 else { return nil }
        let base = destination.map { calendar.startOfDay(for: $0) } ?? originalDay
        guard let start = calendar.date(byAdding: .day, value: shiftMinutes / 1_440, to: base),
              let end = through.flatMap({ calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) })
                ?? calendar.date(byAdding: .day, value: count, to: start), end > start,
              (calendar.dateComponents([.day], from: start, to: end).day ?? 367) <= 366 else { return nil }
        return DateInterval(start: start, end: end)
    }
}

enum AgendaSlotReservation {
    static func interval(in slot: FreeSlot, durationMinutes: Int, now: Date) -> DateInterval? {
        guard (1...1_440).contains(durationMinutes) else { return nil }
        let earliest = max(slot.start, now)
        let start = Date(timeIntervalSince1970: ceil(earliest.timeIntervalSince1970 / 60) * 60)
        let end = start.addingTimeInterval(Double(durationMinutes * 60))
        guard end <= slot.end else { return nil }
        return DateInterval(start: start, end: end)
    }
}
