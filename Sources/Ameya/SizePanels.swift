import AmeyaCore
import SwiftUI

// Settings panels for the size presets. Each is keyboard-first: Tab moves between fields, the up
// and down arrows step a time by one second, Return runs, Escape (from the sheet) cancels.
// Every control has a VoiceOver label, and nothing animates.

// MARK: Trim & mute

struct TrimMutePanel: View {
    let done: (ConversionOptions) -> Void
    @State private var start = "0:00"
    @State private var end = ""
    @State private var mute = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimeField(label: "Start", text: $start, placeholder: "0:00",
                      hint: "Where the copy begins, in minutes and seconds, like 1:30.")
            TimeField(label: "End", text: $end, placeholder: "End of video",
                      hint: "Where the copy ends, like 2:45. Leave empty to keep everything to the end.")
            Toggle("Remove the sound", isOn: $mute)
                .accessibilityHint("The copy will be silent.")
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Can't make the copy yet: \(problem)")
            }
            HStack {
                Spacer()
                Button(mute && !isTrimmed ? "Remove sound" : "Trim") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                    .accessibilityHint("Makes the copy. The original video isn't changed.")
            }
        }
    }

    private var startSeconds: Double? { TimeText.seconds(start) ?? (start.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : nil) }
    private var endSeconds: Double?? {
        end.trimmingCharacters(in: .whitespaces).isEmpty ? .some(nil) : TimeText.seconds(end).map { .some($0) }
    }
    private var isTrimmed: Bool { (startSeconds ?? 0) > 0 || (endSeconds ?? nil) != nil }

    private var problem: String? {
        guard let startSeconds else { return "The start isn't a time like 1:30." }
        guard let endSeconds else { return "The end isn't a time like 2:45." }
        if let endSeconds, endSeconds <= startSeconds { return "The end needs to be after the start." }
        if !isTrimmed && !mute { return "Choose a start or end time, or remove the sound." }
        return nil
    }

    private func finish() {
        guard problem == nil, let startSeconds, let endSeconds else { return }
        done(ConversionOptions(video: VideoEdits(trimStart: startSeconds > 0 ? startSeconds : nil, trimEnd: endSeconds, mute: mute)))
    }
}

/// A "m:ss" text field with a ±1 second stepper; the arrow keys step too.
private struct TimeField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String

    var body: some View {
        HStack {
            Text(label).frame(width: 44, alignment: .leading).accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .accessibilityLabel("\(label) time")
                .accessibilityHint(hint + " Up and down arrows change it by one second.")
                .onKeyPress(.upArrow) { step(1); return .handled }
                .onKeyPress(.downArrow) { step(-1); return .handled }
            Stepper(label, onIncrement: { step(1) }, onDecrement: { step(-1) })
                .labelsHidden()
                .accessibilityLabel("\(label) time, one second at a time")
                .accessibilityValue(TimeText.spoken(TimeText.seconds(text)) ?? placeholder)
        }
    }

    private func step(_ delta: Double) {
        let current = TimeText.seconds(text) ?? 0
        text = TimeText.format(max(0, current + delta))
    }
}

