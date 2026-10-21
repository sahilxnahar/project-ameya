import AmeyaCore
import SwiftUI

// Settings panels for the audio and video tools. Keyboard-first like the size panels: Tab moves
// between controls, Return runs, Escape (from the sheet) cancels. Every control has a VoiceOver
// label and hint, wording stays plain, and nothing animates.

/// The Return-key button at the bottom of every panel.
private struct RunButton: View {
    let title: String
    let hint: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(title, action: action)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
                .accessibilityHint(hint + " The original isn't changed.")
        }
    }
}

/// A short explanation under a control.
private struct Explanation: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A "m:ss" time field; empty means `placeholder`'s meaning. Shows a problem when it can't be read.
private struct TimeEntry: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let hint: String

    var body: some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading).accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .accessibilityLabel("\(label) time")
                .accessibilityHint(hint)
        }
    }
}

// MARK: Even volume

struct EvenVolumePanel: View {
    let finish: (MediaTool) -> Void
    @State private var target: LoudnessTarget = .podcast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Make it right for", selection: $target) {
                ForEach(LoudnessTarget.allCases, id: \.self) { target in
                    Text("\(target.title) (\(Int(target.lufs)) LUFS)").tag(target)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint("How loud the copy should be overall.")
            Explanation(text: "Quiet recordings get louder and loud ones quieter. The loudest moments are held back gently so nothing distorts.")
            RunButton(title: "Make even", hint: "Makes a copy at this loudness.") { finish(.evenVolume(target)) }
        }
    }
}

// MARK: Fade

struct FadePanel: View {
    let finish: (MediaTool) -> Void
    @State private var fadeIn = 2.0
    @State private var fadeOut = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper("Fade in: \(Self.seconds(fadeIn))", value: $fadeIn, in: 0...30, step: 0.5)
                .accessibilityValue(Self.seconds(fadeIn))
                .accessibilityHint("How long the start takes to rise from silence. Zero for no fade in.")
            Stepper("Fade out: \(Self.seconds(fadeOut))", value: $fadeOut, in: 0...30, step: 0.5)
                .accessibilityValue(Self.seconds(fadeOut))
                .accessibilityHint("How long the end takes to fall to silence. Zero for no fade out.")
            RunButton(title: "Fade", hint: "Makes a copy with these fades.", disabled: fadeIn == 0 && fadeOut == 0) {
                finish(.fade(inSeconds: fadeIn, outSeconds: fadeOut))
            }
        }
    }

    static func seconds(_ value: Double) -> String {
        value == 0 ? "none" : value == 1 ? "1 second" : "\(value.formatted()) seconds"
    }
}

// MARK: Trim sound

struct TrimSoundPanel: View {
    let finish: (MediaTool) -> Void
    @State private var start = "0:00"
    @State private var end = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimeEntry(label: "Start", text: $start, placeholder: "0:00", hint: "Where the copy begins, like 1:30.")
            TimeEntry(label: "End", text: $end, placeholder: "End of sound",
                      hint: "Where the copy ends, like 2:45. Leave empty to keep everything to the end.")
            if let problem { Explanation(text: problem).accessibilityLabel("Can't trim yet: \(problem)") }
            RunButton(title: "Trim", hint: "Makes the trimmed copy.", disabled: problem != nil) {
                finish(.trimAudio(start: startSeconds.flatMap { $0 > 0 ? $0 : nil }, end: endSeconds ?? nil))
            }
        }
    }

    private var startSeconds: Double? { start.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : TimeText.seconds(start) }
    private var endSeconds: Double?? { end.trimmingCharacters(in: .whitespaces).isEmpty ? .some(nil) : TimeText.seconds(end).map { .some($0) } }

    private var problem: String? {
        guard let startSeconds else { return "The start isn't a time like 1:30." }
        guard let endSeconds else { return "The end isn't a time like 2:45." }
        if let endSeconds, endSeconds <= startSeconds { return "The end needs to be after the start." }
        if startSeconds == 0 && endSeconds == nil { return "Choose a start or an end time." }
        return nil
    }
}

// MARK: Speed

struct SpeedPanel: View {
    let finish: (MediaTool) -> Void
    static let choices = [0.5, 0.75, 1.25, 1.5, 1.75, 2.0]
    @State private var factor = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Speed", selection: $factor) {
                ForEach(Self.choices, id: \.self) { value in
                    Text(Self.label(value) + (value < 1 ? " (slower)" : " (faster)")).tag(value)
                }
            }
            .accessibilityHint("How fast the copy plays. Voices keep their pitch.")
            Explanation(text: "A 10-minute recording at \(Self.label(factor)) lasts \(TimeText.format(600 / factor)).")
            RunButton(title: "Change speed", hint: "Makes a copy at this speed.") { finish(.speed(factor)) }
        }
    }

    nonisolated static func label(_ factor: Double) -> String { "\(factor.formatted())×" }
}

// MARK: Channels

struct ChannelsPanel: View {
    let finish: (MediaTool) -> Void
    @State private var mix: ChannelMix = .mono

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Sound", selection: $mix) {
                Text("Mix into mono (one channel)").tag(ChannelMix.mono)
                Text("Swap left and right").tag(ChannelMix.swap)
                Text("Keep only the left side").tag(ChannelMix.leftOnly)
                Text("Keep only the right side").tag(ChannelMix.rightOnly)
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint("What happens to the left and right channels.")
            Explanation(text: "Keeping one side helps when a microphone was recorded on only one channel.")
            RunButton(title: "Make copy", hint: "Makes a copy with this sound.") { finish(.channels(mix)) }
        }
    }
}

// MARK: Audiobook

