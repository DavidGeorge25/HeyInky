import AVFoundation
import Observation

/// Voice out: reads sidebar explanations aloud with AVSpeechSynthesizer.
@MainActor
@Observable
final class SpeechOutput {
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    /// 0…1: how far the synthesizer has actually got (word callbacks), so "it's playing" is observable.
    private(set) var progress: Double = 0

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let delegate = Delegate()
    /// Narration in progress (`speakAndWait`): the utterance and who's waiting for it.
    @ObservationIgnored private var narration: (id: ObjectIdentifier, done: CheckedContinuation<Void, Never>)?

    init() {
        synthesizer.delegate = delegate
        delegate.onUtteranceEnded = { [weak self] id in
            guard let self, let narration = self.narration, narration.id == id else { return }
            self.narration = nil
            narration.done.resume()
        }
        delegate.onFinish = { [weak self] in
            // A cancel from `stop()` can arrive after a new utterance started.
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.isSpeaking = false
            self.isPaused = false
        }
        delegate.onProgress = { [weak self] fraction in
            guard let self, self.isSpeaking else { return }
            self.progress = fraction
        }
    }

    func speak(markdown: String) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        let utterance = AVSpeechUtterance(string: MarkdownText.plainText(markdown))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en")
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
        progress = 0
    }

    /// Speaks `text` and returns when it has been said (or after a generous timeout, so a
    /// performance never stalls when audio isn't available).
    func speakAndWait(_ text: String) async {
        let plain = MarkdownText.plainText(text)
        guard !plain.isEmpty else { return }
        stop()
        if let pending = narration { narration = nil; pending.done.resume() }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        let utterance = AVSpeechUtterance(string: plain)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en")
        let id = ObjectIdentifier(utterance)
        isSpeaking = true
        isPaused = false
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            narration = (id, done)
            synthesizer.speak(utterance)
            let timeout = 2.5 + Double(plain.count) * 0.09
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let pending = self.narration, pending.id == id else { return }
                self.narration = nil
                pending.done.resume()
            }
        }
    }

    /// Play/pause button behaviour.
    func toggle(markdown: String) {
        if !isSpeaking {
            speak(markdown: markdown)
        } else if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isPaused = false
    }

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        @MainActor var onFinish: (() -> Void)?
        @MainActor var onUtteranceEnded: ((ObjectIdentifier) -> Void)?
        @MainActor var onProgress: ((Double) -> Void)?

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
            let total = max((utterance.speechString as NSString).length, 1)
            let fraction = Double(characterRange.location + characterRange.length) / Double(total)
            Task { @MainActor in self.onProgress?(fraction) }
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            let id = ObjectIdentifier(utterance)
            Task { @MainActor in self.onUtteranceEnded?(id); self.onFinish?() }
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            let id = ObjectIdentifier(utterance)
            Task { @MainActor in self.onUtteranceEnded?(id); self.onFinish?() }
        }
    }
}
