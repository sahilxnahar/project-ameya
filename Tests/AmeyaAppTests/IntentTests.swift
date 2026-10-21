@testable import Ameya
import AmeyaCore
import AppIntents
import CoreGraphics
import Foundation
import Testing

@Suite("Shortcuts actions")
struct IntentTests {
    @Test func formatsAreWhatThisMacCanWrite() async throws {
        let writable = FileFormat.systemWritable()
        let formats = FormatEntity.writable(writable)
        #expect(formats.contains { $0.id == "jpeg" })
        #expect(formats.contains { $0.id == "png" })
        #expect(formats.contains { $0.id == "pdf" })
        #expect(!formats.contains { $0.id == FileFormat.other.rawValue || $0.id == FileFormat.decompressed.rawValue })
        #expect(formats.allSatisfy { $0.format.map(writable.contains) == true })
        // Only what this Mac can write: a Mac without the FFmpeg helper isn't offered WebM.
        let limited = FormatEntity.writable([.jpeg, .png])
        #expect(limited.map(\.id) == ["jpeg", "png"])
    }

    @Test func formatQuery() async throws {
        let query = FormatQuery()
        #expect(try await query.entities(for: ["png", "nonsense", "jpeg"]).map(\.id) == ["png", "jpeg"])
        #expect(try await query.entities(matching: "jpg").map(\.id) == ["jpeg"])
        #expect(try await query.entities(matching: "Word").map(\.id) == ["docx"])
        #expect(try await query.suggestedEntities().count == FormatEntity.writable().count)
        #expect(FormatEntity(.jpeg).format == .jpeg)
    }

    @Test func toolsNeedNoPanel() async throws {
        let tools = ToolEntity.all()
        let ids = Set(tools.map(\.id))
        #expect(ids.isSuperset(of: ["image.smaller", "pdf.merge", "image.removeLocation", "pdf.split"]))
        // Tools that ask questions first (a panel) can't run in Shortcuts.
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        for tool in catalog.tools where tool.panel != nil {
            #expect(!ids.contains(tool.id), "\(tool.id) has a panel")
        }
        #expect(try await ToolQuery().entities(for: ["image.smaller"]).first?.title == "Make it smaller")
        #expect(try await ToolQuery().entities(matching: "smaller").contains { $0.id == "image.smaller" })
    }

    @Test func namedShortcuts() {
        let shortcuts = AmeyaShortcuts.appShortcuts
        #expect(shortcuts.count == 3)
        // The tools those shortcuts use exist and need no panel.
        let ids = Set(ToolEntity.all().map(\.id))
        #expect(ids.contains("image.smaller") && ids.contains("pdf.merge"))
    }

    @Test func intentsHaveFriendlyTitles() {
        #expect(String(localized: ConvertFilesIntent.title) == "Convert Files")
        #expect(String(localized: RunToolIntent.title) == "Use an Ameya Tool")
        #expect(String(localized: ConvertToJPEGIntent.title) == "Convert to JPEG")
    }

    // MARK: The conversion path (real worker, unsandboxed here like the other integration tests)

    @Test func convertsThroughTheWorker() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("picture.png")
        try Fixtures.picture(at: input)
        let out = folder.appendingPathComponent("out", isDirectory: true)

        let written = try await IntentRunner.run([input], worker: Fixtures.worker, directory: out) { runner, urls, directory in
            runner.planConversion(urls, to: .jpeg, in: directory)
        }
        #expect(written.map(\.lastPathComponent) == ["picture.jpg"])
        #expect(FileFormat.detect(at: written[0]) == .jpeg)

        // Again: a new name, never over the first result.
        let again = try await IntentRunner.run([input], worker: Fixtures.worker, directory: out) { runner, urls, directory in
            runner.planConversion(urls, to: .jpeg, in: directory)
        }
        #expect(again.map(\.lastPathComponent) == ["picture 2.jpg"])
    }

    @Test func runsToolsThroughTheWorker() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("big.png")
        try Fixtures.picture(at: big, width: 3000, height: 1500)
        let out = folder.appendingPathComponent("out", isDirectory: true)

        let smaller = try await IntentRunner.run([big], worker: Fixtures.worker, directory: out) { runner, urls, directory in
            try runner.planTool(try #require(runner.tool(id: "image.smaller")), on: urls, in: directory)
        }
        #expect(smaller.map(\.lastPathComponent) == ["big (smaller).png"])
        #expect(Fixtures.pixelSize(of: smaller[0]).map { max($0.0, $0.1) } == 2048)

        let second = folder.appendingPathComponent("second.png")
        try Fixtures.picture(at: second)
        let merged = try await IntentRunner.run([big, second], worker: Fixtures.worker, directory: out) { runner, urls, directory in
            try runner.planTool(try #require(runner.tool(id: "pdf.merge")), on: urls, in: directory)
        }
        #expect(merged.map(\.lastPathComponent) == ["big (merged).pdf"])
        #expect(CGPDFDocument(merged[0] as CFURL)?.numberOfPages == 2)
    }

    @Test func problemsAreInPlainWords() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let convert: IntentRunner.Plan = { runner, urls, directory in runner.planConversion(urls, to: .jpeg, in: directory) }

        await #expect(throws: IntentProblem.self) {
            try await IntentRunner.run([text], worker: Fixtures.worker, directory: folder, plan: convert)
        }
        do {
            _ = try await IntentRunner.run([folder.appendingPathComponent("missing.png")], worker: Fixtures.worker,
                                           directory: folder, plan: convert)
            Issue.record("expected an error")
        } catch let problem as IntentProblem {
            #expect(problem.message == "There's no file called missing.png.")
        }
        do {
            _ = try await IntentRunner.run([text], worker: Fixtures.worker, directory: folder) { runner, urls, directory in
                try runner.planTool(try #require(runner.tool(id: "pdf.watermark")), on: urls, in: directory)
            }
            Issue.record("expected an error")
        } catch let problem as IntentProblem {
            #expect(problem.message.contains("needs choices made in the Ameya window"))
        }
        // Nothing was written by the failures.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["notes.txt"])
    }
}
