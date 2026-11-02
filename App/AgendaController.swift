import Foundation
import Combine
import EventKit
import WidgetKit

@MainActor
final class AgendaController: ObservableObject {
    @Published private(set) var items: [AgendaItem] = []
    @Published private(set) var hasAccess = CalendarReader.isAuthorized
    @Published private(set) var isWorking = false
    @Published private(set) var needsClarification = false
    @Published private(set) var calendarError: String?
    @Published var response = ""
    @Published var lastRequest = ""
    @Published var slots: [FreeSlot] = []
    @Published var selectedEvent: EKEvent?

    let eventStore = EKEventStore()
    private let interpreter = LocalAgendaInterpreter()
    private var dialogue: [String] = []
    private var references = AgendaReferences()
    private var requestGeneration = UUID()
    private var pendingRequest: String?
    private var undoChanges: [SavedChange] = []
    private var slotDurationMinutes = 60

    var intelligenceMessage: String? { interpreter.availabilityMessage }
    var voiceVocabulary: [String] {
        Array(Set((items + references.listedEvents).map(\.title))).sorted()
    }

    /// Invalidates the awaited interpretation before any calendar mutation.
    func cancelCurrentRequest() {
        let hadPendingRequest = isWorking || needsClarification
        requestGeneration = UUID()
        isWorking = false
        needsClarification = false
        pendingRequest = nil
        if hadPendingRequest { response = "Petición cancelada." }
        dialogue = []
    }

    func connect() async {
        do {
            hasAccess = try await eventStore.requestFullAccessToEvents()
            if hasAccess { refresh() }
            else { calendarError = AgendaError.calendarAccess.localizedDescription }
        } catch { calendarError = error.localizedDescription }

    }