struct AudiobookPanel: View {
    let finish: (MediaTool) -> Void
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Book title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .accessibilityLabel("Book title")
                .accessibilityHint("Shown in Books and other audiobook players. Optional.")
            Explanation(text: "The files are joined in the order shown, each one a chapter named after it. A picture you added becomes the cover.")
            RunButton(title: "Make audiobook", hint: "Makes one M4B audiobook.") {
                let trimmed = title.trimmingCharacters(in: .whitespaces)
                finish(.audiobook(title: trimmed.isEmpty ? nil : trimmed, chapterTitles: []))
            }
        }
    }
}

// MARK: Ringtone

struct RingtonePanel: View {
    let finish: (MediaTool) -> Void
    @State private var start = "0:00"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimeEntry(label: "Start", text: $start, placeholder: "0:00",
                      hint: "Where the ringtone begins, like 0:45. It lasts 30 seconds.")
            Explanation(text: "Pick the start of the part you want, such as the chorus. The ringtone lasts 30 seconds and fades in and out.")
            RunButton(title: "Make ringtone", hint: "Makes an M4R ringtone.", disabled: TimeText.seconds(start) == nil) {
                finish(.ringtone(start: TimeText.seconds(start) ?? 0, seconds: 30))
            }
        }
    }
}

// MARK: GIF

struct GIFSizePanel: View {
    let finish: (MediaTool) -> Void
    static let sizes: [(label: String, bytes: Int)] = [
        ("Under 2 MB (messages)", 2_000_000), ("Under 5 MB (most chats)", 5_000_000),
        ("Under 10 MB (Discord)", 10_000_000), ("Under 15 MB (larger)", 15_000_000),
    ]
    @State private var bytes = 5_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Size", selection: $bytes) {
                ForEach(Self.sizes, id: \.bytes) { Text($0.label).tag($0.bytes) }
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint("The largest the GIF may be.")
            Explanation(text: "Ameya picks the picture size, smoothness and colours to fit. Up to the first 30 seconds are used.")
            RunButton(title: "Make GIF", hint: "Makes an animated GIF.") { finish(.gif(targetBytes: bytes)) }
        }
    }
}

// MARK: Frames

struct FramesPanel: View {
    let finish: (MediaTool) -> Void
    enum Pace: String, CaseIterable, Identifiable {
        case seconds, frames
        var id: String { rawValue }
    }
    @State private var pace: Pace = .seconds
    @State private var seconds = 1.0
    @State private var frames = 30
    @State private var format: FileFormat = .png

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Save a picture", selection: $pace) {
                Text("Every few seconds").tag(Pace.seconds)
                Text("Every few frames").tag(Pace.frames)
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose how often a picture is saved.")
            if pace == .seconds {
                Stepper("Every \(seconds.formatted()) second\(seconds == 1 ? "" : "s")", value: $seconds, in: 0.5...600, step: 0.5)
                    .accessibilityValue("\(seconds.formatted()) seconds")
            } else {
                Stepper("Every \(frames) frame\(frames == 1 ? "" : "s")", value: $frames, in: 1...10_000)
                    .accessibilityValue("\(frames) frames")
            }
            Picker("Format", selection: $format) {
                Text("PNG (exact)").tag(FileFormat.png)
                Text("JPEG (smaller)").tag(FileFormat.jpeg)
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint("PNG keeps every detail; JPEG files are smaller.")
            Explanation(text: "The pictures go into a new folder, up to 1,000 of them.")
            RunButton(title: "Save frames", hint: "Saves the pictures in a folder.") {
                finish(.extractFrames(pace == .seconds ? .everySeconds(seconds) : .everyFrames(frames), format: format))
            }
        }
    }
}

// MARK: Visualiser

struct VisualiserPanel: View {
    let finish: (MediaTool) -> Void
    struct Swatch: Identifiable, Sendable {
        let name: String
        let colour: VisualiserColor
        var id: String { name }
    }
    nonisolated static let colours = [
        Swatch(name: "Midnight", colour: VisualiserColor(red: 0.10, green: 0.09, blue: 0.30)),
        Swatch(name: "Black", colour: VisualiserColor(red: 0.04, green: 0.04, blue: 0.05)),
        Swatch(name: "Coral", colour: VisualiserColor(red: 0.93, green: 0.42, blue: 0.36)),
        Swatch(name: "Forest", colour: VisualiserColor(red: 0.11, green: 0.36, blue: 0.27)),
        Swatch(name: "Sky", colour: VisualiserColor(red: 0.62, green: 0.80, blue: 0.95)),
        Swatch(name: "Paper", colour: VisualiserColor(red: 0.97, green: 0.95, blue: 0.90)),
    ]
    @State private var style: VisualiserStyle = .bars
    @State private var colour = colours[0].name

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $style) {
                Text("Bars").tag(VisualiserStyle.bars)
                Text("Wave").tag(VisualiserStyle.wave)
            }
            .pickerStyle(.segmented)
            .accessibilityHint("What moves with the sound.")
            Picker("Background", selection: $colour) {
                ForEach(Self.colours) { swatch in
                    Label {
                        Text(swatch.name)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(Color(.sRGB, red: swatch.colour.red,
                                                                               green: swatch.colour.green, blue: swatch.colour.blue))
                    }
                    .tag(swatch.name)
                }
            }
            .accessibilityHint("The colour behind the bars or wave.")
            Explanation(text: "Makes a square MP4 with your sound, ready for apps that only share videos.")
            RunButton(title: "Make video", hint: "Makes a video of the sound.") {
                let chosen = Self.colours.first { $0.name == colour } ?? Self.colours[0]
                finish(.visualiser(style: style, background: chosen.colour))
            }
        }
    }
}
