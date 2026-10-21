import AmeyaCore
@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Why a transcription couldn't run. Shown to the user as-is.
public enum TranscriptionError: Error, Equatable, LocalizedError {
    case notAuthorized
    case languageUnsupported(String)
    case modelNotInstalled(String)
    case recognizerUnavailable
    case noSpeech

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Ameya isn't allowed to use speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition."
        case .languageUnsupported(let language):
            "This Mac can't transcribe \(language) on-device."
        case .modelNotInstalled(let language):
            "Speech recognition for \(language) isn't set up on this Mac yet. Turn on Dictation for \(language) in System Settings → Keyboard → Dictation, then try again."
        case .recognizerUnavailable:
            "On-device speech recognition isn't available on this Mac right now."
        case .noSpeech:
            "No speech was found in this file."
        }
    }
}

/// Audio or video → plain transcript (TXT) or timed captions (SRT, WebVTT), entirely on this Mac.
///
/// macOS 26 and later use `SpeechAnalyzer` + `SpeechTranscriber` (no permission prompt). Only
/// language models already on the Mac are used: Ameya never asks macOS to download one. Earlier systems use `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition`, which needs the user's speech-recognition permission and is
/// fed one-minute chunks cut at quiet moments. Audio never leaves the Mac either way.
enum Transcriber {
    /// One recognised word with its timing in milliseconds.
    struct Word: Equatable, Sendable {
        var text: String
        var start: Int
        var end: Int
    }

    /// Caption layout rules (broadcast-style defaults).
    struct CaptionLayout: Sendable {
        var maxLineLength = 42
        var maxLines = 2
        var maxDuration = 7_000
        var minDuration = 1_000
        /// A silence at least this long always starts a new caption.
        var pauseBreak = 1_000
        /// A silence at least this long starts a new paragraph in the plain transcript.
        var paragraphPause = 2_000
    }

