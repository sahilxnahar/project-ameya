import Foundation

/// Finds the bundled FFmpeg helper (`ameya-ffmpeg`), an LGPL build that runs as its own process.
///
/// The app and the worker live in `Ameya.app/Contents/MacOS/`, next to the helper, so both see the
/// same answer. Builds without the helper simply don't offer the formats that need it.
/// `AMEYA_FFMPEG` points at another copy, for tests and development.
public enum FFmpegAvailability {
    public static let executableName = "ameya-ffmpeg"
    public static let environmentKey = "AMEYA_FFMPEG"

    /// The helper to run, or nil when this build doesn't have one.
    public static var helperURL: URL? {
        if let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent(executableName)
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    public static var isAvailable: Bool { helperURL != nil }
}
