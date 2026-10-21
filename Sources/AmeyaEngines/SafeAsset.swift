import AmeyaCore
import AVFoundation

/// Opens media for reading so that it can only use the file itself.
///
/// QuickTime movies may hold *references* instead of samples: a track's media can live in
/// another file (by absolute path) or at a web address. Opened plainly, AVFoundation follows
/// them, so a small "movie" could pull a file from elsewhere on the Mac into the output.
/// Every asset in the engines comes from here. References are forbidden through
/// `AVURLAssetReferenceRestrictionsKey`, but that alone doesn't stop a movie whose track
/// points at another local file (checked on macOS 26), so `open` also refuses any track that
/// isn't self-contained.
enum SafeAsset {
    static var options: [String: Any] { [
        AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        AVURLAssetAllowsCellularAccessKey: false,
        AVURLAssetAllowsExpensiveNetworkAccessKey: false,
        AVURLAssetAllowsConstrainedNetworkAccessKey: false,
    ] }

    /// The asset, without the self-containment check. Prefer `open`.
    static func make(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: options)
    }

    /// The asset, once every track is known to keep its samples inside the file.
    static func open(_ url: URL) async throws -> AVURLAsset {
        let asset = make(url: url)
        for track in try await asset.load(.tracks) where try await !track.load(.isSelfContained) {
            throw ConversionError.invalidData("its picture or sound is stored in other files, which can't be included")
        }
        return asset
    }
}
