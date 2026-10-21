import Darwin
import Foundation

/// Keeps passwords off the worker's command line, where any process of the same user could read
/// them. `WorkerRunner` takes the password out of the request, marks it `secretOnStdin`, and sends
/// it ahead of the file on the worker's stdin: a 4-byte big-endian length, then UTF-8 bytes.
/// Nothing is written to disk or logged.
public enum WorkerSecret {
    /// Longest password accepted, in UTF-8 bytes.
    public static let maxBytes = 4_096

    public enum Failure: Error, Equatable, LocalizedError {
        case malformed
        public var errorDescription: String? { "The converter couldn't read the password." }
    }

    /// Moves the request's password out of it. Returns `nil` when it carries none.
    public static func extract(from request: inout ConversionRequest) -> String? {
        guard let action = request.options.pdf, let secret = action.secret else { return nil }
        request.options.pdf = action.replacingSecret(with: "")
        request.options.secretOnStdin = true
        return secret
    }

    /// Puts a password read from stdin back into the request.
    public static func restore(_ secret: String, into request: inout ConversionRequest) {
        request.options.pdf = request.options.pdf?.replacingSecret(with: secret)
        request.options.secretOnStdin = nil
    }

    static func header(for secret: String) throws -> Data {
        let bytes = Data(secret.utf8)
        guard bytes.count <= maxBytes else { throw Failure.malformed }
        var length = UInt32(bytes.count).bigEndian
        return Data(bytes: &length, count: 4) + bytes
    }

    /// A pipe to use as the worker's stdin: the secret header, then everything in `source`.
    /// A background thread feeds it from a duplicate of `source`'s descriptor, so the caller may
    /// close `source` at any time. Close the returned handle once the worker has exited; the
    /// feeder then stops (EPIPE, no signal) if the worker didn't read everything.
    public static func stdin(prefixing secret: String, to source: FileHandle) throws -> FileHandle {
        let header = try header(for: secret)
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw Failure.malformed }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        let input = dup(source.fileDescriptor)
        guard input >= 0 else {
            close(readEnd)
            close(writeEnd)
            throw Failure.malformed
        }
        let thread = Thread {
            defer {
                close(input)
                close(writeEnd)
            }
            guard writeAll(header, to: writeEnd) else { return }
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                guard writeAll(Data(buffer[0..<count]), to: writeEnd) else { return }
            }
        }
        thread.name = "Ameya stdin feeder"
        thread.start()
        return FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// Reads the header from the start of `handle` (the worker's stdin), consuming exactly its bytes.
    public static func receive(from handle: FileHandle) throws -> String {
        let lengthBytes = try readExactly(4, from: handle.fileDescriptor)
        let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
        guard length <= maxBytes else { throw Failure.malformed }
        let bytes = try readExactly(length, from: handle.fileDescriptor)
        guard let secret = String(data: bytes, encoding: .utf8) else { throw Failure.malformed }
        return secret
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + offset, count - offset) }
            if got < 0 && errno == EINTR { continue }
            guard got > 0 else { throw Failure.malformed }
            offset += got
        }
        return data
    }
}
