@testable import Ameya
import AmeyaCore
import Foundation
import Testing

/// Runs the built `ameya` binary for real: a copy of the debug app executable named `ameya`
/// (which is how the app tells it should be the command-line tool), with the debug worker.
@Suite("ameya binary", .serialized)
struct CommandLineToolTests {
    struct Setup {
        let folder: URL
        let ameya: URL
        var environment: [String: String] { [CommandLineTool.workerEnvironmentKey: Fixtures.worker.path] }

        init() throws {
            folder = try Fixtures.temporaryFolder()
            let bin = folder.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            ameya = bin.appendingPathComponent("ameya")
            try FileManager.default.copyItem(at: Fixtures.app, to: ameya)
        }

        func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
            try Fixtures.run(ameya, arguments, environment: environment, in: folder)
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    @Test func isRequestedOnlyAsLowercaseAmeya() {
        #expect(CommandLineTool.isRequested(["/usr/local/bin/ameya", "convert"]))
        #expect(CommandLineTool.isRequested(["ameya"]))
        #expect(!CommandLineTool.isRequested(["/Applications/Ameya.app/Contents/MacOS/Ameya"]))
        #expect(!CommandLineTool.isRequested([]))
    }

    @Test func convertsFilesForReal() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let input = setup.folder.appendingPathComponent("photo.jpg")
        try Fixtures.picture(at: input, type: .jpeg)
        let before = try Data(contentsOf: input)

        let result = try setup.run(["convert", "photo.jpg", "--to", "png", "--out", "converted", "--json"])
        #expect(result.status == 0, "\(result.stderr)")
        let report = try JSONDecoder().decode(CLIRunReport.self, from: Data(result.stdout.utf8))
        #expect(report.ok)
        let output = try #require(report.jobs.first?.output)
        #expect(output.hasSuffix("/converted/photo.png"))
        #expect(FileFormat.detect(at: URL(fileURLWithPath: output)) == .png)
        // The input is only read.
        #expect(try Data(contentsOf: input) == before)

        // Plain output names the new file.
        let human = try setup.run(["convert", "photo.jpg", "--to", "png", "--out", "converted"])
        #expect(human.status == 0)
        #expect(human.stdout.contains("photo 2.png"))
    }

    @Test func runsATool() throws {
        let setup = try Setup()
        defer { setup.remove() }
        for name in ["one.png", "two.png"] { try Fixtures.picture(at: setup.folder.appendingPathComponent(name)) }
        let result = try setup.run(["run", "pdf.merge", "one.png", "two.png", "-o", "out", "--json"])
        #expect(result.status == 0, "\(result.stderr)")
        let report = try JSONDecoder().decode(CLIRunReport.self, from: Data(result.stdout.utf8))
        #expect(report.jobs.count == 1)
        #expect(report.jobs[0].output?.hasSuffix("one (merged).pdf") == true)
    }

    @Test func exitCodesForProblems() throws {
        let setup = try Setup()
        defer { setup.remove() }
        try Data("plain words".utf8).write(to: setup.folder.appendingPathComponent("notes.txt"))
        try Fixtures.picture(at: setup.folder.appendingPathComponent("ok.png"))

        #expect(try setup.run(["convert", "notes.txt"]).status == CLIExit.usage.rawValue)
        #expect(try setup.run(["bogus"]).status == CLIExit.usage.rawValue)
        #expect(try setup.run(["convert", "missing.png", "--to", "jpeg"]).status == CLIExit.badInput.rawValue)
        #expect(try setup.run(["convert", "ok.png", "--to", "nonsense"]).status == CLIExit.badInput.rawValue)
        #expect(try setup.run(["run", "no.such.tool", "ok.png"]).status == CLIExit.badInput.rawValue)
        #expect(try setup.run(["run", "pdf.watermark", "ok.png"]).status == CLIExit.badInput.rawValue)

        // One good file and one that can't become JPEG: the good one is done, exit 1.
        let mixed = try setup.run(["convert", "ok.png", "notes.txt", "--to", "jpeg", "-o", "out", "--json"])
        #expect(mixed.status == CLIExit.failed.rawValue)
        let report = try JSONDecoder().decode(CLIRunReport.self, from: Data(mixed.stdout.utf8))
        #expect(report.jobs.count == 1 && report.skipped.count == 1)
        #expect(report.skipped[0].reason.contains("can't become JPEG"))

        // A worker that isn't there is a setup problem.
        let broken = try Fixtures.run(setup.ameya, ["convert", "ok.png", "--to", "jpeg"],
                                      environment: [CommandLineTool.workerEnvironmentKey: "/nonexistent/worker"], in: setup.folder)
        #expect(broken.status == CLIExit.unavailable.rawValue)
        let error = try setup.run(["bogus", "--json"])
        #expect(error.stdout.contains("\"exitCode\" : 2"))
    }

    @Test func listsToolsFormatsAndHelp() throws {
        let setup = try Setup()
        defer { setup.remove() }
        try Fixtures.picture(at: setup.folder.appendingPathComponent("pic.png"))

        let tools = try setup.run(["tools", "--json"])
        #expect(tools.status == 0)
        let list = try JSONDecoder().decode([CLIToolInfo].self, from: Data(tools.stdout.utf8))
        #expect(list.contains { $0.id == "image.smaller" && !$0.needsApp })
        #expect(list.contains { $0.id == "pdf.watermark" && $0.needsApp })

        let formats = try setup.run(["formats", "pic.png", "--json"])
        let report = try JSONDecoder().decode(CLIFormatsReport.self, from: Data(formats.stdout.utf8))
        #expect(report.format?.id == "png")
        #expect(report.targets.contains { $0.id == "jpeg" })
        #expect(report.tools?.contains("image.smaller") == true)
        #expect(try setup.run(["formats"]).stdout.contains("jpeg"))

        let help = try setup.run(["--help"])
        #expect(help.status == 0 && help.stdout.contains("ameya convert"))
        #expect(try setup.run(["--install-help"]).stdout.contains("/usr/local/bin/ameya"))
    }

    /// The real bundle (after `./scripts/build-app.sh`): the helper with the separately
    /// sandboxed worker, no environment overrides.
    @Test func builtBundleConvertsThroughItsSandboxedWorker() throws {
        let app = Fixtures.repository.appendingPathComponent("dist/Ameya.app")
        let helper = app.appendingPathComponent("Contents/Helpers/ameya")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return } // not built yet
        let worker = app.appendingPathComponent("Contents/MacOS/\(CommandLineTool.workerName)")
        #expect(CommandLineTool.isSandboxedOnItsOwn(worker))
        #expect(!CommandLineTool.isSandboxedOnItsOwn(Fixtures.worker))

        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Fixtures.picture(at: folder.appendingPathComponent("bundle test.jpg"), type: .jpeg)
        var environment = ProcessInfo.processInfo.environment
        environment[CommandLineTool.workerEnvironmentKey] = nil
        let process = Process()
        process.executableURL = helper
        process.arguments = ["convert", "bundle test.jpg", "--to", "png", "--out", "out", "--json"]
        process.environment = environment
        process.currentDirectoryURL = folder
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let report = try JSONDecoder().decode(CLIRunReport.self, from: data)
        let output = try #require(report.jobs.first?.output)
        #expect(FileFormat.detect(at: URL(fileURLWithPath: output)) == .png)
    }
}
