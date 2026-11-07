import AVFoundation
import Observation

/// Record your own voice while studying and play it back, to compare with
/// the card (Anki's "Record Own Voice", ⇧V, and "Replay Own Voice", V).
/// Recordings are temporary: one at a time, never saved to the card.
@MainActor
@Observable
final class OwnVoice {
    private(set) var isRecording = false
    private(set) var hasRecording = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?

    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("animus-own-voice.m4a")

    /// Starts recording, or stops and plays it back. Returns a message to show.
    func toggle() async -> String {
        if isRecording {
            recorder?.stop()
            recorder = nil
            isRecording = false
            hasRecording = true
            play()
            return "Playing your recording. Press V to hear it again."
        }
        guard await Self.micAllowed() else {
            return "Animus can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        }
        player?.stop()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: file, settings: settings)
            guard recorder.record() else { return "Couldn't start recording." }
            self.recorder = recorder
            isRecording = true
            return "Recording… press ⇧V again to stop."
        } catch {
            return "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    /// Plays the last recording. Returns false if there's none.
    @discardableResult func play() -> Bool {
        guard hasRecording, let player = try? AVAudioPlayer(contentsOf: file) else { return false }
        self.player = player
        player.play()
        return true
    }

    /// A new card: the old recording no longer applies.
    func reset() {
        recorder?.stop()
        recorder = nil
        player?.stop()
        isRecording = false
        hasRecording = false
        try? FileManager.default.removeItem(at: file)
    }

    private static func micAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
