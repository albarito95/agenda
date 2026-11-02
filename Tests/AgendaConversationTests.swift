import Foundation

@main
struct AgendaConversationTests {
    static func main() {
        let a = item("A", title: "Dentista")
        let b = item("B", title: "Consulta")
        var references = AgendaReferences()
        references.recordMutation(a)
        precondition(references.lastEvent == a)
        references.recordList([b])
        precondition(references.lastEvent == b, "Una consulta debe sustituir el referente anterior.")
        references.recordList([a, b])
        precondition(references.lastEvent == nil, "Una lista múltiple no permite interpretar «esa» como la cita antigua.")
        precondition(references.item(forPointer: "#2") == b)
        for invalid in ["#0", "#3", "#01", "#-1", "#2 ", "2", "#999999999999999999999999"] {
            precondition(references.item(forPointer: invalid) == nil)
        }
        references.recordMutation(b)
        precondition(references.item(forPointer: "#1") == nil, "Los números antiguos caducan tras un cambio.")
        references.recordList([])
        precondition(references.lastEvent == nil)
        references.recordList(Array(repeating: a, count: 20))
        precondition(references.listedEvents.count == 12)
        for command in ["Cancela.", "  ¡OLVÍDALO!  ", "Déjalo", "para", "Olvida lo anterior."] {
            precondition(AgendaConversationControl.isCancellation(command), command)
        }
        for command in ["cancela la cita del dentista", "para mañana", "no canceles", ""] {
            precondition(!AgendaConversationControl.isCancellation(command), command)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let march28 = date(2026, 3, 28, calendar)
        let march29 = date(2026, 3, 29, calendar)
        let march30 = date(2026, 3, 30, calendar)
        let moved = AgendaAllDayInterval.moved(originalStart: march28, originalEnd: march29,
            wasAllDay: true, destination: nil, through: nil, shiftMinutes: 1_440, calendar: calendar)!
        precondition(moved.start == march29 && moved.end == march30)
        precondition(moved.duration == 23 * 3_600, "El día del cambio de hora conserva medianoches, no 24 horas.")
        let october25 = date(2026, 10, 25, calendar)
        let october26 = date(2026, 10, 26, calendar)
        let autumn = AgendaAllDayInterval.moved(originalStart: march28, originalEnd: march29,
            wasAllDay: true, destination: october25, through: nil, shiftMinutes: 0, calendar: calendar)!
        precondition(autumn.end == october26 && autumn.duration == 25 * 3_600)
        let multi = AgendaAllDayInterval.moved(originalStart: march28, originalEnd: march30,
            wasAllDay: true, destination: october25, through: nil, shiftMinutes: 0, calendar: calendar)!
        precondition(calendar.dateComponents([.day], from: multi.start, to: multi.end).day == 2)
        let converted = AgendaAllDayInterval.moved(originalStart: march28.addingTimeInterval(12 * 3_600),
            originalEnd: march28.addingTimeInterval(13 * 3_600), wasAllDay: false,
            destination: march29, through: march30, shiftMinutes: 0, calendar: calendar)!
        precondition(converted.start == march29)
        precondition(calendar.dateComponents([.day], from: converted.start, to: converted.end).day == 2)
        precondition(AgendaAllDayInterval.moved(originalStart: march28, originalEnd: march29,
            wasAllDay: true, destination: nil, through: nil, shiftMinutes: 30, calendar: calendar) == nil)
        precondition(AgendaAllDayInterval.moved(originalStart: march28, originalEnd: march29,
            wasAllDay: true, destination: march30, through: march28, shiftMinutes: 0, calendar: calendar) == nil)

        let slot = FreeSlot(start: Date(timeIntervalSince1970: 6_005), end: Date(timeIntervalSince1970: 10_800))
        let reserved = AgendaSlotReservation.interval(in: slot, durationMinutes: 60, now: Date(timeIntervalSince1970: 5_000))!
        precondition(reserved.start.timeIntervalSince1970 == 6_060, "Nunca redondear antes del inicio real del hueco.")
        precondition(reserved.end.timeIntervalSince1970 == 9_660)
        let ongoing = AgendaSlotReservation.interval(in: slot, durationMinutes: 30, now: Date(timeIntervalSince1970: 8_001))!
        precondition(ongoing.start.timeIntervalSince1970 == 8_040)
        precondition(AgendaSlotReservation.interval(in: slot, durationMinutes: 60, now: Date(timeIntervalSince1970: 8_001)) == nil)
        precondition(AgendaSlotReservation.interval(in: slot, durationMinutes: 0, now: .distantPast) == nil)
        precondition(AgendaSlotReservation.interval(in: slot, durationMinutes: Int.max, now: .distantPast) == nil)
        precondition(!AgendaBatchOrder.canPrepareChangesFirst([.query, .mutation]), "Buscar y reservar el segundo no puede usar huecos de una consulta anterior.")
        precondition(!AgendaBatchOrder.canPrepareChangesFirst([.mutation, .query, .mutation]), "Una segunda mutación no puede depender de una consulta aún no ejecutada.")
        precondition(AgendaBatchOrder.canPrepareChangesFirst([.mutation, .mutation, .query]), "Crear citas independientes y consultar después sí conserva el orden.")
        precondition(AgendaBatchOrder.canPrepareChangesFirst([.query, .query]), "Las consultas independientes son válidas.")
        print("AgendaConversationTests: referencias, cancelación, días completos, huecos y orden de lotes correctos.")
    }

    static func item(_ id: String, title: String) -> AgendaItem {
        AgendaItem(id: id, calendarID: "test", title: title, start: Date(timeIntervalSince1970: 0),
                   end: Date(timeIntervalSince1970: 3_600), isAllDay: false, location: "", notes: "", colorHex: "000000")
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
