import Foundation
import Testing

/// Ameya promises that everything stays on the Mac. These checks fail the build if network
/// access creeps in through entitlements or networking APIs.
@Suite("Local only")
struct LocalOnlyTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("No entitlement grants network access", arguments: ["Ameya.entitlements", "AmeyaWorker.entitlements", "AmeyaWorkerStandalone.entitlements"])
    func entitlements(file: String) throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/\(file)"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let networkKeys = plist.keys.filter { $0.localizedCaseInsensitiveContains("network") }
        #expect(networkKeys.isEmpty, "network entitlements found: \(networkKeys)")
        #expect(plist["com.apple.security.app-sandbox"] as? Bool == true)
    }

    @Test func noNetworkingAPIsInOurCode() throws {
        let forbidden = ["URLSession", "NWConnection", "NWListener", "NWBrowser", "URLRequest(", "CFSocket",
                         "CFStream", "WKWebView", "AssetInventory", "SFSafariViewController"]
        let sources = Self.root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for api in forbidden where text.contains(api) {
                offenders.append("\(file.lastPathComponent): \(api)")
            }
        }
        #expect(offenders.isEmpty, "networking APIs found: \(offenders)")
    }
}
