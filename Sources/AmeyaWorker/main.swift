import AmeyaCore
import AmeyaEngines
import Foundation

// One conversion per process. Source bytes arrive on stdin, the result leaves on stdout,
// and status lines go to stderr (see WorkerProtocol). The worker never opens files by path.

let maxInputBytes = 1 << 30 // 1 GiB

func emit(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func fail(_ message: String) -> Never {
    emit(WorkerProtocol.errorPrefix + message.replacingOccurrences(of: "\n", with: " "))
    exit(2)
}

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: WorkerProtocol.requestArgument),
      flag + 1 < arguments.count,
      let request = try? WorkerProtocol.decodeRequest(arguments[flag + 1]) else {
    fail("The converter received an invalid request.")
}

#if DEBUG
// Test hooks for timeout, cancellation and crash isolation. Compiled out of release builds.
if let delay = request.options.debugDelaySeconds { Thread.sleep(forTimeInterval: delay) }
if request.options.debugCrash == true { abort() }
#endif

let input: Data
do {
    input = try FileHandle.standardInput.read(upToCount: maxInputBytes + 1) ?? Data()
} catch {
    fail("Couldn't read the file.")
}
guard !input.isEmpty else { fail("The file is empty.") }
guard input.count <= maxInputBytes else { fail("The file is larger than 1 GB.") }
emit(WorkerProtocol.progressPrefix + "0.05")

do {
    let (output, result) = try ImageConverter.convert(input, request: request) { fraction in
        emit(WorkerProtocol.progressPrefix + String(format: "%.3f", fraction))
    }
    try FileHandle.standardOutput.write(contentsOf: output)
    emit(WorkerProtocol.donePrefix + (try WorkerProtocol.encode(result)))
    exit(0)
} catch let error as LocalizedError {
    fail(error.errorDescription ?? "The conversion failed.")
} catch {
    fail("The conversion failed.")
}
