import Foundation
import Testing
@testable import AmeyaCore

@Suite("Settings import and export")
struct SettingsArchiveTests {
    let schema: [String: SettingKind] = [
        "wheel.size": .string, "wheel.delay": .double, "showInDock": .bool,
        "panel.favourites": .stringArray, "hotkey.*": .string,
    ]

    @Test func roundTripKeepsOnlyKnownKeys() throws {
        let values: [String: Any] = [
            "wheel.size": "large", "wheel.delay": 0.3, "showInDock": true,
            "panel.favourites": ["format.jpeg", "tool.image.rotate"], "hotkey.openPanel": "none",
            "secretOther": "nope",
        ]
        let data = try SettingsArchive.export(values, schema: schema)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("secretOther"))
        let (read, ignored) = try SettingsArchive.read(data, schema: schema)
        #expect(ignored.isEmpty)
        #expect(read["wheel.size"] as? String == "large")
        #expect(read["wheel.delay"] as? Double == 0.3)
        #expect(read["showInDock"] as? Bool == true)
        #expect(read["panel.favourites"] as? [String] == ["format.jpeg", "tool.image.rotate"])
        #expect(read["hotkey.openPanel"] as? String == "none")
    }

    @Test func wrongTypesAndUnknownKeysAreIgnored() throws {
        let json = #"{"format":"ameya-settings","version":1,"settings":{"showInDock":1,"wheel.delay":true,"wheel.size":"small","other":"x"}}"#
        let (read, ignored) = try SettingsArchive.read(Data(json.utf8), schema: schema)
        #expect(read.keys.sorted() == ["wheel.size"])
        #expect(ignored == ["other", "showInDock", "wheel.delay"])
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: SettingsArchive.Problem.notASettingsFile) {
            try SettingsArchive.read(Data(#"{"hello":1}"#.utf8), schema: schema)
        }
        #expect(throws: SettingsArchive.Problem.newerVersion(9)) {
            try SettingsArchive.read(Data(#"{"format":"ameya-settings","version":9,"settings":{}}"#.utf8), schema: schema)
        }
        #expect(throws: SettingsArchive.Problem.tooLarge) {
            try SettingsArchive.read(Data(count: SettingsArchive.maxBytes + 1), schema: schema)
        }
    }

    @Test func prefixKeys() {
        #expect(SettingsArchive.kind(of: "hotkey.quickConvert", in: schema) == .string)
        #expect(SettingsArchive.kind(of: "hotkeyX", in: schema) == nil)
    }
}
