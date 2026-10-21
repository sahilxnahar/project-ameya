import Foundation

/// One file Ameya made. Only the path and sizes are kept: nothing about the contents.
public struct RecentFile: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var bytesBefore: Int64
    public var bytesAfter: Int64
    /// The output is a folder (e.g. "Split into pages").
    public var isFolder: Bool

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: isFolder) }
    public var name: String { url.lastPathComponent }
    public var sizeChange: SizeChange { SizeChange(before: bytesBefore, after: bytesAfter) }

    public init(path: String, bytesBefore: Int64, bytesAfter: Int64, isFolder: Bool = false) {
        self.path = path
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.isFolder = isFolder
    }
}

/// Newest first, without duplicates, capped.
public struct RecentList: Codable, Equatable, Sendable {
    public static let limit = 30
    public private(set) var items: [RecentFile]

    public init(items: [RecentFile] = []) {
        self.items = []
        for item in items.reversed() { add(item) }
    }

    public mutating func add(_ item: RecentFile) {
        items.removeAll { $0.path == item.path }
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(path: String) {
        items.removeAll { $0.path == path }
    }

    public mutating func clear() {
        items = []
    }
}

/// Reads and writes the recent list as a small JSON file on this Mac. Never throws on read:
/// a missing or damaged file is simply an empty list.
public struct RecentStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/Ameya/recent.json` (inside the app's sandbox container).
    public static var standard: RecentStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RecentStore(url: base.appendingPathComponent("Ameya", isDirectory: true)
            .appendingPathComponent("recent.json"))
    }

    public func load() -> RecentList {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(RecentList.self, from: data) else { return RecentList() }
        return RecentList(items: list.items)
    }

    public func save(_ list: RecentList) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(list).write(to: url, options: .atomic)
    }
}