/// Reads and writes times as people type them: "90", "1:30", "1:02:03", "1:30.5".
enum TimeText {
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            if index > 0, value >= 60 { return nil } // "1:75" is a typo, not 2:15
            if index < parts.count - 1, value != value.rounded() { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func format(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let tenths = Int(((seconds - Double(whole)) * 10).rounded())
        let (h, m, s) = (whole / 3600, whole / 60 % 60, whole % 60)
        let clock = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return tenths > 0 ? "\(clock).\(tenths)" : clock
    }

    /// "1 minute 30 seconds" for VoiceOver.
    static func spoken(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        let whole = Int(seconds)
        var parts: [String] = []
        if whole >= 3600 { parts.append("\(whole / 3600) hour\(whole / 3600 == 1 ? "" : "s")") }
        if whole % 3600 >= 60 { parts.append("\(whole / 60 % 60) minute\(whole / 60 % 60 == 1 ? "" : "s")") }
        if whole % 60 > 0 || parts.isEmpty { parts.append("\(whole % 60) second\(whole % 60 == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}

// MARK: Custom size

struct CustomSizePanel: View {
    enum Unit: String, CaseIterable, Identifiable {
        case kb = "KB", mb = "MB"
        var id: String { rawValue }
        var bytes: Double { self == .kb ? 1_000 : 1_000_000 }
    }

    let kind: SizeKind
    let writable: Set<FileFormat>
    let choice: CustomSizeChoice
    let done: (ConversionOptions) -> Void
    @State private var amount: String
    @State private var unit: Unit
    /// `nil` keeps each video's own format.
    @State private var format: FileFormat?

    init(kind: SizeKind, writable: Set<FileFormat>, choice: CustomSizeChoice, done: @escaping (ConversionOptions) -> Void) {
        self.kind = kind
        self.writable = writable
        self.choice = choice
        self.done = done
        switch kind {
        case .photo: (_amount, _unit, _format) = (State(initialValue: "500"), State(initialValue: .kb), State(initialValue: .jpeg))
        case .video: (_amount, _unit, _format) = (State(initialValue: "25"), State(initialValue: .mb), State(initialValue: .mp4))
        case .pdf: (_amount, _unit, _format) = (State(initialValue: "2"), State(initialValue: .mb), State(initialValue: .pdf))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("At most").accessibilityHidden(true)
                TextField("Size", text: $amount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .accessibilityLabel("Largest file size")
                    .accessibilityHint("A number. Choose kilobytes or megabytes next to it.")
                Picker("Unit", selection: $unit) {
                    ForEach(Unit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
                .accessibilityLabel("Size unit")
            }
            if kind != .pdf {
                Picker("Format", selection: $format) {
                    ForEach(formats, id: \.self) { option in
                        Text(option?.displayName ?? "Same as the original").tag(option)
                    }
                }
                .accessibilityHint("The kind of file to make.")
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Make it smaller") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bytes == nil)
                    .accessibilityHint("Makes the copy. The original isn't changed.")
            }
        }
    }

    private var formats: [FileFormat?] {
        switch kind {
        case .photo: [FileFormat.jpeg, .heic, .webp].filter { writable.contains($0) }
        case .video: [nil, .mp4, .mov] + (FFmpegAvailability.isAvailable ? [.mkv, .webm] : [])
        case .pdf: [.pdf]
        }
    }

    private var explanation: String {
        switch kind {
        case .photo: "Ameya lowers the quality first, then the size in pixels, until each photo fits."
        case .video: "Ameya picks the sharpest picture that fits. Very long videos may need trimming first."
        case .pdf: "Scanned and photo pages become smaller pictures; text pages stay sharp and selectable."
        }
    }

    private var minimum: Int {
        switch kind {
        case .photo: 5_000
        case .video: 100_000
        case .pdf: 10_000
        }
    }

    private var bytes: Int? {
        guard let value = Double(amount.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0 else { return nil }
        let bytes = value * unit.bytes
        guard bytes >= Double(minimum), bytes <= 100_000_000_000 else { return nil }
        return Int(bytes)
    }

    private var problem: String? {
        guard bytes == nil else { return nil }
        let smallest = ByteCountFormatter.string(fromByteCount: Int64(minimum), countStyle: .file)
        return "Type a size of at least \(smallest), like 2 MB or 500 KB."
    }

    private func finish() {
        guard let bytes else { return }
        switch kind {
        case .photo:
            choice.imageTarget = format ?? .jpeg
            done(ConversionOptions(image: ImageEdits(targetBytes: bytes)))
        case .video:
            choice.videoTarget = format
            done(ConversionOptions(video: VideoEdits(targetBytes: bytes)))
        case .pdf:
            done(ConversionOptions(pdf: .compress(quality: 0.7, targetBytes: bytes)))
        }
    }
}
