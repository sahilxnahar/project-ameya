import AmeyaCore
import Darwin
import Foundation
import Security

/// The `ameya` command-line tool: `Ameya.app/Contents/Helpers/ameya`, a copy of the app's own
/// executable signed *without* the app sandbox, so it can read the files named on the command line.
///
/// It never parses those files itself. Every job runs in `Contents/MacOS/ameya-worker`, a copy of
/// the worker signed with its own App Sandbox (no `inherit`, which only works under a sandboxed
/// parent). The worker gets the input as a read-only descriptor and writes to a hidden partial file
/// in the output folder, exactly as in the app. The tool reads only the inputs and writes only
/// inside the output folder.
///
/// (A file named `ameya` can't sit next to `Ameya` in Contents/MacOS: on the usual
/// case-insensitive disk they would be the same file. Hence Contents/Helpers.)
@MainActor
enum CommandLineTool {
    nonisolated static let workerName = "ameya-worker"
    /// Development and tests only: run this worker instead (it isn't checked for a sandbox).
    nonisolated static let workerEnvironmentKey = "AMEYA_WORKER"

    /// Started as `ameya`, as opposed to the app (`Ameya`), which Finder and Launch Services start.
    nonisolated static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        guard let first = arguments.first else { return false }
        return URL(fileURLWithPath: first).lastPathComponent == "ameya"
    }

    static func main(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        let wantsJSON = arguments.contains("--json")
        let invocation: CLIInvocation
        do {
            invocation = try CLIInvocation.parse(arguments)
        } catch {
            return fail(error.description, .usage, json: wantsJSON)
        }
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            // `Contents/MacOS/ameya` is the sandboxed app itself on a case-insensitive disk.
            return fail("This is the Ameya app, which can't open files named in Terminal. Use \(helperPath()) instead, or see: \(helperPath()) --install-help",
                        .unavailable, json: invocation.json)
        }
        switch invocation.command {
        case .help:
            print(CLIHelp.usage)
            return CLIExit.success.rawValue
        case .version:
            let version = Bundle(url: appBundle())?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
            print(invocation.json ? CLIJSON.encode(["version": version]) : "ameya \(version)")
            return CLIExit.success.rawValue
        case .installHelp:
            print(CLIHelp.install(executable: helperPath()))
            return CLIExit.success.rawValue
        case .tools:
            return listTools(json: invocation.json)
        case .formats(let file):
            return listFormats(file: file, json: invocation.json)
        case .convert(let files, let targetName, let out):
            guard let target = FileFormat.named(targetName), target != .other else {
                return fail(AutomationRunner.Failure.unknownFormat(targetName).errorDescription!, .badInput, json: invocation.json)
            }
            return await perform(files: files, out: out, json: invocation.json) { runner, urls, directory in
                runner.planConversion(urls, to: target, in: directory)
            }
        case .run(let toolID, let files, let out):
            return await perform(files: files, out: out, json: invocation.json) { runner, urls, directory in
                guard let tool = runner.tool(id: toolID) else { throw AutomationRunner.Failure.unknownTool(toolID) }
                return try runner.planTool(tool, on: urls, in: directory)
            }
        }
    }

    // MARK: Commands

    private static func perform(
        files: [String], out: String?, json: Bool,
        plan: (AutomationRunner, [URL], URL) throws -> (jobs: [AutomationRunner.PlannedJob], skipped: [AutomationRunner.Skipped])
    ) async -> Int32 {
        let worker: URL
        switch locateWorker() {
        case .success(let url): worker = url
        case .failure(let problem): return fail(problem.message, .unavailable, json: json)
        }
        let runner = AutomationRunner(worker: worker)
        let directory = out.map(url(forPath:)) ?? JobStore.realDownloadsDirectory().appendingPathComponent("Ameya", isDirectory: true)
        var planned: (jobs: [AutomationRunner.PlannedJob], skipped: [AutomationRunner.Skipped])
        do {
            planned = try plan(runner, files.map(url(forPath:)), directory)
        } catch {
            return fail((error as? LocalizedError)?.errorDescription ?? "\(error)", .badInput, json: json)
        }
        // Transcription asks for speech-recognition permission, which only the app can do.
        let isTranscription = { (job: AutomationRunner.PlannedJob) in
            job.formats.count == 1 && ConversionMatrix.isTranscription(from: job.formats[0], to: job.request.target)
        }
        for job in planned.jobs where isTranscription(job) {
            planned.skipped.append(.init(input: job.inputs[0], reason: "Transcribing \(job.inputs[0].lastPathComponent) needs the Ameya app (it asks to use speech recognition)."))
        }
        planned.jobs.removeAll(where: isTranscription)
        let interactive = !json && isatty(STDERR_FILENO) == 1
        let names = planned.jobs.map { $0.inputs[0].lastPathComponent }
        let outcomes = await runner.run(planned.jobs, in: directory) { index, value in
            if interactive {
                FileHandle.standardError.write(Data("\r\u{1B}[K\(names[index]): \(Int(value * 100))%".utf8))
            }
        }
        if interactive && !names.isEmpty { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

        let report = CLIRunReport(
            outputFolder: planned.jobs.isEmpty ? nil : directory.path,
            jobs: outcomes.map { outcome in
                CLIJobReport(inputs: outcome.inputs.map(\.path), output: outcome.output?.path, files: outcome.files.map(\.path),
                             bytes: outcome.result?.outputBytes, notes: outcome.result?.notes.map(\.message) ?? [],
                             error: outcome.error)
            },
            skipped: planned.skipped.map { CLISkipped(input: $0.input.path, reason: $0.reason) }
        )
        if json {
            print(CLIJSON.encode(report))
        } else {
            printHuman(report)
        }
        return report.exitCode.rawValue
    }

    private static func printHuman(_ report: CLIRunReport) {
        let sizes = ByteCountFormatter()
        sizes.countStyle = .file
        for job in report.jobs {
            let from = job.inputs.count == 1 ? name(job.inputs[0]) : "\(job.inputs.count) files"
            if let output = job.output {
                let size = job.bytes.map { " (\(sizes.string(fromByteCount: Int64($0))))" } ?? ""
                let extra = job.files.count > 1 ? ", \(job.files.count) files" : ""
                print("Done: \(from) → \(output)\(size)\(extra)")
                for note in job.notes { print("      Note: \(note)") }
            } else {
                printError("Couldn't do \(from): \(job.error ?? "unknown problem")")
            }
        }
        for skipped in report.skipped { printError("Skipped: \(skipped.reason)") }
        if report.jobs.isEmpty && report.skipped.isEmpty { printError("Nothing to do.") }
    }

    private static func listTools(json: Bool) -> Int32 {
        let catalog = ToolCatalog(writable: FileFormat.systemWritable())
        let tools = catalog.tools.map {
            CLIToolInfo(id: $0.id, title: $0.title, help: $0.help, needsApp: $0.panel != nil,
                        allFilesTogether: $0.mode == .allTogether)
        }
        if json {
            print(CLIJSON.encode(tools))
            return CLIExit.success.rawValue
        }
        let width = tools.map(\.id.count).max() ?? 0
        print("Tools for \"ameya run <tool> <files…>\":\n")
        for tool in tools where !tool.needsApp {
            print("  \(tool.id.padding(toLength: width, withPad: " ", startingAt: 0))  \(tool.title): \(tool.help)")
        }
        let appOnly = tools.filter(\.needsApp)
        if !appOnly.isEmpty {
            print("\nThese need choices made in the Ameya window: " + appOnly.map(\.title).joined(separator: ", "))
        }
        return CLIExit.success.rawValue
    }

    private static func listFormats(file: String?, json: Bool) -> Int32 {
        let writable = FileFormat.systemWritable()
        let matrix = ConversionMatrix(writable: writable)
        guard let file else {
            let targets = FileFormat.allCases.filter { writable.contains($0) && $0 != .other && $0 != .decompressed }
            if json {
                print(CLIJSON.encode(CLIFormatsReport(file: nil, format: nil, targets: targets.map(CLIFormatInfo.init), tools: nil)))
            } else {
                print("This Mac can write (use the short name with --to):\n")
                for family in Dictionary(grouping: targets, by: \.family).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    print("  \(family.key.rawValue): " + family.value.map(\.commandLineName).joined(separator: ", "))
                }
                print("\nFor one file: ameya formats <file>")
            }
            return CLIExit.success.rawValue
        }
        let fileURL = url(forPath: file)
        let (found, skipped) = AutomationRunner.detect([fileURL])
        guard let (_, format) = found.first else {
            return fail(skipped.first?.reason ?? "Couldn't read \(file).", .badInput, json: json)
        }
        let targets = matrix.targets(for: format)
        let tools = ToolCatalog(writable: writable).available(for: [format]).filter { $0.panel == nil }.map(\.id)
        if json {
            print(CLIJSON.encode(CLIFormatsReport(file: fileURL.path, format: CLIFormatInfo(format),
                                                  targets: targets.map(CLIFormatInfo.init), tools: tools)))
        } else if targets.isEmpty {
            print("\(fileURL.lastPathComponent) is \(format.displayName). Ameya can't turn it into anything else yet.")
        } else {
            print("\(fileURL.lastPathComponent) is \(format.displayName). It can become:")
            print("  " + targets.map { "\($0.commandLineName) (\($0.displayName))" }.joined(separator: ", "))
            if !tools.isEmpty { print("Tools: " + tools.joined(separator: ", ")) }
        }
        return CLIExit.success.rawValue
    }

    // MARK: The worker

    struct SetupProblem: Error {
        let message: String
    }

    /// The sandboxed worker next to the app's own (`Contents/MacOS/ameya-worker`).
    static func locateWorker() -> Result<URL, SetupProblem> {
        if let path = ProcessInfo.processInfo.environment[workerEnvironmentKey], !path.isEmpty {
            return FileManager.default.isExecutableFile(atPath: path)
                ? .success(URL(fileURLWithPath: path))
                : .failure(SetupProblem(message: "\(workerEnvironmentKey) points at \(path), which isn't a program."))
        }
        let worker = appBundle().appendingPathComponent("Contents/MacOS/\(workerName)")
        guard FileManager.default.isExecutableFile(atPath: worker.path) else {
            return .failure(SetupProblem(message: "The converter is missing (\(worker.path)). Reinstall Ameya."))
        }
        guard isSandboxedOnItsOwn(worker) else {
            return .failure(SetupProblem(message: "The converter at \(worker.path) isn't sandboxed, so Ameya won't use it. Reinstall Ameya."))
        }
        return .success(worker)
    }

    /// Signed with the App Sandbox and without `inherit` (which would crash under this unsandboxed tool).
    nonisolated static func isSandboxedOnItsOwn(_ executable: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else { return false }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
            && entitlements["com.apple.security.inherit"] as? Bool != true
    }

    // MARK: Helpers

    /// This executable with symlinks (e.g. /usr/local/bin/ameya) resolved.
    static func executable() -> URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }

    /// `Ameya.app`, two levels above Contents/Helpers/ameya (or Contents/MacOS/Ameya).
    static func appBundle() -> URL {
        executable().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func helperPath() -> String {
        appBundle().appendingPathComponent("Contents/Helpers/ameya").path
    }

    private static func url(forPath path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }

    private static func name(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String, _ code: CLIExit, json: Bool) -> Int32 {
        if json {
            print(CLIJSON.encode(CLIErrorReport(error: message, exit: code)))
        } else {
            printError(message)
        }
        return code.rawValue
    }
}
