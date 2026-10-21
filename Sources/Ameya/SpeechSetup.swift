import Foundation
import Speech

/// Gets on-device speech recognition ready before a transcription job starts. Runs in the app,
/// because the sandboxed worker can't show a permission prompt.
///
/// - macOS 26+: `SpeechTranscriber` needs no permission. Ameya only uses language models that
///   are already on the Mac and never asks macOS to download one; the worker reports a missing
///   language with instructions.
/// - macOS 14–25: `SFSpeechRecognizer` needs the user's permission, asked for here once.
enum SpeechSetup {
    /// Returns a message for the user if transcription can't run, or `nil` when ready.
    static func prepare(language: String?) async -> String? {
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            return nil
        }

        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        switch status {
        case .authorized:
            return nil
        case .restricted:
            return "Speech recognition is restricted on this Mac."
        default:
            return "Ameya isn't allowed to use speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition."
        }
    }
}
