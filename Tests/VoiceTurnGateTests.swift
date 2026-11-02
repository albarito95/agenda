import Foundation

@main
enum VoiceTurnGateTests {
    static func main() {
        var gate = VoiceTurnGate()
        let first = gate.begin()
        let tokens = [VoiceTurnGate.Token(text: "Dentista", confidence: 0.92), .init(text: "18:30", confidence: 0.93)]
        check(gate.receive(session: first, text: "Dentista 18:30", isFinal: false, tokens: tokens) == .ignored,
              "A partial transcription must never execute")
        gate.markInputFinished(session: first)
        check(gate.receive(session: first, text: "Dentista 18:30", isFinal: true, tokens: tokens) == .accepted("Dentista 18:30"),
              "A clear final result can be interpreted")
        check(gate.receive(session: first, text: "Dentista 18:30", isFinal: true, tokens: tokens) == .ignored,
              "Duplicate final callbacks must not create duplicate events")
        let second = gate.begin()
        check(gate.receive(session: first, text: "old", isFinal: true, tokens: tokens) == .ignored,
              "A callback from a previous session is stale")
        gate.cancel()
        check(gate.receive(session: second, text: "Dentista", isFinal: true, tokens: tokens) == .ignored,
              "Cancelled audio must not become a command")
        let unscored = gate.begin()
        gate.markInputFinished(session: unscored)
        check(gate.receive(session: unscored, text: "mañana a las seis", isFinal: true,
                           tokens: [.init(text: "mañana a las seis", confidence: 0)]) == .review("mañana a las seis"),
              "Absent confidence is not accuracy")
        let uncertainTime = gate.begin()
        gate.markInputFinished(session: uncertainTime)
        check(gate.receive(session: uncertainTime, text: "Dentista a las siete", isFinal: true,
                           tokens: [.init(text: "Dentista", confidence: 0.99), .init(text: "siete", confidence: 0.5)]) == .review("Dentista a las siete"),
              "A weak spoken time cannot hide in a high overall average")
        let uncertainNegation = gate.begin()
        gate.markInputFinished(session: uncertainNegation)
        check(gate.receive(session: uncertainNegation, text: "no la borres", isFinal: true,
                           tokens: [.init(text: "no", confidence: 0), .init(text: "la borres", confidence: 0.99)]) == .review("no la borres"),
              "A missing negation confidence requires review")
        let empty = gate.begin()
        gate.markInputFinished(session: empty)
        check(gate.receive(session: empty, text: "…", isFinal: true, tokens: []) == .review("…"),
              "Punctuation is not an instruction")
        check(gate.receive(session: empty, text: "Dentista", isFinal: true, tokens: tokens) == .ignored,
              "A reviewed final is terminal too")
        let interrupted = gate.begin()
        check(gate.receive(session: interrupted, text: "Dentista 18:30", isFinal: true, tokens: tokens) == .review("Dentista 18:30"),
              "A recognizer-internal finish must not execute a potentially cut-off phrase")
        gate.markInputFinished(session: interrupted)
        check(gate.receive(session: interrupted, text: "Dentista 18:30", isFinal: true, tokens: tokens) == .ignored,
              "Finishing later must not retroactively authorize an interrupted final")
        let finalWithError = gate.begin()
        gate.markInputFinished(session: finalWithError)
        check(gate.receive(session: finalWithError, text: "Dentista 18:30", isFinal: true, tokens: tokens,
                           recognitionFailed: true) == .review("Dentista 18:30"),
              "An error in the same callback must override a high-confidence final result")
        let partialWithError = gate.begin()
        check(gate.receive(session: partialWithError, text: "Dentista", isFinal: false, tokens: tokens,
                           recognitionFailed: true) == .review("Dentista"),
              "An interrupted partial must be retained only for manual review")
        gate.markInputFinished(session: partialWithError)
        check(gate.receive(session: partialWithError, text: "Dentista 18:30", isFinal: true, tokens: tokens) == .ignored,
              "A delayed final cannot resurrect an utterance that failed")

        var endpoint = VoiceEndpointPolicy(now: 0)
        endpoint.observeText("Cambia la cita", now: 1)
        for tick in 1...40 { endpoint.observeAudio(decibels: -24, now: Double(tick) / 10) }
        check(endpoint.action(now: 4) == .wait, "Delayed transcription while speech continues must not end the turn")
        endpoint.observeAudio(decibels: -65, now: 5)
        check(endpoint.action(now: 6.5) == .wait, "A short natural pause is tolerated")
        endpoint.observeText("Cambia la cita a las dieciocho", now: 6.4)
        check(endpoint.action(now: 7) == .wait, "Late text extends the turn even after acoustic silence")
        check(endpoint.action(now: 8.3) == .finish, "Quiet audio and settled text allow finalization")
        check(endpoint.action(now: 55) == .maximumDuration, "A bounded session cannot listen indefinitely")

        var fan = VoiceEndpointPolicy(now: 0)
        for tick in 1...100 { fan.observeAudio(decibels: -50, now: Double(tick) / 20) }
        fan.observeText("¿Qué tengo mañana?", now: 2)
        check(fan.action(now: 5) == .finish, "A steady quiet fan should not keep a completed turn open")
        let silent = VoiceEndpointPolicy(now: 0)
        check(silent.action(now: 11) == .wait, "Initial pause is tolerated")
        check(silent.action(now: 12) == .noSpeech, "Initial silence times out without a command")
        print("Voice turn and endpoint policy tests passed.")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