    static func convert(
        input: URL,
        to target: FileFormat,
        output: URL,
        scratch: URL,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [ConversionNote] {
        let audio = scratch.appendingPathComponent("speech.caf")
        let duration = try await prepareAudio(from: input, to: audio) { progress($0 * 0.1) }
        let words = try await recognise(audio, duration: duration, language: options.language) { progress(0.1 + $0 * 0.89) }
        guard !words.isEmpty else { throw TranscriptionError.noSpeech }
        let text: String = switch target {
        case .txt: transcript(from: words)
        case .srt: SubtitleConverter.renderSRT(cues(from: words))
        case .vtt: SubtitleConverter.renderVTT(cues(from: words))
        default: throw ConversionError.unsupportedTarget(target)
        }
        try Data(text.utf8).write(to: output)
        progress(1)
        return [.transcribedOnDevice]
    }

    // MARK: - Captions and transcript

    /// Groups words into captions: at most `maxLines` lines of `maxLineLength` characters and
    /// `maxDuration` on screen, breaking at sentence ends, pauses, and clause ends once a line is full.
    static func cues(from words: [Word], layout: CaptionLayout = CaptionLayout()) -> [SubtitleConverter.Cue] {
        var groups: [[Word]] = []
        var current: [Word] = []
        for word in words {
            if let first = current.first, let last = current.last {
                let candidate = joined(current + [word])
                if word.start - last.end >= layout.pauseBreak
                    || word.end - first.start > layout.maxDuration
                    || wrap(candidate, layout: layout) == nil {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
            let length = joined(current).count
            if endsSentence(word.text) || (endsClause(word.text) && length >= layout.maxLineLength) {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }

        var cues: [SubtitleConverter.Cue] = []
        for (index, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let text = joined(group)
            let lines = wrap(text, layout: layout) ?? [text]
            var end = max(last.end, first.start + layout.minDuration)
            if index + 1 < groups.count, let next = groups[index + 1].first {
                end = min(end, next.start)
            }
            cues.append(SubtitleConverter.Cue(start: first.start, end: max(end, first.start + 1), text: lines.joined(separator: "\n")))
        }
        return cues
    }

    /// Plain text: words joined with spaces, a blank line between paragraphs at long pauses.
    static func transcript(from words: [Word], layout: CaptionLayout = CaptionLayout()) -> String {
        var paragraphs: [[Word]] = []
        var current: [Word] = []
        for word in words {
            if let last = current.last, word.start - last.end >= layout.paragraphPause {
                paragraphs.append(current)
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.map(joined).joined(separator: "\n\n") + "\n"
    }

    /// Splits caption text into at most `maxLines` balanced lines, or `nil` if it doesn't fit.
    /// A single word longer than a line is allowed on its own.
    static func wrap(_ text: String, layout: CaptionLayout = CaptionLayout()) -> [String]? {
        if text.count <= layout.maxLineLength || !text.contains(" ") { return [text] }
        guard layout.maxLines >= 2 else { return nil }
        let words = text.split(separator: " ").map(String.init)
        var best: [String]?
        var bestWidth = Int.max
        for split in 1..<words.count {
            let top = words[..<split].joined(separator: " ")
            let bottom = words[split...].joined(separator: " ")
            let width = max(top.count, bottom.count)
            // Prefer a slightly shorter top line (reads better) when widths tie.
            if width <= layout.maxLineLength, width < bestWidth || (width == bestWidth && top.count < bottom.count) {
                best = [top, bottom]
                bestWidth = width
            }
        }
        return best
    }

    private static func joined(_ words: [Word]) -> String {
        words.map(\.text).joined(separator: " ")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)")).last else { return false }
        return ".?!…。？！".contains(last)
    }

    private static func endsClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ",;:—，；：".contains(last)
    }

    /// Turns a recognised phrase with one time range into words, sharing the time by length.
    static func words(in text: String, start: Int, end: Int) -> [Word] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return [] }
        let total = parts.reduce(0) { $0 + $1.count }
        var words: [Word] = []
        var position = start
        var consumed = 0
        for part in parts {
            consumed += part.count
            let next = part == parts.last ? end : start + (end - start) * consumed / max(total, 1)
            words.append(Word(text: part, start: position, end: max(next, position)))
            position = next
        }
        return words
    }

    // MARK: - Audio

    static let speechSampleRate = 16_000.0

    /// Decodes the sound of any audio or video file to 16 kHz mono PCM, which every recogniser
    /// accepts and which keeps a one-hour file around 115 MB. Returns the duration in seconds.
    static func prepareAudio(from input: URL, to output: URL, progress: (Double) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: speechSampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(readerOutput) else { throw ConversionError.mediaFailed("the sound can't be decoded") }
        reader.add(readerOutput)
        guard let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: speechSampleRate, channels: 1, interleaved: false) else {
            throw ConversionError.mediaFailed("unsupported audio format")
        }
        do {
            let file = try AVAudioFile(forWriting: output, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: speechSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            guard reader.startReading() else {
                throw ConversionError.mediaFailed(reader.error?.localizedDescription ?? "couldn't start reading")
            }
            while let sample = readerOutput.copyNextSampleBuffer() {
                let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: frames) else { continue }
                buffer.frameLength = frames
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
                guard status == noErr else { throw ConversionError.mediaFailed("decoding error \(status)") }
                try file.write(from: buffer)
                if duration > 0 { progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)) }
            }
        }
        guard reader.status == .completed else {
            throw ConversionError.mediaFailed(reader.error?.localizedDescription ?? "reading stopped early")
        }
        return duration
    }

    // MARK: - Recognition

    static func recognise(
        _ audio: URL,
        duration: Double,
        language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Word] {
        let requested = language.map { Locale(identifier: $0) } ?? Locale.current
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            return try await AnalyzerRecogniser.recognise(audio, duration: duration, locale: requested, progress: progress)
        }
        return try await LegacyRecogniser.recognise(audio, locale: requested, progress: progress)
    }

    /// The installed locale that best fits the request: the exact tag, then the same language
    /// and region, then the same language (US first, else alphabetical). `nil` if the language
    /// isn't installed at all.
    static func installedMatch(for requested: Locale, among installed: [Locale]) -> Locale? {
        let tag = requested.identifier(.bcp47).lowercased()
        if let exact = installed.first(where: { $0.identifier(.bcp47).lowercased() == tag }) { return exact }
        guard let language = requested.language.languageCode else { return nil }
        let sameLanguage = installed
            .filter { $0.language.languageCode == language }
            .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
        if let region = requested.region,
           let sameRegion = sameLanguage.first(where: { $0.region == region }) { return sameRegion }
        return sameLanguage.first { $0.region == .unitedStates } ?? sameLanguage.first
    }

    static func languageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// macOS 26+: SpeechAnalyzer reads the whole file itself, so long recordings need no chunking.
