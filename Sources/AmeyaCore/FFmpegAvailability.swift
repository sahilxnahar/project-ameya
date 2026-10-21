import Foundation

/// Finds the bundled FFmpeg helper (`ameya-ffmpeg`), an LGPL build that runs as its own process.
///
/// The helper sits next to the worker in `AmeyaLauncher.xpc/Contents/MacOS/`; the app looks there
/// too, so both see the same answer. Builds without it simply don't offer the formats that need it.
/// In DEBUG builds `AMEYA_FFMPEG` points at another copy, for tests and development. Release
/// builds ignore it: the worker only ever runs the helper signed into its own bundle.
public enum FFmpegAvailability {
    public static let executableName = "ameya-ffmpeg"
    public static let environmentKey = "AMEYA_FFMPEG"

    /// The helper to run, or nil when this build doesn't have one.
    public static var helperURL: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        #endif
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        // Next to the worker (inside the launcher service); the app looks into that service's bundle.
        let candidates = [
            executable.deletingLastPathComponent().appendingPathComponent(executableName),
            Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/AmeyaLauncher.xpc/Contents/MacOS/\(executableName)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var isAvailable: Bool { helperURL != nil }
}
