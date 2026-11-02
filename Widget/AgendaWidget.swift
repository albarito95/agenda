import Foundation
import SwiftUI
import WidgetKit

private enum AgendaWidgetState {
    case ready([AgendaItem])
    case needsAccess
    case unavailable
    case stale([AgendaItem])
    case outdated
}

private struct AgendaWidgetEntry: TimelineEntry {
    let date: Date
    let updatedAt: Date
    let state: AgendaWidgetState
}

private struct AgendaWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaWidgetEntry {
        AgendaWidgetEntry(date: Date(), updatedAt: Date(), state: .needsAccess)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgendaWidgetEntry) -> Void) {
        completion(readEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaWidgetEntry>) -> Void) {
        let now = Date()
        let initial = readEntry(at: now)
        let calendar = AgendaClock.calendar
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(900)
        let refresh = min(now.addingTimeInterval(15 * 60), midnight)
        var entries = [initial]
        for offset in [5.0, 10.0] {
            let next = now.addingTimeInterval(offset * 60)
            if next < refresh {
                entries.append(AgendaWidgetEntry(date: next, updatedAt: initial.updatedAt, state: initial.state))
            }
        }
        // iOS may delay the requested reload. A fallback entry never promotes
        // yesterday's cached appointments to today's apparently empty calendar.
        if case .ready(let items) = initial.state {
            let staleAt = now.addingTimeInterval(45 * 60)
            if staleAt < midnight {
                entries.append(AgendaWidgetEntry(date: staleAt, updatedAt: initial.updatedAt, state: .stale(items)))
            }
            entries.append(AgendaWidgetEntry(date: midnight, updatedAt: initial.updatedAt, state: .outdated))
        }
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }

    private func readEntry(at date: Date) -> AgendaWidgetEntry {
        guard CalendarReader.isAuthorized else {
            return AgendaWidgetEntry(date: date, updatedAt: date, state: .needsAccess)
        }
        do {
            return AgendaWidgetEntry(date: date, updatedAt: date, state: .ready(try CalendarReader.loadTwoDays(now: date)))
        } catch {
            return AgendaWidgetEntry(date: date, updatedAt: date, state: .unavailable)
        }
    }
}

private struct AgendaWidgetContent: View {
    let entry: AgendaWidgetEntry

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Mi agenda").font(.headline)
                Spacer()
                Link(destination: URL(string: "miagenda://assistant")!) {
                    Image(systemName: "mic.fill")
                        .font(.body.weight(.medium))
                        .frame(width: 30, height: 26)
                }
                .accessibilityLabel("Hablar con mi asistente de agenda")
            }
            switch entry.state {
            case .ready(let items):
                agenda(items, stale: false)
            case .stale(let items):
                agenda(items, stale: true)
            case .needsAccess:
                message("Conecta tu calendario", detail: "Abre Agenda para permitir el acceso.")
            case .unavailable:
                message("No se pudo actualizar", detail: "Toca para comprobar el calendario.")
            case .outdated:
                message("Abre para actualizar", detail: "Última lectura: " + AgendaClock.timeString(entry.updatedAt) + ". Tus citas pueden haber cambiado.")
            }
        }
        .widgetURL(URL(string: "miagenda://today")!)
        .containerBackground(.background, for: .widget)
    }

    private func agenda(_ items: [AgendaItem], stale: Bool) -> some View {
        VStack(spacing: 5) {
            AgendaTimeline(items: items, date: entry.date, compact: true)
            HStack {
                Spacer()
                Text((stale ? "Comprueba cambios · " : "Actualizada ") + AgendaClock.timeString(entry.updatedAt))
                    .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 12)
    }
}

@main
struct MiAgendaWidget: Widget {
    let kind = "MiAgendaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgendaWidgetProvider()) { entry in
            AgendaWidgetContent(entry: entry)
        }
        .configurationDisplayName("Hoy y mañana")
        .description("Tus dos días por horas, con colores por calendario y huecos visibles.")
        .supportedFamilies([.systemLarge])
    }
}
