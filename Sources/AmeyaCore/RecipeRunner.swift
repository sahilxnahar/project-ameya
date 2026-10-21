import Foundation

/// A recipe step that went wrong, said plainly: which step, and why.
public struct RecipeRunError: Error, Equatable, LocalizedError {
    public let step: Int
    public let of: Int
    public let title: String
    public let reason: String

    public init(step: Int, of: Int, title: String, reason: String) {
        self.step = step
        self.of = of
        self.title = title
        self.reason = reason
    }

    public var errorDescription: String? {
        "Step \(step) of \(of) (\(title)) didn't work: \(reason)"
    }
}

/// Runs a planned recipe on one file, one worker job per step.
///
/// In-between files live in a private scratch folder that is always removed afterwards; only
/// the last step writes to `destination`, so the output folder never sees half-made files.
/// The original is only ever read.
public enum RecipeRunner {
    /// Runs one step: converts `input` into a new file at `destination`. In the app this is a
    /// sandboxed worker job; tests pass a fake.
    public typealias Execute = @Sendable (
        _ step: PlannedRecipeStep, _ input: URL, _ destination: URL, _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult

    public static func run(
        _ steps: [PlannedRecipeStep],
        input: URL,
        destination: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        execute: Execute
    ) async throws -> ConversionResult {
        // Every step was "convert to the format it already has": the result is a plain copy.
        guard !steps.isEmpty else {
            do {
                try FileManager.default.copyItem(at: input, to: destination)
            } catch {
                throw WorkerError.outputExists(destination.lastPathComponent)
            }
            progress(1)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return ConversionResult(outputBytes: size, frames: 1, notes: [])
        }

        let scratch = temporaryDirectory.appendingPathComponent("ameya-recipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var current = input
        var notes: [ConversionNote] = []
        var last = ConversionResult(outputBytes: 0, frames: 0, notes: [])
        let count = Double(steps.count)
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            let isLast = index == steps.count - 1
            let output = isLast
                ? destination
                : scratch.appendingPathComponent("step \(step.number).\(step.request.target.preferredExtension)")
            let done = Double(index)
            do {
                last = try await execute(step, current, output) { value in
                    progress((done + min(max(value, 0), 1)) / count)
                }
            } catch WorkerError.cancelled {
                throw WorkerError.cancelled
            } catch is CancellationError {
                throw WorkerError.cancelled
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw RecipeRunError(step: step.number, of: steps.last?.number ?? steps.count, title: step.title, reason: reason)
            }
            if last.outputNames != nil {
                throw RecipeRunError(step: step.number, of: steps.last?.number ?? steps.count, title: step.title,
                                     reason: "it made several files, and a recipe makes one.")
            }
            for note in last.notes where !notes.contains(note) { notes.append(note) }
            // The previous in-between file is no longer needed.
            if current != input { try? FileManager.default.removeItem(at: current) }
            current = output
        }
        progress(1)
        last.notes = notes
        return last
    }
}
