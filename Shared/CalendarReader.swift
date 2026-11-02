import Foundation
import EventKit
import CoreGraphics

enum CalendarReader {
    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func loadTwoDays(now: Date = .now) throws -> [AgendaItem] {
        let calendar = AgendaClock.calendar
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else { return [] }
        return try load(start: start, end: end)
    }

    static func load(start: Date, end: Date) throws -> [AgendaItem] {
        guard isAuthorized else { throw AgendaError.calendarAccess }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(item)
            .sorted { $0.start < $1.start }
    }

    static func item(_ event: EKEvent) -> AgendaItem {
        AgendaItem(
            id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)",
            calendarID: event.calendar.calendarIdentifier,
            title: event.title ?? "Sin título",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location ?? "",
            notes: event.notes ?? "",
            colorHex: hex(event.calendar.cgColor),
            blocksTime: event.calendar.type != .birthday && event.availability != .free
        )
    }

    static func eventIdentifier(_ itemID: String) -> String {
        String(itemID.split(separator: "|", omittingEmptySubsequences: false).dropLast().joined(separator: "|"))
    }

    static func hex(_ color: CGColor?) -> String {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color?.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return "397FAD" }
        return components.prefix(3).map { String(format: "%02X", Int(max(0, min(1, $0)) * 255)) }.joined()
    }
}

enum AgendaError: LocalizedError {
    case calendarAccess
    case missing(String)
    case ambiguous(String)
    case readOnly
    case notFound
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .calendarAccess: "Permite el acceso a Calendario para ver y organizar tu agenda."
        case .missing(let message), .ambiguous(let message), .unsupported(let message): message
        case .readOnly: "Ese calendario es de solo lectura."
        case .notFound: "No encuentro esa cita. Indícame su nombre y el día."
        }
    }
}
