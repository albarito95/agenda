import Foundation

/// The only gate through which a recognized utterance may become a command.
/// It does not decide what the command means: the calendar layer must still
/// validate dates, resolve a real event and check collisions before saving.
struct VoiceTurnGate {
    struct Token: Equatable, Sendable {
        let text: String
        let confidence: Float
    }

    enum Decision: Equatable {
        case accepted(String)
        case review(String)
        case ignored
    }

    private var session: UUID?
    private var delivered = false
    private var inputFinished = false

    mutating func begin() -> UUID {
        let id = UUID()
        session = id
        delivered = false
        inputFinished = false
        return id
    }

    mutating func cancel() {
        session = nil
        delivered = false
        inputFinished = false
    }

    mutating func markInputFinished(session id: UUID) {
        guard session == id, !delivered else { return }
        inputFinished = true
    }

    mutating func receive(session id: UUID, text: String, isFinal: Bool, tokens: [Token], recognitionFailed: Bool = false) -> Decision {
        guard session == id, !delivered, isFinal || recognitionFailed else { return .ignored }
        // Consume even an unusable final result. A late second final must not
        // turn a failed or reviewed utterance into an automatic command.
        delivered = true
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some callbacks contain both a result and an error. A final flag must
        // never override that error, even when its confidence looks high.
        guard !recognitionFailed else { return .review(value) }
        // The recognizer can finish for its own internal limit or failure.
        // Only our user/endpoint-controlled finish authorizes execution.
        guard inputFinished else { return .review(value) }
        guard value.count <= 1_500,
              value.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            return .review(value)
        }
        let words = tokens.filter { token in
            token.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
        }
        guard !words.isEmpty else { return .review(value) }
        let calibrated = words.filter { $0.confidence.isFinite && $0.confidence > 0 && $0.confidence <= 1 }
        // Zero/missing confidence is not evidence of accuracy. In particular,
        // an unscored date, number or negation must be reviewed, not guessed.
        guard Double(calibrated.count) / Double(words.count) >= 0.75 else { return .review(value) }
        let average = calibrated.map { Double($0.confidence) }.reduce(0, +) / Double(calibrated.count)
        guard average >= 0.62,
              calibrated.allSatisfy({ $0.confidence >= 0.35 }),
              words.filter({ Self.containsCriticalWord($0.text) }).allSatisfy({
                  $0.confidence.isFinite && $0.confidence >= 0.65 && $0.confidence <= 1
              }) else { return .review(value) }
        return .accepted(value)
    }

    private static func containsCriticalWord(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) { return true }
        let critical: Set<String> = [
            "no", "sin", "borra", "borrar", "elimina", "eliminar", "cancela", "cancelar",
            "cero", "una", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve",
            "diez", "once", "doce", "trece", "catorce", "quince", "dieciseis", "diecisiete",
            "dieciocho", "diecinueve", "veinte", "veintiuno", "veintidos", "veintitres", "veinticuatro",
            "veinticinco", "veintiseis", "veintisiete", "veintiocho", "veintinueve", "treinta", "cuarenta",
            "cincuenta", "sesenta", "media", "cuarto", "menos", "antes", "despues",
            "hoy", "manana", "pasado", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo",
            "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre",
            "octubre", "noviembre", "diciembre"
        ]
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains { critical.contains($0) }
    }
}

/// Conservative end-of-turn heuristic, deliberately separate from recognition.
/// Transcription latency is not silence. Both acoustic quiet and stable text are
/// required. RMS is not a speech detector: steady loud noise can keep a turn
/// open, in which case the bounded session requires manual review.
struct VoiceEndpointPolicy {
    enum Action: Equatable { case wait, finish, noSpeech, maximumDuration }

    private let started: TimeInterval
    private var lastActivity: TimeInterval
    private var lastTextChange: TimeInterval
    private var text = ""
    private var levels: [Double] = []

    init(now: TimeInterval) {
        started = now
        lastActivity = now
        lastTextChange = now
    }

    mutating func observeAudio(decibels: Double, now: TimeInterval) {
        guard decibels.isFinite, now >= started else { return }
        let level = max(-100, min(0, decibels))
        levels.append(level)
        if levels.count > 100 { levels.removeFirst(levels.count - 100) }
        let ordered = levels.sorted()
        let floor = ordered[max(0, (ordered.count - 1) / 5)]
        // The cap is intentional: loud speech must not become its own noise
        // floor. Quiet rooms still detect a soft voice above background.
        let threshold = max(-52, min(-36, floor + 10))
        if level > threshold { lastActivity = now }
    }

    mutating func observeText(_ value: String, now: TimeInterval) {
        guard value != text else { return }
        text = value
        lastTextChange = now
    }

    func action(now: TimeInterval) -> Action {
        if now - started >= 55 { return .maximumDuration }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return now - started >= 12 ? .noSpeech : .wait
        }
        guard now - started >= 3,
              now - lastActivity >= 2.6,
              now - lastTextChange >= 1.8 else { return .wait }
        return .finish
    }
}
