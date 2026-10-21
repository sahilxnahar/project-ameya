import Foundation

/// The `ameya` command-line tool's grammar, exit codes, help text and `--json` shapes.
/// Running the commands lives in the app target (Automation/CommandLineTool.swift);
/// everything here is pure so it can be unit tested.
public enum CLIExit: Int32, Sendable, CaseIterable {
    /// Everything worked.
    case success = 0
    /// At least one file couldn't be converted (the others were).
    case failed = 1
    /// The command line didn't make sense; see `ameya --help`.
    case usage = 2
    /// A file is missing, unreadable, or can't become what was asked.
    case badInput = 3
    /// Ameya itself isn't set up right (e.g. the converter is missing).
    case unavailable = 4
}

public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case installHelp
    case convert(files: [String], target: String, out: String?)
    case tools
    case run(tool: String, files: [String], out: String?)
    case formats(file: String?)
}

public struct CLIInvocation: Equatable, Sendable {
    public var command: CLICommand
    public var json: Bool

    public init(command: CLICommand, json: Bool = false) {
        self.command = command
        self.json = json
    }
}

public enum CLIParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case missingFiles(String)
    case missingTarget
    case missingTool
    case unexpectedArgument(String)

    public var description: String {
        switch self {
        case .unknownCommand(let name): "\"\(name)\" isn't an ameya command. Try: ameya --help"
        case .unknownOption(let name): "\"\(name)\" isn't an option here. Try: ameya --help"
        case .missingValue(let option): "\(option) needs a value after it."
        case .missingFiles(let command): "Which files? For example: ameya \(command) photo.heic"
        case .missingTarget: "Convert to what? Add --to, for example: --to jpeg"
        case .missingTool: "Which tool? See the list with: ameya tools"
        case .unexpectedArgument(let value): "Didn't expect \"\(value)\" here. Try: ameya --help"
        }
    }
}

extension CLIInvocation {
    /// Parses the arguments after the program name.
    public static func parse(_ arguments: [String]) throws(CLIParseError) -> CLIInvocation {
        var json = false
        var out: String?
        var target: String?
        var positional: [String] = []
        var index = 0
        var optionsEnded = false

        func value(for option: String, inline: String?) throws(CLIParseError) -> String {
            if let inline, !inline.isEmpty { return inline }
            index += 1
            guard index < arguments.count, !arguments[index].isEmpty else { throw .missingValue(option) }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                positional.append(argument)
            } else {
                let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                let inline = parts.count > 1 ? parts[1] : nil
                switch name {
                case "--": optionsEnded = true
                case "--json": json = true
                case "-h", "--help": return CLIInvocation(command: .help, json: json)
                case "--version": return CLIInvocation(command: .version, json: json)
                case "--install-help": return CLIInvocation(command: .installHelp, json: json)
                case "--to", "-t": target = try value(for: "--to", inline: inline)
                case "--out", "-o": out = try value(for: "--out", inline: inline)
                default: throw .unknownOption(name)
                }
            }
            index += 1
        }

        guard let name = positional.first else { return CLIInvocation(command: .help, json: json) }
        let rest = Array(positional.dropFirst())
        let command: CLICommand
        switch name {
        case "help":
            command = .help
        case "version":
            command = .version
        case "convert":
            guard !rest.isEmpty else { throw .missingFiles("convert") }
            guard let target else { throw .missingTarget }
            command = .convert(files: rest, target: target, out: out)
        case "run":
            guard let tool = rest.first else { throw .missingTool }
            let files = Array(rest.dropFirst())
            guard !files.isEmpty else { throw .missingFiles("run \(tool)") }
            command = .run(tool: tool, files: files, out: out)
        case "tools":
            if let extra = rest.first { throw .unexpectedArgument(extra) }
            command = .tools
        case "formats":
            if rest.count > 1 { throw .unexpectedArgument(rest[1]) }
            command = .formats(file: rest.first)
        default:
            throw .unknownCommand(name)
        }
        // Options that only make sense for some commands.
        switch command {
        case .convert, .run: break
        default:
            if target != nil { throw .unknownOption("--to") }
            if out != nil { throw .unknownOption("--out") }
        }
        return CLIInvocation(command: command, json: json)
    }
}

// MARK: Formats by name

extension FileFormat {
    /// The format a person means by `name`: "jpeg", "JPG", ".png", "Word", "7z" …
    /// `nil` when nothing matches.
    public static func named(_ name: String) -> FileFormat? {
        var key = name.trimmingCharacters(in: .whitespaces).lowercased()
        while key.hasPrefix(".") { key.removeFirst() }
        guard !key.isEmpty else { return nil }
        if let exact = FileFormat(rawValue: key) { return exact }
        let aliases: [String: FileFormat] = [
            "jpg": .jpeg, "jpe": .jpeg, "tif": .tiff, "htm": .html, "markdown": .md, "text": .txt,
            "word": .docx, "yml": .yaml, "excel": .xlsx, "heif": .heic, "aac": .m4a, "aif": .aiff,
            "gzip": .gz, "mpeg": .mpg, "subrip": .srt, "webvtt": .vtt,
        ]
        if let alias = aliases[key] { return alias }
        if let byExtension = allCases.first(where: { $0.extensions.contains(key) }) { return byExtension }
        return allCases.first { $0.displayName.lowercased() == key }
    }

