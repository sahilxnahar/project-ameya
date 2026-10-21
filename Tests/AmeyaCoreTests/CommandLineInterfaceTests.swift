@testable import AmeyaCore
import Foundation
import Testing

@Suite("ameya command line")
struct CommandLineInterfaceTests {
    @Test func convertWithTargetAndFolder() throws {
        let parsed = try CLIInvocation.parse(["convert", "a.heic", "b.png", "--to", "jpeg", "--out", "~/Out"])
        #expect(parsed == CLIInvocation(command: .convert(files: ["a.heic", "b.png"], target: "jpeg", out: "~/Out")))
    }

    @Test func optionsMayComeFirstAndUseEquals() throws {
        let parsed = try CLIInvocation.parse(["--json", "-t=png", "convert", "x.jpg", "-o", "out"])
        #expect(parsed == CLIInvocation(command: .convert(files: ["x.jpg"], target: "png", out: "out"), json: true))
    }

    @Test func doubleDashEndsOptions() throws {
        let parsed = try CLIInvocation.parse(["convert", "--to", "png", "--", "--weird name.jpg"])
        #expect(parsed.command == .convert(files: ["--weird name.jpg"], target: "png", out: nil))
    }

    @Test func runToolsFormats() throws {
        #expect(try CLIInvocation.parse(["run", "pdf.merge", "a.pdf", "b.pdf"]).command
            == .run(tool: "pdf.merge", files: ["a.pdf", "b.pdf"], out: nil))
        #expect(try CLIInvocation.parse(["tools", "--json"]) == CLIInvocation(command: .tools, json: true))
        #expect(try CLIInvocation.parse(["formats"]).command == .formats(file: nil))
        #expect(try CLIInvocation.parse(["formats", "a.docx"]).command == .formats(file: "a.docx"))
    }

    @Test func helpVersionInstall() throws {
        #expect(try CLIInvocation.parse([]).command == .help)
        #expect(try CLIInvocation.parse(["help"]).command == .help)
        #expect(try CLIInvocation.parse(["convert", "--help"]).command == .help)
        #expect(try CLIInvocation.parse(["-h"]).command == .help)
        #expect(try CLIInvocation.parse(["--version"]).command == .version)
        #expect(try CLIInvocation.parse(["--install-help"]).command == .installHelp)
    }

    @Test("Mistakes are explained", arguments: [
        (["convert", "a.png"], CLIParseError.missingTarget),
        (["convert", "--to", "png"], .missingFiles("convert")),
        (["convert", "a.png", "--to"], .missingValue("--to")),
        (["run"], .missingTool),
        (["run", "image.smaller"], .missingFiles("run image.smaller")),
        (["frobnicate"], .unknownCommand("frobnicate")),
        (["convert", "a.png", "--to", "png", "--fast"], .unknownOption("--fast")),
        (["tools", "extra"], .unexpectedArgument("extra")),
        (["formats", "a", "b"], .unexpectedArgument("b")),
        (["tools", "--to", "png"], .unknownOption("--to")),
    ])
    func errors(arguments: [String], expected: CLIParseError) {
        #expect(throws: expected) { try CLIInvocation.parse(arguments) }
        #expect(!expected.description.isEmpty)
    }

    @Test func formatNames() {
        #expect(FileFormat.named("jpeg") == .jpeg)
        #expect(FileFormat.named("JPG") == .jpeg)
        #expect(FileFormat.named(".png") == .png)
        #expect(FileFormat.named("Word") == .docx)
        #expect(FileFormat.named("7z") == .sevenZip)
        #expect(FileFormat.named("3gp") == .threegp)
        #expect(FileFormat.named("tif") == .tiff)
        #expect(FileFormat.named("markdown") == .md)
        #expect(FileFormat.named("") == nil)
        #expect(FileFormat.named("nonsense") == nil)
        for format in FileFormat.allCases {
            #expect(FileFormat.named(format.commandLineName) == format)
        }
    }

    @Test func exitCodes() {
        #expect(CLIExit.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
        let done = CLIJobReport(inputs: ["/a.png"], output: "/out/a.jpg", files: ["/out/a.jpg"], bytes: 10)
        let failed = CLIJobReport(inputs: ["/b.png"], error: "broken")
        let skipped = CLISkipped(input: "/c.txt", reason: "no")
        #expect(CLIRunReport(outputFolder: "/out", jobs: [done]).exitCode == .success)
        #expect(CLIRunReport(outputFolder: "/out", jobs: [done, failed]).exitCode == .failed)
        #expect(CLIRunReport(outputFolder: "/out", jobs: [done], skipped: [skipped]).exitCode == .failed)
        #expect(CLIRunReport(outputFolder: nil, jobs: [], skipped: [skipped]).exitCode == .badInput)
        #expect(CLIRunReport(outputFolder: nil, jobs: []).exitCode == .badInput)
    }

    @Test func jsonShape() throws {
        let report = CLIRunReport(outputFolder: "/out",
                                  jobs: [CLIJobReport(inputs: ["/a.png"], output: "/out/a.jpg", files: ["/out/a.jpg"],
                                                      bytes: 42, notes: ["Transparent areas became white."])])
        let json = CLIJSON.encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        #expect(object["outputFolder"] as? String == "/out")
        let jobs = try #require(object["jobs"] as? [[String: Any]])
        #expect(jobs.first?["output"] as? String == "/out/a.jpg")
        #expect(jobs.first?["bytes"] as? Int == 42)
        #expect(json.contains("/out/a.jpg")) // slashes aren't escaped
        #expect(try JSONDecoder().decode(CLIRunReport.self, from: Data(json.utf8)) == report)

        let error = CLIJSON.encode(CLIErrorReport(error: "nope", exit: .usage))
        #expect(error.contains("\"exitCode\" : 2"))
    }

    @Test func helpMentionsEveryCommand() {
        for word in ["convert", "run", "formats", "tools", "--install-help", "--json", "--out", "--to", "Exit codes"] {
            #expect(CLIHelp.usage.contains(word), "help is missing \(word)")
        }
        #expect(CLIHelp.install(executable: "/Applications/Ameya.app/Contents/Helpers/ameya")
            .contains("ln -sf \"/Applications/Ameya.app/Contents/Helpers/ameya\" /usr/local/bin/ameya"))
    }
}
