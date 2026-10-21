import AmeyaCore
import AppKit
import QuickLookThumbnailing
import SwiftUI

/// The welcome: one big, friendly place to drop files, with the keyboard way right there.
struct EmptyDropArea: View {
    let isTargeted: Bool
    let choose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(isTargeted ? 0.22 : 0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .scaleEffect(isTargeted && !reduceMotion ? 1.08 : 1)
            .animation(Theme.arrival(reduceMotion: reduceMotion), value: isTargeted)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(isTargeted ? "Let go to add them" : "Drop anything here")
                    .font(.title2.weight(.semibold))
                Text("Photos, documents, music, videos and more. Ameya turns them into what you need.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: choose) {
                Label("Choose Files…", systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("choose-files")
            .accessibilityHint("Opens a window to pick files from your Mac. Shortcut: Command O.")

            Text("or paste with ⌘V")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("You can also paste files or a picture with Command V.")
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isTargeted ? Theme.accent : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [7, 6]))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop area")
        .accessibilityIdentifier("drop-area")
    }
}

/// One file waiting to be converted: picture or icon, name and size.
struct PendingFileCard: View {
    let file: PendingFile
    let remove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var size: String {
        let bytes = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.format.displayName) · \(size)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .opacity(hovering || focused ? 1 : 0.55)
            .help("Remove from the list")
            .accessibilityLabel("Remove \(file.url.lastPathComponent)")
            .accessibilityHint("Takes it off the list. The file itself isn't touched.")
        }
        .padding(8)
        .card(highlighted: focused)
        .focusable()
        .focused($focused)
        .onDeleteCommand(perform: remove)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.url.lastPathComponent), \(file.format.displayName), \(size)")
        .accessibilityIdentifier("file-card")
        .task(id: file.url) { thumbnail = await Thumbnails.image(for: file.url, size: 80) }
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Theme.accent.opacity(0.12)
                Image(systemName: Theme.symbol(for: file.format))
                    .foregroundStyle(Theme.accent)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}

/// Thumbnails from Quick Look, made on this Mac.
enum Thumbnails {
    static func image(for url: URL, size: CGFloat) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .all)
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.nsImage
    }
}
