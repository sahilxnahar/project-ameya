import Foundation

/// How "Add page numbers" writes each number.
public enum PageNumberStyle: String, Codable, Sendable, Equatable, CaseIterable {
    /// "3"
    case number
    /// "Page 3 of 12"
    case pageOfTotal
    /// "– 3 –"
    case dashes

    public func label(page: Int, of total: Int) -> String {
        switch self {
        case .number: "\(page)"
        case .pageOfTotal: "Page \(page) of \(total)"
        case .dashes: "– \(page) –"
        }
    }
}

extension FileFormat {
    /// Pictures whose words can be recognised (photos, scans, screenshots; not icons or SVG).
    public var isRecognisableImage: Bool {
        family == .image && !isIcon && self != .svg
    }
}

/// Page lists typed by people, such as "1-3, 7, 9-" (9- means 9 to the end).
public enum PageRanges {
    public static let maxPages = 10_000

    public enum Failure: Error, Equatable, LocalizedError {
        case empty
        case notAPage(String)
        case pageZero
        case backwards(String)
        case beyondEnd(page: Int, pageCount: Int)
        case tooMany

        public var errorDescription: String? {
            switch self {
            case .empty: "Type the pages to keep, for example 1-3, 7."
            case .notAPage(let text): "“\(text)” isn't a page number or a range like 2-5."
            case .pageZero: "Pages start at 1."
            case .backwards(let text): "“\(text)” runs backwards; write the smaller page first."
            case .beyondEnd(let page, let count): "There is no page \(page); this PDF has \(count) page\(count == 1 ? "" : "s")."
            case .tooMany: "That is more than \(PageRanges.maxPages) pages."
            }
        }
    }

    /// The pages in the order typed, each once. Ranges are inclusive; "9-" runs to `pageCount`
    /// and "-3" from page 1.
    public static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        let normalized = text
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
        let tokens = normalized
            .components(separatedBy: CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw Failure.empty }

        var pages: [Int] = []
        var seen = Set<Int>()
        for token in tokens {
            let range = try parseToken(token, pageCount: pageCount)
            guard pages.count + range.count <= maxPages else { throw Failure.tooMany }
            for page in range where seen.insert(page).inserted {
                pages.append(page)
            }
        }
        return pages
    }

    private static func parseToken(_ token: String, pageCount: Int) throws -> ClosedRange<Int> {
        let parts = token.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        func number(_ text: String) throws -> Int {
            guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let value = Int(text) else {
                throw Failure.notAPage(token)
            }
            guard value >= 1 else { throw Failure.pageZero }
            guard value <= pageCount else { throw Failure.beyondEnd(page: value, pageCount: pageCount) }
            return value
        }
        switch parts.count {
        case 1:
            let page = try number(parts[0])
            return page...page
        case 2:
            guard !(parts[0].isEmpty && parts[1].isEmpty) else { throw Failure.notAPage(token) }
            let first = parts[0].isEmpty ? 1 : try number(parts[0])
            let last = parts[1].isEmpty ? pageCount : try number(parts[1])
            guard first <= last else { throw Failure.backwards(token) }
            return first...last
        default:
            throw Failure.notAPage(token)
        }
    }
}
