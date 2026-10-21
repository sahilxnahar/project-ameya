import Foundation

/// The "Save converted files to" setting.
///
/// The sandbox only lets Ameya write to Downloads (entitlement) and to folders the user picked.
/// A picked folder is remembered as an app-scoped security-scoped bookmark, so access survives
/// relaunches. "Next to the original" for arbitrary folders would need either a bookmark per
/// folder or the related-items mechanism, which only covers same-name sibling files; choosing a
/// folder once covers the common case of "save into the folder I work in".
@MainActor
enum OutputLocation {
    enum Choice: String, CaseIterable, Identifiable {
        case downloads
        case folder
        var id: String { rawValue }
    }

    static let choiceKey = "outputLocation"
    static let bookmarkKey = "outputFolderBookmark"

    private static var resolved: (data: Data, url: URL)?

    static var choice: Choice {
        Choice(rawValue: UserDefaults.standard.string(forKey: choiceKey) ?? "") ?? .downloads
    }

    /// The folder to save into. Falls back to `fallback` when the chosen folder is gone.
    static func directory(default fallback: URL) -> URL {
        guard choice == .folder, let url = chosenFolder() else { return fallback }
        return url
    }

    /// The user-picked folder, with sandbox access started (kept for the app's lifetime).
    static func chosenFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        if let resolved, resolved.data == data { return resolved.url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        resolved?.url.stopAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            resolved = (fresh, url)
        } else {
            resolved = (data, url)
        }
        return url
    }

    /// Remembers a folder the user picked in an open panel (which grants access for now).
    static func choose(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope])
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(Choice.folder.rawValue, forKey: choiceKey)
        _ = chosenFolder()
    }
}