    /// The short name shown by `ameya formats` and accepted by `--to`.
    public var commandLineName: String { rawValue }
}

// MARK: JSON output

/// One finished (or failed) job, as `--json` reports it.
public struct CLIJobReport: Codable, Equatable, Sendable {
    public var inputs: [String]
    /// The file or folder written. `nil` when the job failed.
    public var output: String?
    /// Every file written: the output itself, or the files inside an output folder.
    public var files: [String]
    public var bytes: Int?
    public var notes: [String]
    public var error: String?

    public init(inputs: [String], output: String? = nil, files: [String] = [], bytes: Int? = nil,
                notes: [String] = [], error: String? = nil) {
        self.inputs = inputs
        self.output = output
        self.files = files
        self.bytes = bytes
        self.notes = notes
        self.error = error
    }
}

public struct CLIRunReport: Codable, Equatable, Sendable {
    public var ok: Bool
    public var outputFolder: String?
    public var jobs: [CLIJobReport]
    /// Files that were left out before anything ran (missing, unsupported, …), with why.
    public var skipped: [CLISkipped]

    public init(outputFolder: String?, jobs: [CLIJobReport], skipped: [CLISkipped] = []) {
        self.ok = !jobs.isEmpty && jobs.allSatisfy { $0.error == nil } && skipped.isEmpty
        self.outputFolder = outputFolder
        self.jobs = jobs
        self.skipped = skipped
    }

    public var exitCode: CLIExit {
        if ok { return .success }
        // Nothing ran at all: every file was missing or unsuitable.
        return jobs.isEmpty ? .badInput : .failed
    }
}

public struct CLISkipped: Codable, Equatable, Sendable {
    public var input: String
    public var reason: String

    public init(input: String, reason: String) {
        self.input = input
        self.reason = reason
    }
}

public struct CLIToolInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var help: String
    /// Tools that need choices made in a panel can only run in the app.
    public var needsApp: Bool
    public var allFilesTogether: Bool

    public init(id: String, title: String, help: String, needsApp: Bool, allFilesTogether: Bool) {
        self.id = id
        self.title = title
        self.help = help
        self.needsApp = needsApp
        self.allFilesTogether = allFilesTogether
    }
}

public struct CLIFormatInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var family: String

    public init(_ format: FileFormat) {
        id = format.commandLineName
        name = format.displayName
        family = format.family.rawValue
    }
}

/// `ameya formats [file]`.
public struct CLIFormatsReport: Codable, Equatable, Sendable {
    public var file: String?
    /// The detected format of `file`.
    public var format: CLIFormatInfo?
    /// What `file` can become, or every format this Mac can write.
    public var targets: [CLIFormatInfo]
    /// Tool ids that work on `file` (only with a file).
    public var tools: [String]?

    public init(file: String?, format: CLIFormatInfo?, targets: [CLIFormatInfo], tools: [String]?) {
        self.file = file
        self.format = format
        self.targets = targets
        self.tools = tools
    }
}

/// `{"error": "…"}` for usage and setup problems in `--json` mode.
public struct CLIErrorReport: Codable, Equatable, Sendable {
    public var error: String
    public var exitCode: Int32

    public init(error: String, exit: CLIExit) {
        self.error = error
        exitCode = exit.rawValue
    }
}

public enum CLIJSON {
    public static func encode<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

// MARK: Help

public enum CLIHelp {
    public static let usage = """
    ameya — convert files on this Mac. Nothing is uploaded.

    Usage:
      ameya convert <files…> --to <format> [--out <folder>]
      ameya run <tool> <files…> [--out <folder>]
      ameya formats [file]        what this Mac can write, or what a file can become
      ameya tools                 tools you can use with "ameya run"
      ameya --install-help        how to type "ameya" in any Terminal window
      ameya --version

    Options:
      -t, --to <format>     the new format: jpeg, png, pdf, mp3, docx … (see "ameya formats")
      -o, --out <folder>    where to save (default: Downloads/Ameya)
          --json            print results as JSON, for scripts
      -h, --help            show this help

    Examples:
      ameya convert IMG_0042.heic --to jpeg
      ameya convert *.png --to webp --out ~/Desktop/web
      ameya run pdf.merge scan1.pdf scan2.pdf
      ameya formats report.docx

    Ameya never changes or replaces your files: results get new names, like "photo 2.jpg".
    Each file is read by its own sandboxed converter.

    Exit codes:
      0  everything worked
      1  some files couldn't be converted
      2  the command wasn't understood
      3  a file is missing or can't become that format
      4  Ameya isn't set up right (reinstall the app)
    """

    public static func install(executable: String) -> String {
        """
        To type "ameya" in any Terminal window, link it into your PATH (needs your password once):

          sudo mkdir -p /usr/local/bin
          sudo ln -sf "\(executable)" /usr/local/bin/ameya

        Then try: ameya --help

        If you move Ameya.app, run the second line again. To remove it: sudo rm /usr/local/bin/ameya
        """
    }
}
