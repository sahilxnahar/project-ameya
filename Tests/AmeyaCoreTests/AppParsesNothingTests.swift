import Foundation
import Testing

/// The app is the privileged process: it must never parse the contents of a user's file. PDFs,
/// pictures, audio and video are opened only by the sandboxed worker. This fails when one of the
/// system parsers shows up in the app target.
@Suite("The app doesn't parse user files")
struct AppParsesNothingTests {
    /// Calls that open or parse a file's contents.
    static let forbidden = [
        "PDFDocument(", "CGPDFDocument(", "import PDFKit",
        "CGImageSourceCreateWithURL(", "CGImageSourceCreateWithData(", "CGImageSourceCreateIncremental(",
        "NSImage(contentsOf", "NSImage(byReferencing", "CIImage(contentsOf", "NSBitmapImageRep(data",
        "AVAsset(", "AVURLAsset(", "AVAudioFile(", "NSAttributedString(url", "NSAttributedString(data",
    ]

    /// Developer-only code that reads Ameya's own generated outputs (`--self-test`) or a system
    /// wallpaper (`--snapshots`); neither runs for a user's files.
    static func isAllowed(_ file: String) -> Bool {
        file.hasPrefix("SelfTest") || file == "Snapshots.swift"
    }

    static var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Ameya", isDirectory: true)
    }

    @Test func noSystemParserTouchesUserFilesInTheApp() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.appSources, includingPropertiesForKeys: nil))
        var checked = 0
        var offences: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            checked += 1
            guard !Self.isAllowed(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                for token in Self.forbidden where code.contains(token) {
                    offences.append("\(url.lastPathComponent):\(number + 1) uses \(token)")
                }
            }
        }
        #expect(checked > 20, "found only \(checked) app source files; has the folder moved?")
        #expect(offences.isEmpty, "Move this work into the worker: \(offences.joined(separator: "; "))")
    }
}