@available(macOS 26, *)
enum AnalyzerRecogniser {
    static func recognise(
        _ audio: URL,
        duration: Double,
        locale requested: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Transcriber.Word] {
        // Only models already installed on this Mac. Ameya never triggers a download.
        let installed = Array(await SpeechTranscriber.installedLocales)
        guard let locale = Transcriber.installedMatch(for: requested, among: installed) else {
            throw TranscriptionError.modelNotInstalled(Transcriber.languageName(requested))
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])

        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var words: [Transcriber.Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    let start = Int((range.start.seconds * 1000).rounded())
                    let end = Int((range.end.seconds * 1000).rounded())
                    words += Transcriber.words(in: text, start: start, end: end)
                    if duration > 0 { progress(min(0.99, range.end.seconds / duration)) }
                }
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value.sorted { $0.start < $1.start }
    }
}

/// macOS 14–25: SFSpeechRecognizer, on-device only. It handles about a minute per request,
/// so the audio is sent in chunks of up to 60 s, each cut at the quietest moment of its last
/// five seconds to avoid splitting words. Timestamps are offset so they stay continuous.
enum LegacyRecogniser {
    static let chunkSeconds = 60.0
    static let searchSeconds = 5.0

    static func recognise(_ audio: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcriber.Word] {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        default: throw TranscriptionError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.languageUnsupported(Transcriber.languageName(locale))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.modelNotInstalled(Transcriber.languageName(locale))
        }
        guard recognizer.isAvailable else { throw TranscriptionError.recognizerUnavailable }

        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        let rate = format.sampleRate
        let totalFrames = file.length
        var words: [Transcriber.Word] = []
        while file.framePosition < totalFrames {
            let offset = file.framePosition
            let window = AVAudioFrameCount(min(Double(totalFrames - offset), chunkSeconds * rate))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { break }
            try file.read(into: buffer, frameCount: window)
            if file.framePosition < totalFrames {
                let cut = quietestFrame(in: buffer, searchFrames: Int(searchSeconds * rate), windowFrames: Int(rate / 50))
                buffer.frameLength = AVAudioFrameCount(cut)
                file.framePosition = offset + AVAudioFramePosition(cut)
            }
            let offsetMillis = Int(Double(offset) / rate * 1000)
            words += try await recognise(buffer, with: recognizer).map {
                Transcriber.Word(text: $0.text, start: $0.start + offsetMillis, end: $0.end + offsetMillis)
            }
            progress(Double(file.framePosition) / Double(max(totalFrames, 1)))
        }
        return words
    }

    /// The start of the quietest short window within the last `searchFrames` of the buffer.
    static func quietestFrame(in buffer: AVAudioPCMBuffer, searchFrames: Int, windowFrames: Int) -> Int {
        let length = Int(buffer.frameLength)
        guard let samples = buffer.floatChannelData?[0], length > searchFrames, windowFrames > 0 else { return length }
        var bestFrame = length
        var bestEnergy = Float.greatestFiniteMagnitude
        var frame = length - searchFrames
        while frame + windowFrames <= length {
            var energy: Float = 0
            for index in frame..<(frame + windowFrames) { energy += samples[index] * samples[index] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestFrame = frame + windowFrames / 2
            }
            frame += windowFrames
        }
        return bestFrame
    }

    private static func recognise(_ buffer: AVAudioPCMBuffer, with recognizer: SFSpeechRecognizer) async throws -> [Transcriber.Word] {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    guard resumed.claim() else { return }
                    continuation.resume(returning: result.bestTranscription.segments.map { segment in
                        let start = Int((segment.timestamp * 1000).rounded())
                        return Transcriber.Word(text: segment.substring, start: start, end: start + Int((segment.duration * 1000).rounded()))
                    })
                } else if let error {
                    guard resumed.claim() else { return }
                    // "No speech detected" for a silent chunk is not a failure.
                    let code = (error as NSError).code
                    if code == 1110 || code == 203 {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Makes sure a continuation is resumed exactly once.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
