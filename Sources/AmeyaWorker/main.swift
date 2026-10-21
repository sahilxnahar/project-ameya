import AmeyaCore
import AmeyaEngines
import Foundation

// One conversion per process. Source bytes arrive on stdin, the result leaves on stdout,
// and status lines go to stderr (see WorkerProtocol). The worker never opens the user's files
// by path: it copies stdin into a private scratch folder, converts there, and deletes it.

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

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: WorkerProtocol.requestArgument),
      flag + 1 < arguments.count,
      let request = try? WorkerProtocol.decodeRequest(arguments[flag + 1]) else {
    fail("The converter received an invalid request.")
}

#if DEBUG
// Test hooks for timeout, cancellation and crash isolation. Compiled out of release builds.
if let delay = request.options.debugDelaySeconds { try? await Task.sleep(for: .seconds(delay)) }
if request.options.debugCrash == true { abort() }
#endif

// The app cleans up scratch folders left behind by killed workers (see JobStore).
let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("ameya-worker-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
} catch {
    fail("Couldn't create a working folder.")
}

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
emit(WorkerProtocol.progressPrefix + "0.02")

do {
    let (output, result) = try await Engine.convert(input: input, request: request, scratch: scratch) { fraction in
        emit(WorkerProtocol.progressPrefix + String(format: "%.3f", fraction))
    }
    let reader = try FileHandle(forReadingFrom: output)
    while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
        try FileHandle.standardOutput.write(contentsOf: chunk)
    }
    try reader.close()
    try? FileManager.default.removeItem(at: scratch)
    emit(WorkerProtocol.donePrefix + (try WorkerProtocol.encode(result)))
    exit(0)
} catch let error as LocalizedError {
    fail(error.errorDescription ?? "The conversion failed.", scratch: scratch)
} catch {
    fail("The conversion failed: \(error.localizedDescription)", scratch: scratch)
}