    func refresh() {
        hasAccess = CalendarReader.isAuthorized
        guard hasAccess else {
            items = []
            calendarError = AgendaError.calendarAccess.localizedDescription
            return
        }
        do {
            items = try CalendarReader.loadTwoDays()
            calendarError = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "MiAgendaWidget")
        } catch { calendarError = error.localizedDescription }
    }

    func select(_ item: AgendaItem) {
        references.recordMutation(item)
        slots = []
        selectedEvent = rawEvent(for: item)
    }

    @discardableResult
    func openEvent(id: String) -> Bool {
        selectedEvent = nil
        references.recordMutation(nil)
        refresh()
        guard let item = items.first(where: { $0.id == id }) else { return false }
        select(item)
        return selectedEvent != nil
    }

    func send(_ request: String) async {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isWorking else { return }
        guard CalendarReader.isAuthorized else {
            hasAccess = false
            response = AgendaError.calendarAccess.localizedDescription
            return
        }
        let generation = UUID()
        requestGeneration = generation
        isWorking = true
        needsClarification = false
        lastRequest = request
        defer { if requestGeneration == generation { isWorking = false } }
        if AgendaConversationControl.isCancellation(request) {
            pendingRequest = nil
            dialogue = []
            response = "Petición cancelada."
            return
        }
        var effectiveRequest = request
        do {
            let plan = try await interpreter.interpret(request, lastEvent: references.lastEvent,
                                                       recentDialogue: dialogue, pendingRequest: pendingRequest ?? "",
                                                       candidates: references.listedEvents, slots: slots,
                                                       slotDurationMinutes: slotDurationMinutes)
            try ensureCurrent(generation)
            if plan.continuesPendingRequest { effectiveRequest = pendingRequest ?? request }
            if !plan.question.isEmpty {
                pendingRequest = effectiveRequest
                needsClarification = true
                response = plan.question
            } else {
                response = try execute(plan, generation: generation)
                pendingRequest = nil
                refresh()
            }
        } catch is CancellationError {
            // An old task must never reset a newer task's store or interface.
            guard requestGeneration == generation else { return }
            eventStore.reset()
            pendingRequest = nil
            response = "Petición cancelada."
        } catch {
            guard requestGeneration == generation else { return }
            eventStore.reset()
            response = error.localizedDescription
            if let agendaError = error as? AgendaError {
                switch agendaError {
                case .missing, .ambiguous, .notFound:
                    pendingRequest = effectiveRequest
                    needsClarification = true
                default:
                    pendingRequest = nil
                }
            } else {
                pendingRequest = nil
            }
        }
        guard requestGeneration == generation else { return }
        dialogue.append("Usuario: \(request)")
        dialogue.append("Agenda: \(response)")
        if dialogue.count > 8 { dialogue.removeFirst(dialogue.count - 8) }
    }

    private func ensureCurrent(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
    }

    private func execute(_ plan: AgendaPlan, generation: UUID) throws -> String {
        try ensureCurrent(generation)
        guard !plan.operations.isEmpty, plan.operations.count <= 5 else {
            throw AgendaError.missing("Dime qué quieres organizar. Puedes pedir hasta cinco cambios juntos.")
        }
        if plan.operations.contains(where: { $0.action == .clarify }) {
            throw AgendaError.missing("Necesito el nombre de la cita, el día o la hora para completar la petición.")
        }
        if plan.operations.contains(where: { $0.action == .undo }) {
            guard plan.operations.count == 1 else {
                throw AgendaError.missing("Pídeme deshacer por separado para no mezclarlo con otros cambios.")
            }
            return try undo(generation: generation)
        }
        let steps: [AgendaBatchOrder.Step] = plan.operations.compactMap {
            switch $0.action {
            case .list, .freeTime: return .query
            case .create, .update, .delete: return .mutation
            default: return nil
            }
        }
        guard AgendaBatchOrder.canPrepareChangesFirst(steps) else {
            throw AgendaError.missing("Pídeme primero la consulta o los huecos. Después elige la cita o el hueco que quieres usar, para trabajar con los resultados actuales.")
        }
        for operation in plan.operations {
            guard operation.durationMinutes >= 0 else {
                throw AgendaError.missing("La duración debe ser positiva. ¿Cuánto tiempo necesitas?")
            }
            guard operation.slotIndex >= 0, operation.slotIndex <= slots.count else {
                throw AgendaError.missing("Ese hueco ya no está disponible. Pídeme buscar los huecos otra vez.")
            }
            if operation.slotIndex > 0, operation.action != .create {
                throw AgendaError.missing("Para usar ese hueco, dime qué cita quieres añadir. Para mover otra cita, indica su nombre y la nueva hora.")
            }
            if operation.action == .list { _ = try queryRange(day: operation.day, through: operation.throughDay) }
            if operation.action == .freeTime {
                let range = try queryRange(day: operation.day, through: operation.throughDay)
                guard (AgendaClock.calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 999) <= 31,
                      operation.durationMinutes >= 0, operation.durationMinutes <= 1_440 else {
                    throw AgendaError.missing("Busca huecos en un intervalo de hasta un mes y con una duración válida.")
                }
            }
        }
        var prepared: [PreparedChange] = []
        var usedIDs: Set<String> = []
        for operation in plan.operations {
            if plan.operations.count > 1,
               operation.action == .update || operation.action == .delete,
               operation.target.isEmpty, operation.originalDay.isEmpty {
                throw AgendaError.missing("En una petición con varios cambios, indica el nombre y el día de cada cita. También puedes hacer este cambio por separado.")
            }
            switch operation.action {
            case .create:
                prepared.append(try prepareCreate(operation))
            case .update, .delete:
                let item = try resolve(operation)
                guard usedIDs.insert(item.id).inserted else {
                    throw AgendaError.missing("Has pedido varios cambios sobre la misma cita. Únelos en una sola indicación.")
                }
                guard let event = rawEvent(for: item) else { throw AgendaError.notFound }
                guard event.calendar.allowsContentModifications else { throw AgendaError.readOnly }
                prepared.append(try prepareExisting(event, operation: operation))
            default: break
            }
        }

        // Toda la validación termina antes de guardar el primer cambio.
        for change in prepared where !change.isDeletion {
            try validateConflicts(change, allChanges: prepared)
        }
        for change in prepared {
            try ensureCurrent(generation)
            if change.isDeletion {
                try eventStore.remove(change.event, span: .thisEvent, commit: false)
            } else {
                try eventStore.save(change.event, span: .thisEvent, commit: false)
            }
        }
        if !prepared.isEmpty {
            try ensureCurrent(generation)
            try eventStore.commit()
            slots = []
            undoChanges = prepared.map {
                SavedChange(before: $0.before, after: $0.isDeletion ? nil : CalendarReader.item($0.event),
                            modifiedAt: $0.event.lastModifiedDate)
            }
            if let event = prepared.last(where: { !$0.isDeletion })?.event {
                references.recordMutation(CalendarReader.item(event))
            } else { references.recordMutation(nil) }
        }

        var messages = prepared.map { change in
            if change.isDeletion { return "Eliminada: \(change.before?.item.title ?? "cita")." }
            let item = CalendarReader.item(change.event)
            let verb = change.before == nil ? "Añadida" : "Actualizada"
            return "\(verb): \(item.title), \(summaryDate(item.start))\(item.isAllDay ? ", todo el día" : "–" + AgendaClock.timeString(item.end))."
        }
        for operation in plan.operations {
            do {
                switch operation.action {
                case .list: messages.append(try list(operation))
                case .freeTime: messages.append(try findFree(operation))
                default: break
                }
            } catch {
                if prepared.isEmpty { throw error }
                messages.append("Los cambios están guardados, pero no he completado la consulta: \(error.localizedDescription)")
            }
        }
        return messages.joined(separator: "\n")
    }

    private struct PreparedChange {
        let event: EKEvent
        let before: EventSnapshot?
        let isDeletion: Bool
        let allowOverlap: Bool
    }

    private struct SavedChange {
        let before: EventSnapshot?
        let after: AgendaItem?
        let modifiedAt: Date?
    }

    private struct EventSnapshot {
        let item: AgendaItem
        let calendar: EKCalendar
        let alarms: [EKAlarm]?
        let recurrence: [EKRecurrenceRule]?
        let availability: EKEventAvailability
        let url: URL?
        let timeZone: TimeZone?
        let structuredLocation: EKStructuredLocation?

        init(_ event: EKEvent) {
            item = CalendarReader.item(event)
            calendar = event.calendar
            alarms = event.alarms?.compactMap { $0.copy() as? EKAlarm }
            recurrence = event.recurrenceRules
            availability = event.availability
            url = event.url
            timeZone = event.timeZone
            structuredLocation = event.structuredLocation?.copy() as? EKStructuredLocation
        }

        func apply(to event: EKEvent) {
            event.calendar = calendar
            event.title = item.title
            event.timeZone = timeZone
            event.url = url
            event.startDate = item.start
            event.endDate = item.end
            event.isAllDay = item.isAllDay
            event.location = item.location
            event.structuredLocation = structuredLocation?.copy() as? EKStructuredLocation
            event.notes = item.notes
            event.alarms = alarms?.compactMap { $0.copy() as? EKAlarm }
            event.availability = availability
        }
    }

    private func prepareCreate(_ proposed: AgendaOperation) throws -> PreparedChange {
        var op = proposed
        if op.slotIndex > 0 {
            guard !op.allDay, op.slotIndex <= slots.count else {
                throw AgendaError.missing("Ese hueco no es una reserva de todo el día. Indica la cita y su duración.")
            }
            let slot = slots[op.slotIndex - 1]
            let duration = op.durationMinutes > 0 ? op.durationMinutes : slotDurationMinutes
            guard op.day.isEmpty, op.time.isEmpty, op.endTime.isEmpty, op.throughDay.isEmpty else {
                throw AgendaError.missing("¿Uso el inicio del hueco elegido o prefieres una hora concreta?")
            }
            guard let interval = AgendaSlotReservation.interval(in: slot, durationMinutes: duration, now: .now) else {
                throw AgendaError.missing("Ese hueco ya no tiene tiempo suficiente. Pídeme buscar otro.")
            }
            op.day = AgendaClock.dayString(interval.start)
            op.time = AgendaClock.timeString(interval.start)
            op.endTime = ""
            op.throughDay = ""
            op.durationMinutes = duration
        }
        guard op.recurrence.isEmpty || op.recurrence == "none" else {
            throw AgendaError.unsupported("Para crear una serie, añade primero la cita puntual y toca su ficha → Repetir. Así podrás revisar la serie completa en Calendario.")
        }
        guard !op.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgendaError.missing("¿Cómo se llama la cita?")
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents, calendar.allowsContentModifications else {
            throw AgendaError.missing("Selecciona un calendario editable por omisión en Ajustes del iPhone → Apps → Calendario.")
        }
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        if calendar.supportedEventAvailabilities.contains(.busy) { event.availability = .busy }
        event.title = op.title
        event.isAllDay = op.allDay
        event.location = op.location
        event.notes = op.notes
        if op.allDay {
            guard let day = AgendaClock.day(op.day),
                  let lastDay = op.throughDay.isEmpty ? day : AgendaClock.day(op.throughDay),
                  let end = AgendaClock.calendar.date(byAdding: .day, value: 1, to: lastDay), end > day,
                  (AgendaClock.calendar.dateComponents([.day], from: day, to: end).day ?? 367) <= 366 else {
                throw AgendaError.missing("¿Qué día o días quieres reservar?")
            }
            event.startDate = day
            event.endDate = end
        } else {
            guard let start = AgendaClock.date(day: op.day, time: op.time) else {
                throw AgendaError.missing("¿Qué día y a qué hora empieza \(op.title)?")
            }
            event.startDate = start
            event.endDate = try endDate(for: op, start: start, defaultDuration: 60)
        }
        guard event.endDate > event.startDate else { throw AgendaError.missing("El final debe ser posterior al inicio.") }
        guard event.endDate > Date() else { throw AgendaError.missing("La fecha ya ha pasado. ¿Qué día querías indicar?") }
        try setAlarm(op.alertMinutes, on: event, isNew: true)
        return PreparedChange(event: event, before: nil, isDeletion: false, allowOverlap: op.allowOverlap)
    }

    private func prepareExisting(_ event: EKEvent, operation op: AgendaOperation) throws -> PreparedChange {
        guard event.attendees?.isEmpty != false else {
            throw AgendaError.unsupported("Esa cita tiene invitados. Tócala y revisa el cambio en su ficha de Calendario.")
        }
        guard !event.hasRecurrenceRules, !event.isDetached else {
            throw AgendaError.unsupported("Esa cita pertenece a una serie. Tócala para elegir qué ocurrencias modificar en Calendario.")
        }
        let snapshot = EventSnapshot(event)
        if op.action == .delete {
            return PreparedChange(event: event, before: snapshot, isDeletion: true, allowOverlap: true)
        }
        guard op.recurrence.isEmpty || op.recurrence == "none" else {
            throw AgendaError.unsupported("Para cambiar la repetición de una serie, toca la cita y edítala en su ficha.")
        }
        if !op.title.isEmpty { event.title = op.title }
        if !op.location.isEmpty { event.location = op.location }
        if op.clearNotes { event.notes = "" }
        else if !op.notes.isEmpty { event.notes = op.notes }
        let oldDuration = event.endDate.timeIntervalSince(event.startDate)
        let remainsAllDay = event.isAllDay && op.time.isEmpty && op.endTime.isEmpty && op.durationMinutes == 0
        if op.allDay || remainsAllDay {
            guard op.time.isEmpty, op.endTime.isEmpty, op.durationMinutes == 0 else {
                throw AgendaError.missing("¿Quieres reservar todo el día o una franja con hora de inicio y final?")
            }
            guard op.shiftMinutes == 0 || op.day.isEmpty else {
                throw AgendaError.missing("Indica el día de destino o cuántos días la desplazo, sin mezclar ambos.")
            }
            let destination = op.day.isEmpty ? nil : AgendaClock.day(op.day)
            let through = op.throughDay.isEmpty ? nil : AgendaClock.day(op.throughDay)
            guard op.day.isEmpty || destination != nil, op.throughDay.isEmpty || through != nil,
                  let interval = AgendaAllDayInterval.moved(originalStart: event.startDate,
                    originalEnd: event.endDate, wasAllDay: event.isAllDay, destination: destination,
                    through: through, shiftMinutes: op.shiftMinutes, calendar: AgendaClock.calendar) else {
                throw AgendaError.missing("Para una cita de todo el día, indica un día válido o un desplazamiento en días completos.")
            }
            event.isAllDay = true
            event.startDate = interval.start
            event.endDate = interval.end
        } else {
            if event.isAllDay, op.time.isEmpty {
                throw AgendaError.missing("¿A qué hora quieres que empiece la cita?")
            }
            // Giving a time to an all-day event creates a one-hour timed event by default.
            let duration = event.isAllDay ? 3_600 : oldDuration
            if op.shiftMinutes != 0 {
                guard (-525_600...525_600).contains(op.shiftMinutes),
                      op.day.isEmpty, op.time.isEmpty,
                      let start = AgendaClock.calendar.date(byAdding: .minute, value: op.shiftMinutes, to: event.startDate) else {
                    throw AgendaError.missing("Indica una nueva fecha y hora o un desplazamiento relativo, sin mezclar ambos.")
                }
                event.startDate = start
                event.endDate = start.addingTimeInterval(duration)
            } else if !op.day.isEmpty || !op.time.isEmpty {
                let day = op.day.isEmpty ? AgendaClock.dayString(event.startDate) : op.day
                let time = op.time.isEmpty ? AgendaClock.timeString(event.startDate) : op.time
                guard let start = AgendaClock.date(day: day, time: time) else {
                    throw AgendaError.missing("La nueva fecha u hora no es válida. ¿Cuándo quieres ponerla?")
                }
                event.startDate = start
                event.endDate = start.addingTimeInterval(duration)
            }
            event.isAllDay = false
            if !op.endTime.isEmpty || op.durationMinutes > 0 {
                event.endDate = try endDate(for: op, start: event.startDate,
                                           defaultDuration: max(1, Int(duration / 60)))
            }
        }
        guard event.endDate > event.startDate else { throw AgendaError.missing("La hora final debe ser posterior al inicio.") }
        try setAlarm(op.alertMinutes, on: event, isNew: false)
        return PreparedChange(event: event, before: snapshot, isDeletion: false, allowOverlap: op.allowOverlap)
    }

    private func endDate(for op: AgendaOperation, start: Date, defaultDuration: Int) throws -> Date {
        if !op.endTime.isEmpty {
            let day = op.throughDay.isEmpty ? AgendaClock.dayString(start) : op.throughDay
            guard var end = AgendaClock.date(day: day, time: op.endTime) else {
                throw AgendaError.missing("¿A qué hora termina?")
            }
            if end <= start, op.throughDay.isEmpty,
               AgendaClock.calendar.component(.hour, from: start) >= 18,
               AgendaClock.calendar.component(.hour, from: end) < 8 {
                end = AgendaClock.calendar.date(byAdding: .day, value: 1, to: end) ?? end
            }
            guard end > start, end.timeIntervalSince(start) <= 31 * 86_400 else {
                throw AgendaError.missing("No encajan las horas de inicio y final. Indícame ambas.")
            }
            return end
        }
        let duration = op.durationMinutes > 0 ? op.durationMinutes : defaultDuration
        guard duration <= 7 * 24 * 60,
              let end = AgendaClock.calendar.date(byAdding: .minute, value: duration, to: start) else {
            throw AgendaError.missing("La duración no es válida.")
        }
        return end
    }

    private func setAlarm(_ minutes: Int, on event: EKEvent, isNew: Bool) throws {
        guard (-2...10_080).contains(minutes) else { throw AgendaError.missing("El aviso debe estar entre cero y siete días antes.") }
        if minutes == -2, !isNew { return }
        let value = minutes == -2 ? 30 : minutes
        if value == -1 { event.alarms = nil; return }
        let alarmDate = event.startDate.addingTimeInterval(TimeInterval(-value * 60))
        if alarmDate <= Date(), minutes >= 0 {
            throw AgendaError.missing("Ese aviso ya habría pasado. ¿Lo pongo al empezar o sin aviso?")
        }
        event.alarms = alarmDate > Date() ? [EKAlarm(relativeOffset: TimeInterval(-value * 60))] : nil
    }

    private func resolve(_ op: AgendaOperation) throws -> AgendaItem {
        if op.target.hasPrefix("#") {
            guard let item = references.item(forPointer: op.target) else {
                throw AgendaError.missing("Esa opción ya no está disponible. Dime el nombre y el día de la cita.")
            }
            guard op.originalDay.isEmpty || op.originalDay == AgendaClock.dayString(item.start) else {
                throw AgendaError.missing("La opción y el día no coinciden. ¿Qué cita quieres cambiar?")
            }
            return item
        }
        if op.target.isEmpty, op.originalDay.isEmpty, let lastEvent = references.lastEvent { return lastEvent }
        // An explicit search replaces the previous referent even when no match exists.
        references.recordList([])
        let range = try queryRange(day: op.originalDay, through: "", defaultDays: op.originalDay.isEmpty ? 30 : 1)
        let events = try CalendarReader.load(start: range.start, end: range.end)
        let target = normalized(op.target)
        guard !target.isEmpty else { throw AgendaError.missing("¿Qué cita quieres cambiar? Dime su nombre y el día.") }
        let exact = events.filter { normalized($0.title) == target }
        if exact.count == 1 { return exact[0] }
        let contains = events.filter { normalized($0.title).contains(target) }
        if contains.count == 1 { return contains[0] }
        let words = target.split(separator: " ").filter { $0.count > 2 && !["con", "del", "las", "los", "una", "cita", "para"].contains(String($0)) }
        let matches = contains.isEmpty ? events.filter { event in
            !words.isEmpty && words.allSatisfy { normalized(event.title).contains($0) }
        } : contains
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty { throw AgendaError.notFound }
        references.recordList(matches)
        let choices = references.listedEvents.enumerated().map { "\($0.offset + 1). \($0.element.title), \(summaryDate($0.element.start))" }.joined(separator: "; ")
        throw AgendaError.ambiguous("Hay varias: \(choices). ¿Cuál de ellas?")
    }

    private func rawEvent(for item: AgendaItem) -> EKEvent? {
        let range = DateInterval(start: item.start.addingTimeInterval(-1), end: item.end.addingTimeInterval(1))
        return eventStore.events(matching: eventStore.predicateForEvents(withStart: range.start, end: range.end, calendars: nil))
            .first { CalendarReader.item($0).id == item.id }
    }

    private func validateConflicts(_ change: PreparedChange, allChanges: [PreparedChange]) throws {
        guard !change.allowOverlap else { return }
        let item = CalendarReader.item(change.event)
        guard item.blocksTime else { return }
        let modifiedIDs = Set(allChanges.compactMap { $0.before?.item.id })
        var others = try CalendarReader.load(start: item.start, end: item.end)
            .filter { !modifiedIDs.contains($0.id) && $0.blocksTime }
        others += allChanges.filter { !$0.isDeletion && $0.event !== change.event }.map { CalendarReader.item($0.event) }
        let conflicts = others.filter { $0.blocksTime && $0.start < item.end && $0.end > item.start }
        if let first = conflicts.first {
            throw AgendaError.ambiguous("\(item.title) se solaparía con \(first.title), \(summaryDate(first.start)). ¿Quieres mantener ese solape o buscar otro hueco?")
        }
    }

    private func queryRange(day: String, through: String, defaultDays: Int = 1) throws -> DateInterval {
        let start: Date
        if day.isEmpty { start = AgendaClock.calendar.startOfDay(for: .now) }
        else if let parsed = AgendaClock.day(day) { start = parsed }
        else { throw AgendaError.missing("No entiendo la fecha. ¿Qué día quieres consultar?") }
        let end: Date
        if !through.isEmpty {
            guard let finalDay = AgendaClock.day(through),
                  let exclusiveEnd = AgendaClock.calendar.date(byAdding: .day, value: 1, to: finalDay) else {
                throw AgendaError.missing("La fecha final no es válida.")
            }
            end = exclusiveEnd
        } else {
            guard let nextDay = AgendaClock.calendar.date(byAdding: .day, value: defaultDays, to: start) else {
                throw AgendaError.missing("No puedo calcular ese intervalo.")
            }
            end = nextDay
        }
        guard end > start, (AgendaClock.calendar.dateComponents([.day], from: start, to: end).day ?? 999) <= 366 else {
            throw AgendaError.missing("Consulta un intervalo de hasta un año.")
        }
        return DateInterval(start: start, end: end)
    }

    private func list(_ op: AgendaOperation) throws -> String {
        let range = try queryRange(day: op.day, through: op.throughDay)
        var events = try CalendarReader.load(start: range.start, end: range.end)
        if !op.target.isEmpty { events = events.filter { normalized($0.title).contains(normalized(op.target)) } }
        references.recordList(events)
        slots = []
        if events.isEmpty { return "No tienes citas en ese intervalo." }
        let lines = references.listedEvents.enumerated().map { index, event in
            "\(index + 1). \(event.title) · \(summaryDate(event.start))\(event.isAllDay ? " · todo el día" : "–" + AgendaClock.timeString(event.end))"
        }
        return lines.joined(separator: "\n") + (events.count > 12 ? "\nHay \(events.count - 12) citas más; acota los días para verlas." : "")
    }

    private func findFree(_ op: AgendaOperation) throws -> String {
        let range = try queryRange(day: op.day, through: op.throughDay)
        let days = AgendaClock.calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0
        guard days <= 31 else { throw AgendaError.missing("Busca huecos en un intervalo de hasta un mes.") }
        let duration = op.durationMinutes > 0 ? op.durationMinutes : 60
        let startHour = op.time.isEmpty ? 7 : Int(op.time.prefix(2)) ?? -1
        let endHourBase = op.endTime.isEmpty ? 23 : Int(op.endTime.prefix(2)) ?? -1
        let endMinute = op.endTime.isEmpty ? 0 : Int(op.endTime.suffix(2)) ?? -1
        let endHour = endHourBase + (endMinute > 0 ? 1 : 0)
        guard startHour >= 0, endHour <= 24, endHour > startHour, duration <= 24 * 60 else {
            throw AgendaError.missing("Indícame una duración y una franja horaria válida.")
        }
        let events = try CalendarReader.load(start: range.start, end: range.end)
        var found: [FreeSlot] = []
        var day = range.start
        let now = Date()
        while day < range.end {
            guard let exactStart = AgendaClock.date(day: AgendaClock.dayString(day), time: op.time.isEmpty ? "07:00" : op.time),
                  let exactEnd = AgendaClock.date(day: AgendaClock.dayString(day), time: op.endTime.isEmpty ? "23:00" : op.endTime),
                  exactEnd > exactStart else {
                throw AgendaError.missing("La franja horaria no es válida. Indica la hora de inicio y de final.")
            }
            let candidates = AgendaMath.freeSlots(on: day, events: events, minimumMinutes: duration,
                                                  startHour: startHour, endHour: endHour, calendar: AgendaClock.calendar)
            for slot in candidates {
                let start = max(slot.start, now, exactStart)
                let end = min(slot.end, exactEnd)
                if end.timeIntervalSince(start) >= Double(duration * 60) {
                    found.append(FreeSlot(start: start, end: end))
                }
            }
            guard let next = AgendaClock.calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        references.recordList([])
        slotDurationMinutes = duration
        slots = Array(found.prefix(12))
        if slots.isEmpty { return "No hay huecos de \(duration) minutos en esa franja." }
        return slots.enumerated().map { index, slot in
            "\(index + 1). Libre: \(summaryDate(slot.start))–\(AgendaClock.timeString(slot.end))"
        }.joined(separator: "\n")
    }

    private func undo(generation: UUID) throws -> String {
        try ensureCurrent(generation)
        guard !undoChanges.isEmpty else { return "No hay un cambio de esta sesión que pueda deshacer." }
        // Verifica que nadie haya modificado las citas desde la última operación.
        for change in undoChanges {
            if let after = change.after {
                guard let actual = rawEvent(for: after), CalendarReader.item(actual) == after,
                      actual.lastModifiedDate == change.modifiedAt else {
                    throw AgendaError.ambiguous("La cita ha cambiado fuera de esta operación. Revísala antes de deshacer.")
                }
                if change.before == nil, actual.hasRecurrenceRules {
                    throw AgendaError.unsupported("La creación es una serie. Toca la cita para eliminar la serie en Calendario.")
                }
            }
        }
        var lastRestored: EKEvent?
        for change in undoChanges.reversed() {
            try ensureCurrent(generation)
            if let before = change.before {
                let event = change.after.flatMap { rawEvent(for: $0) } ?? EKEvent(eventStore: eventStore)
                before.apply(to: event)
                if change.after == nil { event.recurrenceRules = before.recurrence }
                try eventStore.save(event, span: .thisEvent, commit: false)
                lastRestored = event
            } else if let after = change.after, let created = rawEvent(for: after) {
                try eventStore.remove(created, span: .thisEvent, commit: false)
                lastRestored = nil
            }
        }
        try ensureCurrent(generation)
        try eventStore.commit()
        references.recordMutation(lastRestored.map(CalendarReader.item))
        slots = []
        undoChanges = []
        return "Último cambio deshecho."
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func summaryDate(_ value: Date) -> String {
        value.formatted(.dateTime.locale(Locale(identifier: "es_ES")).weekday(.abbreviated).day().month(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}
