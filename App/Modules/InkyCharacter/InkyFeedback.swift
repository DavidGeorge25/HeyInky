import AudioToolbox
import Foundation
import UIKit

/// Haptics and subtle sounds for Inky's moments. Sounds can be turned off with the
/// "Inky Sounds" toggle (`soundsKey` in UserDefaults, on by default).
///
/// Haptics: Apple Pencil Pro (`UICanvasFeedbackGenerator`) on iPad, the Taptic Engine elsewhere.
/// Sounds: tiny tones synthesized once into Caches and played as system sounds, so they mix
/// with everything, follow the system alert volume and never touch the speech audio session.
@MainActor
enum InkyFeedback {
    enum Cue: String, CaseIterable, Sendable {
        /// Inky summoned.
        case summon
        /// Question sent.
        case send
        /// Inky lands on the page to draw.
        case land
        /// Inky finished acting on the page.
        case done
        /// Something went wrong.
        case error
    }

    static let soundsKey = "InkySoundsEnabled"

    static var soundsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundsKey) }
    }

    /// Cues played so far (tests).
    private(set) static var log: [Cue] = []

    static func play(_ cue: Cue) {
        log.append(cue)
        if log.count > 50 { log.removeFirst() }
        haptic(cue)
        if soundsEnabled { InkySounds.play(cue) }
    }

    private static func haptic(_ cue: Cue) {
        switch cue {
        case .summon, .send:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
            pencil { $0.alignmentOccurred(at: $1) }
        case .land:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.4)
        case .done:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            pencil { $0.pathCompleted(at: $1) }
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    /// Apple Pencil Pro haptics (only felt while the pencil is in hand).
    private static func pencil(_ body: (UICanvasFeedbackGenerator, CGPoint) -> Void) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let generator = UICanvasFeedbackGenerator(view: window)
        body(generator, CGPoint(x: window.bounds.midX, y: window.bounds.midY))
    }
}

/// Synthesized tones. Each is a few hundred milliseconds of soft sine partials.
@MainActor
enum InkySounds {
    private static var ids: [InkyFeedback.Cue: SystemSoundID] = [:]

    static func play(_ cue: InkyFeedback.Cue) {
        if let id = ids[cue] ?? load(cue) {
            AudioServicesPlaySystemSound(id)
        }
    }

    private static func load(_ cue: InkyFeedback.Cue) -> SystemSoundID? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("InkySounds", isDirectory: true)
        let url = folder.appendingPathComponent("\(cue.rawValue)-v1.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? wav(samples(for: cue)).write(to: url, options: .atomic)) != nil else { return nil }
        }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        ids[cue] = id
        return id
    }

    static let sampleRate = 44_100.0

    /// A note: frequency glide, start time, length, loudness.
    struct Note {
        var from: Double
        var to: Double
        var start: Double
        var length: Double
        var gain: Double
    }

    static func notes(for cue: InkyFeedback.Cue) -> [Note] {
        switch cue {
        case .summon: [Note(from: 740, to: 990, start: 0, length: 0.11, gain: 0.16)]
        case .send: [Note(from: 1320, to: 1250, start: 0, length: 0.05, gain: 0.09)]
        case .land: [Note(from: 520, to: 360, start: 0, length: 0.07, gain: 0.1)]
        case .done: [Note(from: 1047, to: 1047, start: 0, length: 0.32, gain: 0.1),
                     Note(from: 1568, to: 1568, start: 0.09, length: 0.38, gain: 0.09)]
        case .error: [Note(from: 392, to: 392, start: 0, length: 0.16, gain: 0.1),
                      Note(from: 330, to: 330, start: 0.12, length: 0.22, gain: 0.1)]
        }
    }

    static func samples(for cue: InkyFeedback.Cue) -> [Float] {
        let notes = notes(for: cue)
        let total = notes.map { $0.start + $0.length }.max() ?? 0
        var out = [Float](repeating: 0, count: Int(total * sampleRate) + 1)
        for note in notes {
            let first = Int(note.start * sampleRate)
            let count = Int(note.length * sampleRate)
            var phase = 0.0
            for i in 0..<count where first + i < out.count {
                let t = Double(i) / sampleRate
                let progress = t / note.length
                let frequency = note.from + (note.to - note.from) * progress
                phase += 2 * .pi * frequency / sampleRate
                let attack = min(1, t / 0.004)
                let decay = exp(-5 * progress)
                // Fundamental plus a quiet octave for a soft, round "ink" tone.
                let value = (sin(phase) + 0.18 * sin(2 * phase)) * attack * decay * note.gain
                out[first + i] += Float(value)
            }
        }
        return out
    }

    /// 16-bit mono PCM WAV.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for s in samples { append(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}
