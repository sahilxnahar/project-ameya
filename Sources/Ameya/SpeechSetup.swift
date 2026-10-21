import Foundation
import Speech

/// Gets on-device speech recognition ready before a transcription job starts. Runs in the app,
/// because the sandboxed worker can neither show a permission prompt nor reach the network.
///
/// - macOS 26+: `SpeechTranscriber` needs no permission, but its language model is a system
///   asset. The app asks macOS to install it (macOS downloads it from Apple, not Ameya); no audio
///   is involved.
/// - macOS 14–25: `SFSpeechRecognizer` needs the user's permission, asked for here once.
enum SpeechSetup {
    /// Returns a message for the user if transcription can't run, or `nil` when ready.
    static func prepare(language: String?) async -> String? {
        let requested = language.map { Locale(identifier: $0) } ?? Locale.current
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                return nil // the worker reports the unsupported language
            }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            if await AssetInventory.status(forModules: [transcriber]) != .installed,
               let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await request.downloadAndInstall()
            }
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
