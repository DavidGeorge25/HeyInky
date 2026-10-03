import AVFoundation
import Observation

/// Voice out: reads sidebar explanations aloud with AVSpeechSynthesizer.
@MainActor
@Observable
final class SpeechOutput {
    private(set) var isSpeaking = false
    private(set) var isPaused = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let delegate = Delegate()

    init() {
        synthesizer.delegate = delegate
        delegate.onFinish = { [weak self] in
            // A cancel from `stop()` can arrive after a new utterance started.
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.isSpeaking = false
            self.isPaused = false
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

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in self.onFinish?() }
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor in self.onFinish?() }
        }
    }
}
