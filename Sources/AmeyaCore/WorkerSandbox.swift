import Darwin
import Foundation

// Deprecated in the SDK headers but supported; Chromium and WebKit tighten their helpers the same way.
@_silgen_name("sandbox_init_with_parameters")
private func sandbox_init_with_parameters(
    _ profile: UnsafePointer<CChar>, _ flags: UInt64,
    _ parameters: UnsafePointer<UnsafePointer<CChar>?>?,
    _ errorBuffer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("sandbox_free_error")
private func sandbox_free_error(_ errorBuffer: UnsafeMutablePointer<CChar>)

/// Makes sure the worker can't reach the user's files by path before it reads a byte of input.
///
/// A bug in a parser (ImageIO, PDFKit, libarchive, FFmpeg …) must not reach Downloads, the chosen
/// output folder or the files the user dropped, all of which the *app's* sandbox can open. Two layers:
///
/// 1. In the app, workers are started by the `AmeyaLauncher` XPC service, whose own sandbox has
///    no file entitlements at all; workers inherit that sandbox, never the app's. macOS refuses a
///    second profile inside an App Sandbox (`sandbox_init` fails with EPERM, even for an empty one),
///    so there the worker *verifies* it can't open Downloads and stops if it can.
/// 2. Wherever the process isn't sandboxed yet (tests, development), the worker applies the strict
///    profile below, which only ever narrows access:
///    - reads only system code and data (`/System`, `/usr`, `/Library`, system asset stores), its
///      own code folder and its scratch folder; file *metadata* stays visible, contents don't;
///    - writes only inside its scratch folder (plus `/dev/null`); the output leaves on the stdout
///      descriptor it was handed, which needs no path access;
///    - no network, and no program can start except the bundled FFmpeg helper (which inherits it).
public enum WorkerSandbox {
    /// How the worker ended up contained.
    public enum Containment: Equatable, Sendable {
        /// The strict profile was applied.
        case profile
        /// Already in a sandbox (the launcher's) that was checked to have no access to Downloads.
        case inheritedWithoutUserFiles
    }

    /// System locations frameworks, fonts, codecs and on-device models are read from.
    public static let systemReadPaths = [
        "/System", "/usr", "/Library", "/private/etc",
        "/private/var/db/timezone", "/private/var/db/dyld", "/private/var/MobileAsset",
        "/dev",
    ]

    /// The SBPL profile. Parameters are passed separately, so no path is ever spliced into it.
    public static func profile(allowsHelper: Bool) -> String {
        let reads = systemReadPaths.map { "(subpath \"\($0)\")" }.joined(separator: " ")
            + (allowsHelper ? " (literal (param \"HELPER\"))" : "")
        return """
        (version 1)
        (allow default)
        (deny file-read* (require-not (require-any \(reads) (subpath (param "SCRATCH")) (subpath (param "BUNDLE")))))
        (allow file-read-metadata)
        (deny file-write* (require-not (require-any (subpath (param "SCRATCH")) (subpath (param "STAGING")) (literal "/dev/null") (literal "/dev/dtracehelper"))))
        (deny network*)
        (deny process-exec*\(allowsHelper ? " (require-not (literal (param \"HELPER\")))" : ""))
        """
    }

    public enum Failure: Error, LocalizedError {
        case unavailable(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable(let detail): "The converter couldn't lock itself down (\(detail)), so it stopped."
            }
        }
    }

    /// Contains this process and everything it starts, irreversibly, or throws (the worker then stops).
    /// - Parameters:
    ///   - scratch: the job's private folder (created already).
    ///   - bundle: the folder holding the worker's own code.
    ///   - helper: the FFmpeg helper allowed to run, if any.
    ///   - userFolder: a folder the app can read but a worker must not (the real Downloads).
    public static func lockDown(scratch: URL, bundle: URL, helper: URL?, userFolder: URL) throws -> Containment {
        do {
            try apply(scratch: scratch, bundle: bundle, helper: helper)
            return .profile
        } catch {
            // Already sandboxed: acceptable only if that sandbox keeps user files out of reach.
            guard !canOpen(userFolder) else {
                throw Failure.unavailable("it was started with access to your files")
            }
            return .inheritedWithoutUserFiles
        }
    }

    /// Whether this process can list `folder`'s contents.
    public static func canOpen(_ folder: URL) -> Bool {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// The user's real Downloads folder (inside a sandbox `FileManager` would give the container's).
    public static var realDownloads: URL {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Applies the strict profile. Fails when the process is already in an App Sandbox.
    static func apply(scratch: URL, bundle: URL, helper: URL?) throws {
        // Foundation's atomic writes stage new files in the volume's item replacement folder
        // (…/T/TemporaryItems) and rename them into scratch; writing there is allowed, reading isn't.
        let staging = (try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: scratch, create: true))
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        let stagingParent = try staging.map { try realPath($0.deletingLastPathComponent()) } ?? realPath(scratch)
        var values = ["SCRATCH": try realPath(scratch), "BUNDLE": try realPath(bundle), "STAGING": stagingParent]
        if let helper { values["HELPER"] = try realPath(helper) }
        let flat = values.flatMap { [$0.key, $0.value] }
        let strings = flat.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var parameters: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
        parameters.append(nil)
        var error: UnsafeMutablePointer<CChar>?
        let status = parameters.withUnsafeBufferPointer {
            sandbox_init_with_parameters(profile(allowsHelper: helper != nil), 0, $0.baseAddress, &error)
        }
        if status != 0 {
            let detail = error.map { String(cString: $0) } ?? "status \(status)"
            if let error { sandbox_free_error(error) }
            throw Failure.unavailable(detail)
        }
    }

    /// The folder whose contents the worker may read as its own code: the bundle's `Contents`
    /// for an app, or the build folder for a bare executable (tests).
    public static func codeFolder(for executable: URL) -> URL {
        let folder = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        return folder.lastPathComponent == "MacOS" ? folder.deletingLastPathComponent() : folder
    }

    /// The canonical path the kernel matches against (`/var` → `/private/var`, no symlinks).
    static func realPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else { throw Failure.unavailable("no folder at \(url.lastPathComponent)") }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// What a sandboxed worker could and couldn't do, from `--probe-sandbox` (the self-test's proof).
public struct SandboxProbe: Codable, Equatable, Sendable {
    /// Opening and reading the target file by path.
    public var readFile: Bool
    /// Listing the folder that holds the target file.
    public var listFolder: Bool
    /// Creating a new file in that folder.
    public var writeBesideFile: Bool
    /// Creating a file in its own scratch folder (must work).
    public var writeScratch: Bool
    /// Starting `/bin/sh`. Denied by the strict profile; the launcher's App Sandbox allows system
    /// programs, which then run in that same sandbox (no user files), so it isn't part of `isContained`.
    public var runProgram: Bool

    public init(readFile: Bool, listFolder: Bool, writeBesideFile: Bool, writeScratch: Bool, runProgram: Bool) {
        self.readFile = readFile
        self.listFolder = listFolder
        self.writeBesideFile = writeBesideFile
        self.writeScratch = writeScratch
        self.runProgram = runProgram
    }

    /// The sandbox held: nothing outside scratch was reachable, and scratch still worked.
    public var isContained: Bool { !readFile && !listFolder && !writeBesideFile && writeScratch }

    public static let argument = "--probe-sandbox"
    public static let prefix = "AMEYA:probe:"

    /// Runs the probes from inside the (already tightened) worker.
    public static func run(target: URL, scratch: URL) -> SandboxProbe {
        let folder = target.deletingLastPathComponent()
        var readFile = false
        let descriptor = open(target.path, O_RDONLY)
        if descriptor >= 0 {
            var byte: UInt8 = 0
            readFile = read(descriptor, &byte, 1) >= 0
            close(descriptor)
        }
        let listFolder = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
        let outside = folder.appendingPathComponent(".ameya-probe-\(UUID().uuidString)")
        let writeBesideFile = FileManager.default.createFile(atPath: outside.path, contents: Data("x".utf8))
        if writeBesideFile { try? FileManager.default.removeItem(at: outside) }
        let inside = scratch.appendingPathComponent("probe")
        let writeScratch = FileManager.default.createFile(atPath: inside.path, contents: Data("x".utf8))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "exit 0"]
        var runProgram = false
        if (try? shell.run()) != nil {
            shell.waitUntilExit()
            runProgram = shell.terminationReason == .exit && shell.terminationStatus == 0
        }
        return SandboxProbe(readFile: readFile, listFolder: listFolder, writeBesideFile: writeBesideFile,
                            writeScratch: writeScratch, runProgram: runProgram)
    }
}
