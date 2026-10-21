import AmeyaCore
import AmeyaEngines
import Foundation

// One conversion per process. Source bytes arrive on stdin, the result leaves on stdout,
// and status lines go to stderr (see WorkerProtocol). Before reading any input the worker locks
// its own sandbox down to a private scratch folder (WorkerSandbox), so it *can't* open the user's
// files by path: it copies stdin into that folder, converts there, and deletes it.

let maxInputBytes: Int64 = 20 << 30 // 20 GiB
let chunkSize = 4 << 20 // 4 MiB

func emit(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func fail(_ message: String, scratch: URL? = nil) -> Never {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    emit(WorkerProtocol.errorPrefix + message.replacingOccurrences(of: "\n", with: " "))
    exit(2)
}

// Lead a process group of our own so the app can stop helpers we start (FFmpeg) along with us.
setpgid(0, 0)

/// A private folder for this job; the app removes ones left behind by killed workers (see JobStore).
func makeScratch() -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("ameya-worker-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
    let temporary = scratch.appendingPathComponent("tmp", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    } catch {
        fail("Couldn't create a working folder.")
    }
    // Frameworks that make temporary files put them inside the scratch folder, the only writable place.
    setenv("TMPDIR", temporary.path + "/", 1)
    return scratch
}

/// Narrows this process's sandbox to the scratch folder before any input is read (WorkerSandbox).
func lockDown(_ scratch: URL) {
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    do {
        _ = try WorkerSandbox.lockDown(scratch: scratch, bundle: WorkerSandbox.codeFolder(for: executable),
                                       helper: FFmpegAvailability.helperURL, userFolder: WorkerSandbox.realDownloads)
    } catch {
        fail((error as? LocalizedError)?.errorDescription ?? "The converter couldn't lock itself down.", scratch: scratch)
    }
}

let arguments = CommandLine.arguments

// The self-test's proof that a locked-down worker can't reach the user's files by path.
if let flag = arguments.firstIndex(of: SandboxProbe.argument), flag + 1 < arguments.count {
    let scratch = makeScratch()
    lockDown(scratch)
    let probe = SandboxProbe.run(target: URL(fileURLWithPath: arguments[flag + 1]), scratch: scratch)
    try? FileManager.default.removeItem(at: scratch)
    emit(SandboxProbe.prefix + String(decoding: (try? JSONEncoder().encode(probe)) ?? Data(), as: UTF8.self))
    exit(0)
}

guard let flag = arguments.firstIndex(of: WorkerProtocol.requestArgument),
      flag + 1 < arguments.count,
      var request = try? WorkerProtocol.decodeRequest(arguments[flag + 1]) else {
    fail("The converter received an invalid request.")
}

let scratch = makeScratch()
lockDown(scratch)

// Nobody would be left to enforce time, memory and disk limits if whoever started us died.
let parent = getppid()
Thread.detachNewThread {
    while getppid() == parent { sleep(1) }
    try? FileManager.default.removeItem(at: scratch)
    exit(3)
}

// A PDF password arrives ahead of the file on stdin, never on the command line (WorkerSecret).
if request.options.secretOnStdin == true {
    do {
        WorkerSecret.restore(try WorkerSecret.receive(from: FileHandle.standardInput), into: &request)
    } catch {
        fail("The converter couldn't read the password.", scratch: scratch)
    }
}

#if DEBUG
// Test hooks for timeout, cancellation, crash isolation and resource limits. Compiled out of release builds.
if let delay = request.options.debugDelaySeconds { try? await Task.sleep(for: .seconds(delay)) }
if request.options.debugCrash == true { abort() }
if let bytes = request.options.debugAllocateBytes {
    // Touch every page so it counts towards the physical footprint, then wait to be stopped.
    var held: [UnsafeMutableRawPointer] = []
    var total = 0
    while total < bytes {
        let size = min(64 << 20, bytes - total)
        let block = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        memset(block, 0xA5, size)
        held.append(block)
        total += size
    }
    try? await Task.sleep(for: .seconds(60))
    withExtendedLifetime(held) {}
}
if request.options.debugStartHelper == true, let helper = FFmpegAvailability.helperURL {
    // FFmpeg opening a FIFO nobody writes to blocks forever, like a helper that outlives its worker.
    let fifo = scratch.appendingPathComponent("never")
    mkfifo(fifo.path, 0o600)
    let process = Process()
    process.executableURL = helper
    process.arguments = ["-nostdin", "-loglevel", "quiet", "-i", fifo.path, "-f", "null", "-"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("helper didn't start: \(error.localizedDescription)", scratch: scratch) }
    fail("helper \(process.processIdentifier)", scratch: scratch)
}
if request.options.debugWriteEndlessly == true {
    let chunk = Data(repeating: 0x41, count: 1 << 20)
    while true { try? FileHandle.standardOutput.write(contentsOf: chunk) }
}
#endif

var inputs: [URL] = []
if let formats = request.inputs, formats.count > 1 {
    // Several files arrive as a strict TAR stream named 0.ext, 1.ext, … in order.
    let folder = scratch.appendingPathComponent("inputs", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let names = try TarStream.extract(
            from: FileHandle.standardInput, into: folder,
            limits: TarStream.Limits(maxEntries: 1_000, maxTotalBytes: maxInputBytes)
        )
        let expected = formats.enumerated().map { "\($0.offset).\($0.element.preferredExtension)" }
        guard names == expected else { fail("The converter received an unexpected set of files.", scratch: scratch) }
        inputs = names.map { folder.appendingPathComponent($0) }
    } catch {
        fail((error as? LocalizedError)?.errorDescription ?? "Couldn't read the files.", scratch: scratch)
    }
} else {
    // Copy stdin to a file. AVFoundation needs a file, and streaming keeps memory flat for large videos.
    let inputExtension = request.source?.preferredExtension ?? "bin"
    let input = scratch.appendingPathComponent("input.\(inputExtension)")
    do {
        FileManager.default.createFile(atPath: input.path, contents: nil)
        let writer = try FileHandle(forWritingTo: input)
        var total: Int64 = 0
        while let chunk = try FileHandle.standardInput.read(upToCount: chunkSize), !chunk.isEmpty {
            total += Int64(chunk.count)
            guard total <= maxInputBytes else { fail("The file is larger than 20 GB.", scratch: scratch) }
            try writer.write(contentsOf: chunk)
        }
        try writer.close()
        guard total > 0 else { fail("The file is empty.", scratch: scratch) }
    } catch {
        fail("Couldn't read the file.", scratch: scratch)
    }
    inputs = [input]
}
emit(WorkerProtocol.progressPrefix + "0.02")

do {
    var (outputs, result) = try await Engine.run(inputs: inputs, request: request, scratch: scratch) { fraction in
        emit(WorkerProtocol.progressPrefix + String(format: "%.3f", fraction))
    }
    if let names = result.outputNames {
        // Several files leave as a TAR stream; outputBytes is then the stream's size.
        guard names.count == outputs.count else { fail("The converter produced an unexpected set of files.", scratch: scratch) }
        result.outputBytes = Int(try TarStream.write(files: Array(zip(names, outputs)).map { (name: $0.0, url: $0.1) },
                                                     to: FileHandle.standardOutput))
    } else {
        guard outputs.count == 1 else { fail("The converter produced an unexpected set of files.", scratch: scratch) }
        let reader = try FileHandle(forReadingFrom: outputs[0])
        while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
            try FileHandle.standardOutput.write(contentsOf: chunk)
        }
        try reader.close()
    }
    try? FileManager.default.removeItem(at: scratch)
    emit(WorkerProtocol.donePrefix + (try WorkerProtocol.encode(result)))
    exit(0)
} catch let error as LocalizedError {
    fail(error.errorDescription ?? "The conversion failed.", scratch: scratch)
} catch {
    fail("The conversion failed: \(error.localizedDescription)", scratch: scratch)
}
