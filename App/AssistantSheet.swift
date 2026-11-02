import SwiftUI

/// One turn at a time. Dismissing the sheet ends both capture and interpretation.
@MainActor
struct AssistantSheet: View {
    @ObservedObject var agenda: AgendaController
    @StateObject private var voice = AgendaVoiceSession()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var isVisible = false
    @State private var interactionID = UUID()
    @State private var operationTask: Task<Void, Never>?
    @FocusState private var isEditing: Bool

    private var cleanDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isCapturing: Bool { voice.phase == .listening || voice.phase == .finishing }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(status).font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar asistente")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let unavailable = agenda.intelligenceMessage {
                        Text(unavailable).foregroundStyle(.secondary)
                    }
                    if isCapturing, !voice.transcript.isEmpty {
                        Text(voice.transcript)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if !agenda.lastRequest.isEmpty {
                            Text(agenda.lastRequest).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if agenda.isWorking {
                            ProgressView("Revisando tu agenda…")
                        } else if !agenda.response.isEmpty {
                            Text(agenda.response).font(.body).textSelection(.enabled)
                        } else if voice.phase == .listening {
                            Text("Te escucho.").font(.title2.weight(.medium))
                            Text("Puedes hablar con naturalidad.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let message = voice.errorMessage {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                        if voice.phase == .failed, agenda.intelligenceMessage == nil {
                            Button("Volver a decirlo", systemImage: "mic") { beginListening() }
                                .font(.subheadline)
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)

            HStack(alignment: .bottom, spacing: 12) {
                TextField("Dime qué necesitas", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                    .focused($isEditing)
                    .submitLabel(.send)
                    .onSubmit { submit(draft, spoken: false) }
                    .disabled(agenda.isWorking)
                    .accessibilityLabel("Petición de agenda")
                    .accessibilityHint("Alternativa a la voz. Permite revisar y corregir una frase antes de enviarla.")
                Button(action: primaryAction) {
                    Image(systemName: primarySymbol)
                        .font(.title3.weight(.semibold))
                        .frame(width: 50, height: 50)
                        .foregroundStyle(.white)
                        .background(agenda.isWorking || isCapturing ? Color.red : Color(red: 0.16, green: 0.40, blue: 0.31), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(voice.phase == .requestingPermission || (agenda.intelligenceMessage != nil && !agenda.isWorking && !isCapturing))
                .accessibilityLabel(primaryLabel)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .onAppear(perform: open)
        .onDisappear(perform: close)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && voice.phase != .requestingPermission) {
                suspend()
            }
        }
        .onChange(of: isEditing) { _, editing in
            guard editing else { return }
            if isCapturing, cleanDraft.isEmpty { draft = voice.transcript }
            voice.stop()
        }
        .onChange(of: voice.phase) { _, phase in
            if phase == .failed, !voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = voice.transcript
            }
        }
    }

    private var status: String {
        if agenda.isWorking { return "Organizando" }
        switch voice.phase {
        case .requestingPermission: return "Preparando la voz"
        case .listening: return "Te escucho"
        case .finishing: return "Terminando de escuchar"
        case .speaking: return "Tu agenda"
        case .failed: return "Revisa tu petición"
        case .idle: return agenda.needsClarification ? "Una aclaración" : "Tu asistente"
        }
    }

    private var primarySymbol: String {
        if agenda.isWorking || voice.phase == .finishing { return "xmark" }
        if voice.phase == .listening { return "stop.fill" }
        if voice.phase == .speaking { return "mic.fill" }
        return cleanDraft.isEmpty ? "mic.fill" : "arrow.up"
    }

    private var primaryLabel: String {
        if agenda.isWorking { return "Cancelar petición pendiente" }
        switch voice.phase {
        case .listening: return "Terminar de hablar"
        case .finishing: return "Cancelar escucha"
        case .speaking: return "Interrumpir y hablar"
        default: return cleanDraft.isEmpty ? "Hablar" : "Enviar petición revisada"
        }
    }

    private func open() {
        guard !isVisible else { return }
        isVisible = true
        interactionID = UUID()
        voice.onFinalTranscript = { text in
            guard isVisible, scenePhase == .active, !isEditing else { return }
            submit(text, spoken: true)
        }
        if agenda.intelligenceMessage == nil { beginListening() }
    }

    private func primaryAction() {
        if agenda.isWorking || voice.phase == .finishing { suspend(); return }
        if voice.phase == .listening { voice.finish(); return }
        if voice.phase == .speaking {
            beginListening()
            return
        }
        if !cleanDraft.isEmpty { submit(draft, spoken: false) }
        else { beginListening() }
    }

    private func beginListening() {
        guard isVisible, scenePhase == .active, !agenda.isWorking,
              agenda.intelligenceMessage == nil else { return }
        isEditing = false
        draft = ""
        operationTask?.cancel()
        voice.stop()
        let id = UUID()
        interactionID = id
        operationTask = Task { @MainActor in
            // Let the focus update settle before capture begins.
            await Task.yield()
            guard !Task.isCancelled, isVisible, interactionID == id, scenePhase == .active else { return }
            await voice.start(contextualStrings: agenda.voiceVocabulary)
        }
    }

    private func submit(_ text: String, spoken: Bool) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isVisible, scenePhase == .active, !agenda.isWorking,
              !value.isEmpty, agenda.intelligenceMessage == nil else { return }
        operationTask?.cancel()
        voice.stop()
        isEditing = false
        draft = ""
        let id = UUID()
        interactionID = id
        operationTask = Task { @MainActor in
            guard !Task.isCancelled, isVisible, interactionID == id else { return }
            await agenda.send(value)
            guard !Task.isCancelled, isVisible, interactionID == id, scenePhase == .active else { return }
            if spoken {
                voice.speak(spokenReply(agenda.response), thenListen: agenda.needsClarification)
            }
        }
    }

    private func spokenReply(_ text: String) -> String {
        if agenda.needsClarification { return text }
        let lines = text.split(separator: "\n").map(String.init)
        if lines.count <= 3 { return text }
        return lines.prefix(3).joined(separator: ". ") + ". Tienes el resto en pantalla."
    }

    private func suspend() {
        interactionID = UUID()
        operationTask?.cancel()
        operationTask = nil
        voice.stop()
        agenda.cancelCurrentRequest()
    }

    private func close() {
        isVisible = false
        voice.onFinalTranscript = nil
        suspend()
    }
}
