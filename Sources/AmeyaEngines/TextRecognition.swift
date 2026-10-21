import AmeyaCore
import CoreGraphics
import Foundation
import Vision

/// One line of recognised text. `box` is in Vision's unit coordinates: 0…1, origin bottom-left.
struct RecognizedLine: Sendable, Equatable {
    var text: String
    var box: CGRect
}

/// On-device text recognition (Vision). Nothing leaves the Mac.
enum TextRecognizer {
    /// Recognises the text in `image`, in reading order (top to bottom, then left to right).
    /// - Parameter languages: BCP-47 tags such as "en" or "hi-IN". `nil` uses the Mac's preferred
    ///   languages and lets Vision detect the language too.
    static func recognize(_ image: CGImage, languages: [String]?) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let chosen = recognitionLanguages(for: languages, supported: (try? request.supportedRecognitionLanguages()) ?? [])
        if !chosen.isEmpty { request.recognitionLanguages = chosen }
        request.automaticallyDetectsLanguage = languages == nil
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw ConversionError.mediaFailed("text recognition failed (\(error.localizedDescription))")
        }
        let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, observation.boundingBox.width > 0, observation.boundingBox.height > 0 else { return nil }
            return RecognizedLine(text: text, box: observation.boundingBox)
        }
        return readingOrder(lines)
    }

    /// Languages Vision supports on this Mac, matched by language code: "hi" → "hi-IN", "en-GB" → "en-US".
    static func recognitionLanguages(for requested: [String]?, supported: [String]) -> [String] {
        let wanted = requested ?? Locale.preferredLanguages
        var chosen: [String] = []
        for tag in wanted {
            let match = supported.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
                ?? supported.first { Self.code($0) == Self.code(tag) && Self.script($0) == Self.script(tag) }
                ?? supported.first { Self.code($0) == Self.code(tag) }
            if let match, !chosen.contains(match) { chosen.append(match) }
        }
        // English as a fallback keeps Latin text (numbers, names, URLs) readable next to other scripts.
        if requested == nil, let english = supported.first(where: { code($0) == "en" }), !chosen.contains(english) {
            chosen.append(english)
        }
        return chosen
    }

    /// Whether Vision can read this language on this Mac.
    static func supports(_ language: String) -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        return supported.contains { code($0) == code(language) }
    }

    private static func code(_ tag: String) -> String {
        String(tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    private static func script(_ tag: String) -> String? {
        tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).dropFirst().first { $0.count == 4 }.map { $0.lowercased() }
    }

    /// Top to bottom; lines whose middles share a row go left to right.
    static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        var rows: [[RecognizedLine]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, abs(first.box.midY - line.box.midY) <= min(first.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// Plain text: one line per row, a blank line where the gap suggests a new paragraph.
    static func text(of lines: [RecognizedLine]) -> String {
        var output = ""
        var previous: RecognizedLine?
        for line in lines {
            if let previous {
                let sameRow = abs(previous.box.midY - line.box.midY) <= min(previous.box.height, line.box.height) / 2
                if sameRow {
                    output += "  "
                } else {
                    let gap = previous.box.minY - line.box.maxY
                    output += gap > 1.2 * max(previous.box.height, line.box.height) ? "\n\n" : "\n"
                }
            }
            output += line.text
            previous = line
        }
        return output
    }
}
