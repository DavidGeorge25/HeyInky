import AVFoundation
import Observation
import Speech

/// Voice in: on-device speech recognition (Speech framework) from the microphone.
@MainActor
@Observable
final class SpeechInput {
    private(set) var isListening = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var onText: ((String) -> Void)?

    func start(onText: @escaping (String) -> Void) {
        guard !isListening else { return }
        self.onText = onText
        errorMessage = nil
        isListening = true
        Task {
            guard await Self.requestPermissions() else {
                fail("Allow microphone and speech recognition in Settings to ask out loud.")
                return
            }
            guard isListening else { return }
            do {
                try begin()
            } catch {
                fail("Couldn't start listening: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func begin() throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SpeechError.unavailable
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = InkyVoiceHints.contextualStrings
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(request))
        engine.prepare()
        try engine.start()

        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler(owner: self))
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let text, !text.isEmpty { onText?(text) }
        if isFinal || failed { stop() }
    }

    private func fail(_ message: String) {
        errorMessage = message
        stop()
    }

    // Closures handed to audio/speech callbacks must not be main-actor isolated: they run
    // on background queues. Building them in nonisolated static functions guarantees that.

    nonisolated private static func makeTapBlock(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func makeResultHandler(owner: SpeechInput) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in owner?.handle(text: text, isFinal: isFinal, failed: failed) }
        }
    }

    nonisolated private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    enum SpeechError: LocalizedError {
        case unavailable, noMicrophone
        var errorDescription: String? {
            switch self {
            case .unavailable: "Speech recognition isn't available right now."
            case .noMicrophone: "No microphone is available."
            }
        }
    }
}
