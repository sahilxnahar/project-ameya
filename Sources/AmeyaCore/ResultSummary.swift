import Foundation

/// Size before → after, in friendly words: "62% smaller", "About the same size", "3× bigger".
public struct SizeChange: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case smaller(percent: Int)
        case bigger(percent: Int)
        case same
    }

    public let before: Int64
    public let after: Int64

    public init(before: Int64, after: Int64) {
        self.before = max(0, before)
        self.after = max(0, after)
    }

    public var direction: Direction {
        guard before > 0 else { return .same }
        let exact = (1 - Double(after) / Double(before)) * 100
        // Under one percent either way isn't worth mentioning.
        guard abs(exact) >= 1 else { return .same }
        let percent = Int(exact.rounded())
        if percent >= 1 { return .smaller(percent: after > 0 ? min(percent, 99) : 100) }
        if percent <= -1 { return .bigger(percent: -percent) }
        return .same
    }

    /// "62% smaller". Large growth reads better as a multiple: "3× bigger".
    public var description: String {
        switch direction {
        case .smaller(let percent): return "\(percent)% smaller"
        case .same: return "About the same size"
        case .bigger(let percent):
            guard percent >= 100 else { return "\(percent)% bigger" }
            let times = Double(after) / Double(before)
            let rounded = times >= 10 ? times.rounded() : (times * 10).rounded() / 10
            let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return "\(text)× bigger"
        }
    }

    /// "1.2 MB → 450 KB".
    public var sizes: String { "\(Self.format(before)) → \(Self.format(after))" }

    /// For VoiceOver: "1.2 MB before, 450 KB after, 62% smaller".
    public var spoken: String { "\(Self.format(before)) before, \(Self.format(after)) after, \(description)" }

    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// How one finished job went, for the batch headline.
public enum BatchOutcome: Equatable, Sendable {
    case done(before: Int64, after: Int64)
    case failed
    case cancelled
}

/// The headline when a batch finishes: "Done! 4 files, 12 MB smaller".
public struct BatchSummary: Equatable, Sendable {
    public let succeeded: Int
    public let failed: Int
    public let saved: Int64

    public init(_ outcomes: [BatchOutcome]) {
        var succeeded = 0, failed = 0
        var before: Int64 = 0, after: Int64 = 0
        for outcome in outcomes {
            switch outcome {
            case .done(let b, let a):
                succeeded += 1
                before += b
                after += a
            case .failed: failed += 1
            case .cancelled: break
            }
        }
        self.succeeded = succeeded
        self.failed = failed
        let change = SizeChange(before: before, after: after)
        if case .smaller = change.direction { saved = before - after } else { saved = 0 }
    }

    /// Something worth a small celebration: at least one file made, nothing went wrong.
    public var isCelebration: Bool { succeeded > 0 && failed == 0 }

    public var headline: String {
        let files = "\(succeeded) file\(succeeded == 1 ? "" : "s")"
        switch (succeeded, failed) {
        case (0, 0): return "Nothing was converted."
        case (0, 1): return "That one didn't work. The reason is below."
        case (0, _): return "None of those worked. The reasons are below."
        case (_, 0):
            return saved > 0 ? "Done! \(files), \(SizeChange.format(saved)) smaller" : "Done! \(files) ready"
        default:
            return "\(succeeded) done, \(failed) didn't work. Details are below."
        }
    }
}

/// Whether "Undo" may move an output to the Trash: only when the very file Ameya made is still
/// where Ameya put it. A moved, renamed or replaced file is left alone.
public enum UndoCheck {
    /// - Parameters:
    ///   - exists: a file or folder is at the output path.
    ///   - currentBytes: its size now (`nil` for folders, which aren't size-checked).
    ///   - recordedBytes: the size Ameya wrote.
    public static func canMoveToTrash(exists: Bool, currentBytes: Int64?, recordedBytes: Int64) -> Bool {
        guard exists else { return false }
        guard let currentBytes else { return true }
        return currentBytes == recordedBytes
    }
}

/// Whether to play the end-of-batch burst. Reduce Motion always wins.
public enum CelebrationPolicy {
    public static func shouldCelebrate(setting: Bool, reduceMotion: Bool, summary: BatchSummary) -> Bool {
        setting && !reduceMotion && summary.isCelebration
    }
}
