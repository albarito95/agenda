import Foundation
import Combine
import Speech
import AVFoundation

enum VoicePhase: Equatable {
    case idle, requestingPermission, listening, finishing, speaking, failed
}

/// A foreground, explicitly opened voice session. No audio is written to disk
/// or sent to an external API. All calendar execution belongs to the caller.
@MainActor
final class AgendaVoiceSession: NSObject, ObservableObject {
    @Published private(set) var phase: VoicePhase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    var onFinalTranscript: ((String) -> Void)?
    var isActive: Bool {
        [.requestingPermission, .listening, .finishing, .speaking].contains(phase)
    }

    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var gate = VoiceTurnGate()
    private var endpoint: VoiceEndpointPolicy?
    private var session: UUID?
    private var generation = UUID()
    private var timer: Task<Void, Never>?
    private var finalizationTimer: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var vocabulary: [String] = []
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var listenAfterSpeech = false
    private var configuringAudio = false

    override init() {
        super.init()
        synthesizer.delegate = self
        observeAudioChanges()
    }

    deinit {
        timer?.cancel()
        finalizationTimer?.cancel()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    func start(contextualStrings: [String] = []) async {
        // Idempotent while permission UI is outstanding; a second tap must not
        // issue duplicate system prompts or create two audio engines.
        guard phase != .requestingPermission else { return }
        stop()
        transcript = ""
        vocabulary = Array(contextualStrings.filter { !$0.isEmpty }.prefix(60))
        let id = gate.begin()
        session = id
        generation = id
        phase = .requestingPermission

        let permission = await speechPermission()
        guard isCurrent(id), !Task.isCancelled else { abandonIfCurrent(id); return }
        guard permission == .authorized else {
            fail(permission == .restricted
                 ? "El reconocimiento de voz está restringido en este iPhone. Puedes usar el texto."
                 : "Permite el reconocimiento de voz en Ajustes > Agenda para hablar con el asistente.")
            return
        }
        let microphoneAllowed = await microphonePermission()
        guard isCurrent(id), !Task.isCancelled else { abandonIfCurrent(id); return }
        guard microphoneAllowed else {
            fail("Permite el micrófono en Ajustes > Agenda para hablar con el asistente.")
            return
        }
        guard let speech = SFSpeechRecognizer(locale: Locale(identifier: "es_ES")),
              speech.supportsOnDeviceRecognition else {
            fail("El reconocimiento local en español no está disponible en este iPhone. Puedes escribir la petición.")
            return
        }
        guard speech.isAvailable else {
            fail("La voz no está disponible ahora. Vuelve a tocar el micrófono o escribe tu petición.")
            return
        }

        do {
            try configureRecordingAudio()
            guard isCurrent(id), !Task.isCancelled else { abandonIfCurrent(id); return }
            let audioEngine = AVAudioEngine()
            let audioRequest = SFSpeechAudioBufferRecognitionRequest()
            audioRequest.requiresOnDeviceRecognition = true
            audioRequest.shouldReportPartialResults = true
            audioRequest.addsPunctuation = true
            audioRequest.taskHint = .dictation
            audioRequest.contextualStrings = vocabulary
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceError.noInput
            }
            recognizer = speech
            recognizer?.delegate = self
            engine = audioEngine
            request = audioRequest
            endpoint = VoiceEndpointPolicy(now: ProcessInfo.processInfo.systemUptime)

            recognitionTask = speech.recognitionTask(with: audioRequest) { [weak self] result, error in
                // Copy values before crossing to the main actor; no AVAudio
                // buffers or mutable recognition objects cross this boundary.
                let value = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let tokens = result?.bestTranscription.segments.map {
                    VoiceTurnGate.Token(text: $0.substring, confidence: $0.confidence)
                } ?? []
                let failed = error != nil
                Task { @MainActor [weak self] in
                    self?.received(value, isFinal: final, tokens: tokens, failed: failed, session: id)
                }
            }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                audioRequest.append(buffer)
                let level = Self.decibels(buffer)
                let capturedAt = ProcessInfo.processInfo.systemUptime
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(id), self.phase == .listening else { return }
                    self.endpoint?.observeAudio(decibels: level, now: capturedAt)
                }
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            phase = .listening
            startTimer(session: id)
        } catch {
            fail("No puedo iniciar el micrófono. Comprueba la conexión de los auriculares y vuelve a intentarlo.")
        }
    }

    /// Ends input, then waits for the recognizer's final result. A displayed
    /// partial transcription is never promoted to final by a timer or button.
    func finish() {
        guard phase == .listening, let id = session else { return }
        phase = .finishing
        gate.markInputFinished(session: id)
        timer?.cancel()
        timer = nil
        stopInput()
        request?.endAudio()
        finalizationTimer?.cancel()
        finalizationTimer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, self.isCurrent(id), self.phase == .finishing else { return }
            self.fail("No he recibido la frase completa. Revisa el texto o vuelve a decirlo.")
        }
    }

    /// Invalidates every pending callback before releasing audio resources.
    /// Keeps the transcript so a failed utterance can be reviewed in the sheet.
    func stop() {
        generation = UUID()
        session = nil
        gate.cancel()
        listenAfterSpeech = false
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        releaseRecognition()
        deactivateAudio()
        errorMessage = nil
        phase = .idle
    }

    func speak(_ text: String, thenListen: Bool = false) {
        stop()
        // The caller already displays the executed request. Keeping it here
        // would make a playback failure look like an unsent voice draft.
        transcript = ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try configurePlaybackAudio()
            let spoken = Self.shortSpokenReply(value)
            let utterance = AVSpeechUtterance(string: spoken)
            utterance.voice = AVSpeechSynthesisVoice(language: "es-ES")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.postUtteranceDelay = 0.15
            currentUtterance = utterance
            listenAfterSpeech = thenListen
            phase = .speaking
            synthesizer.speak(utterance)
        } catch {
            fail("La respuesta está en pantalla. Ahora no puedo reproducirla en voz alta.")
        }
    }

    func interruptAndListen() async {
        let context = vocabulary
        stop()
        await start(contextualStrings: context)
    }

    private func isCurrent(_ id: UUID) -> Bool { session == id && generation == id }

    private func abandonIfCurrent(_ id: UUID) {
        if isCurrent(id) { stop() }
    }

    private func received(_ value: String?, isFinal: Bool, tokens: [VoiceTurnGate.Token], failed: Bool, session id: UUID) {
        guard isCurrent(id), phase == .listening || phase == .finishing else { return }
        if let value {
            transcript = value
            endpoint?.observeText(value, now: ProcessInfo.processInfo.systemUptime)
        }
        if failed {
            _ = gate.receive(session: id, text: transcript, isFinal: isFinal, tokens: tokens, recognitionFailed: true)
            fail(transcript.isEmpty
                 ? "No he podido escucharte. Toca el micrófono y vuelve a intentarlo."
                 : "La escucha se ha interrumpido. Revisa el texto o vuelve a decirlo.")
            return
        }
        if let value {
            if isFinal {
                switch gate.receive(session: id, text: value, isFinal: true, tokens: tokens) {
                case .accepted(let command):
                    // Invalidate before invoking client code; duplicate finals
                    // or error callbacks cannot race the calendar operation.
                    session = nil
                    generation = UUID()
                    releaseRecognition()
                    deactivateAudio()
                    phase = .idle
                    onFinalTranscript?(command)
                case .review:
                    if phase == .listening {
                        fail("La escucha ha terminado antes de tiempo. Revisa el texto antes de enviarlo.")
                    } else {
                        fail(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "No he oído una petición. Toca el micrófono y vuelve a intentarlo."
                             : "No lo he oído con suficiente claridad. Revisa el texto antes de enviarlo.")
                    }
                case .ignored:
                    break
                }
                return
            }
        }
    }

    private func startTimer(session id: UUID) {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, self.isCurrent(id), self.phase == .listening else { return }
                switch self.endpoint?.action(now: ProcessInfo.processInfo.systemUptime) ?? .wait {
                case .wait: break
                case .finish: self.finish(); return
                case .noSpeech:
                    self.fail("No he oído una petición. Toca el micrófono cuando quieras hablar.")
                    return
                case .maximumDuration:
                    // A hard cap can interrupt speech. It must never execute a
                    // fragment, even if recognition subsequently marks it final.
                    self.fail("La petición es larga. Revisa el texto o divídela en dos peticiones.")
                    return
                }
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        errorMessage = message
        phase = .failed
    }

    private func stopInput() {
        if let engine {
            engine.stop()
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
        }
    }

    private func releaseRecognition() {
        timer?.cancel()
        timer = nil
        finalizationTimer?.cancel()
        finalizationTimer = nil
        stopInput()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer?.delegate = nil
        recognizer = nil
        engine = nil
        endpoint = nil
    }

    private func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let existing = SFSpeechRecognizer.authorizationStatus()
        guard existing == .notDetermined else { return existing }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func microphonePermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    private func configureRecordingAudio() throws {
        configuringAudio = true
        defer { configuringAudio = false }
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)
        #endif
    }

    private func configurePlaybackAudio() throws {
        configuringAudio = true
        defer { configuringAudio = false }
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try audio.setActive(true)
        #endif
    }

    private func deactivateAudio() {
        configuringAudio = true
        defer { configuringAudio = false }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func observeAudioChanges() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, let changed = note.object as? AVAudioEngine,
                      changed === self.engine, self.phase == .listening || self.phase == .finishing else { return }
                self.fail("Ha cambiado el micrófono. Revisa el texto o vuelve a hablar.")
            }
        })
        #if os(iOS)
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, raw == AVAudioSession.InterruptionType.began.rawValue, self.isActive else { return }
                self.fail("El audio se ha interrumpido. Toca el micrófono para continuar.")
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let self, !self.configuringAudio, self.isActive,
                      raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.fail("Se han desconectado los auriculares. Toca el micrófono para continuar.")
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.fail("El audio se ha reiniciado. Toca el micrófono para continuar.")
            }
        })
        #endif
    }

    nonisolated private static func decibels(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        let count = Int(buffer.frameLength)
        let stride = Int(buffer.stride)
        var sum = 0.0
        for index in 0..<count {
            let value = Double(samples[index * stride])
            sum += value * value
        }
        return 20 * log10(max(0.000_01, sqrt(sum / Double(count))))
    }

    private static func shortSpokenReply(_ text: String) -> String {
        guard text.count > 650 else { return text }
        let firstLines = text.split(separator: "\n").prefix(3).joined(separator: ". ")
        let prefix = String(firstLines.prefix(550))
        return prefix + ". Tienes el resto en pantalla."
    }
}

extension AgendaVoiceSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.currentUtterance === utterance, self.phase == .speaking else { return }
            let shouldListen = self.listenAfterSpeech
            let cycle = self.generation
            let context = self.vocabulary
            self.currentUtterance = nil
            self.listenAfterSpeech = false
            self.phase = .idle
            self.deactivateAudio()
            if shouldListen {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == cycle, self.phase == .idle else { return }
                    await self.start(contextualStrings: context)
                }
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.stop()
        }
    }
}

extension AgendaVoiceSession: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self, !available, self.recognizer === speechRecognizer,
                  self.phase == .listening || self.phase == .finishing else { return }
            self.fail("El reconocimiento local se ha detenido. Revisa el texto o vuelve a hablar.")
        }
    }
}

private enum VoiceError: Error { case noInput }
