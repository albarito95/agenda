import SwiftUI
import EventKit
import EventKitUI
import UIKit

@main
struct MiAgendaApp: App {
    @StateObject private var agenda = AgendaController()

    var body: some Scene {
        WindowGroup {
            AgendaScreen(agenda: agenda)
                .environment(\.locale, Locale(identifier: "es_ES"))
        }
    }
}

struct AgendaScreen: View {
    @ObservedObject var agenda: AgendaController
    @Environment(\.scenePhase) private var scenePhase
    @State private var assistantIsOpen = false
    @State private var eventIsOpen = false
    @State private var eventLinkExpired = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                if agenda.hasAccess, let message = agenda.calendarError {
                    ContentUnavailableView {
                        Label("No se pudo leer la agenda", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Reintentar") { agenda.refresh() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if agenda.hasAccess, dynamicTypeSize.isAccessibilitySize {
                    accessibleAgenda
                } else if agenda.hasAccess {
                    GeometryReader { geometry in
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            AgendaTimeline(items: agenda.items, date: timeline.date, compact: false) { item in
                                agenda.select(item)
                                eventIsOpen = agenda.selectedEvent != nil
                            }
                            .frame(height: max(420, geometry.size.height - 24))
                        }
                    }
                    .padding(.horizontal, 12)
                } else {
                    ContentUnavailableView {
                        Label("Tu día, de un vistazo", systemImage: "calendar")
                    } description: {
                        Text("Hoy y mañana, con tus citas y tus huecos. Los datos se consultan en tu iPhone.")
                    } actions: {
                        if EKEventStore.authorizationStatus(for: .event) == .denied {
                            Button("Abrir Ajustes") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Conectar mi agenda") { Task { await agenda.connect() } }
                                .buttonStyle(.borderedProminent)
                        }
                        if let message = agenda.calendarError {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Agenda")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                if agenda.hasAccess {
                    Button { assistantIsOpen = true } label: {
                        Image(systemName: "mic.fill")
                            .font(.title3)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Hablar con mi asistente")
                    .padding(.trailing, 18)
                    .padding(.bottom, 8)
                }
            }
        }
        .tint(Color(red: 0.16, green: 0.40, blue: 0.31))
        .task { agenda.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { agenda.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in agenda.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in agenda.refresh() }
        .onOpenURL { url in
            switch url.host {
            case "assistant": assistantIsOpen = true
            case "event":
                if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
                    eventIsOpen = agenda.openEvent(id: id)
                    eventLinkExpired = !eventIsOpen
                }
            default: break
            }
        }
        .sheet(isPresented: $assistantIsOpen) {
            AssistantSheet(agenda: agenda)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $eventIsOpen, onDismiss: { agenda.refresh() }) {
            if let event = agenda.selectedEvent {
                EventEditor(event: event, store: agenda.eventStore) { eventIsOpen = false }
            }
        }
        .alert("La cita ha cambiado", isPresented: $eventLinkExpired) {
            Button("Aceptar", role: .cancel) { }
        } message: {
            Text("Ese enlace ya no corresponde a una cita disponible. La agenda se ha actualizado; selecciona la cita desde aquí.")
        }
    }

    private var accessibleAgenda: some View {
        List {
            ForEach(0..<2) { offset in
                let calendar = AgendaClock.calendar
                let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now)) ?? .now
                let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let events = agenda.items.filter { $0.start < end && $0.end > day }
                Section(offset == 0 ? "Hoy" : "Mañana") {
                    ForEach(events) { item in
                        Button {
                            agenda.select(item)
                            eventIsOpen = agenda.selectedEvent != nil
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title.isEmpty ? "Sin título" : item.title).foregroundStyle(.primary)
                                Text(item.isAllDay ? "Todo el día" : AgendaClock.timeString(item.start) + "–" + AgendaClock.timeString(item.end))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if !item.blocksTime { Text("No bloquea tiempo").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    let free = AgendaMath.freeSlots(on: day, events: agenda.items, minimumMinutes: 30, calendar: calendar)
                    if !free.isEmpty {
                        Text("Huecos de al menos 30 minutos").font(.headline)
                        ForEach(free) { slot in
                            Text(AgendaClock.timeString(slot.start) + "–" + AgendaClock.timeString(slot.end))
                                .foregroundStyle(.secondary)
                        }
                    } else if events.isEmpty {
                        Text("Sin citas").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct EventEditor: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        editor.eventStore = store
        editor.event = event
        editor.editViewDelegate = context.coordinator
        return editor
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onDismiss()
        }
    }
}
