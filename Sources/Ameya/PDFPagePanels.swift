import AmeyaCore
import PDFKit
import SwiftUI

/// A grid of page thumbnails for "Remove pages…" and "Reorder pages…".
///
/// Keyboard: arrow keys move between pages, Space marks a page (remove), ⌥ + arrow keys move the
/// focused page (reorder). VoiceOver reads each page as "Page 3 of 12" and offers the same actions.
struct PageGridPanel: View {
    enum Mode { case remove, reorder }
    let mode: Mode
    let finish: (AmeyaCore.PDFAction) -> Void

    @EnvironmentObject private var store: JobStore
    @State private var pdf: PendingPDF?
    /// Original page numbers (1-based) in their current order.
    @State private var order: [Int] = []
    /// Original page numbers marked for removal.
    @State private var marked: Set<Int> = []
    @State private var thumbnails: [Int: NSImage] = [:]
    /// Position in `order` that has keyboard focus.
    @FocusState private var focus: Int?

    private static let columns = 4
    private var total: Int { order.count }
    private var original: [Int] { total > 0 ? Array(1...total) : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = pdf?.problem {
                PanelProblem(message: problem)
            } else if let document = pdf?.document {
                Text(mode == .remove
                     ? "Click the pages to leave out, or use the arrow keys and Space."
                     : "Drag pages into a new order, or use ⌥ and the arrow keys.")
                    .foregroundStyle(.secondary)
                grid(document)
                footer
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func load() {
        guard pdf == nil else { return }
        let opened = PendingPDF(store.pending.first?.url)
        pdf = opened
        order = opened.pageCount > 0 ? Array(1...opened.pageCount) : []
        focus = order.isEmpty ? nil : 0
    }

    // MARK: Grid

    private func grid(_ document: PDFDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: Self.columns), spacing: 12) {
                    ForEach(Array(order.enumerated()), id: \.element) { position, page in
                        cell(page: page, position: position, document: document)
                            .id(page)
                    }
                }
                .padding(6)
            }
            .frame(height: 380)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: focus) { _, position in
                if let position, order.indices.contains(position) {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(order[position]) }
                }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                arrow(press)
            }
            .onKeyPress(.space) {
                guard mode == .remove, let position = focus, order.indices.contains(position) else { return .ignored }
                toggle(order[position])
                return .handled
            }
        }
    }

    private func cell(page: Int, position: Int, document: PDFDocument) -> some View {
        let isMarked = marked.contains(page)
        return VStack(spacing: 4) {
            ZStack {
                if let image = thumbnails[page] {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Rectangle().fill(.white)
                }
                if isMarked {
                    Rectangle().fill(.red.opacity(0.25))
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white, .red)
                }
            }
            .frame(height: 130)
            .shadow(radius: 1)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(focus == position ? Color.accentColor : .clear, lineWidth: 3))
            Text("\(page)").font(.caption).monospacedDigit()
                .foregroundStyle(isMarked ? .red : .primary)
                .strikethrough(isMarked)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focus, equals: position)
        .onTapGesture {
            focus = position
            if mode == .remove { toggle(page) }
        }
        .task(id: page) {
            if thumbnails[page] == nil, let pdfPage = document.page(at: page - 1) {
                thumbnails[page] = pdfPage.thumbnail(of: CGSize(width: 220, height: 220), for: .cropBox)
            }
        }
        .modifier(ReorderDrag(enabled: mode == .reorder, page: page) { dragged in
            guard let from = order.firstIndex(of: dragged) else { return false }
            move(from: from, to: position)
            return true
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page) of \(total)")
        .accessibilityValue(mode == .remove ? (isMarked ? "Will be removed" : "Kept") : "In position \(position + 1)")
        .accessibilityAddTraits(isMarked ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(mode == .remove ? "Space marks or keeps this page." : "Option and arrow keys move this page.")
        .accessibilityActions {
            if mode == .remove {
                Button(isMarked ? "Keep page" : "Remove page") { toggle(page) }
            } else {
                Button("Move earlier") { move(from: position, to: position - 1) }
                Button("Move later") { move(from: position, to: position + 1) }
            }
        }
    }

    private func arrow(_ press: KeyPress) -> KeyPress.Result {
        guard let position = focus, !order.isEmpty else { return .ignored }
        let step: Int
        switch press.key {
        case .leftArrow: step = -1
        case .rightArrow: step = 1
        case .upArrow: step = -Self.columns
        default: step = Self.columns
        }
        if mode == .reorder && press.modifiers.contains(.option) {
            move(from: position, to: position + step)
        } else {
            focus = min(max(position + step, 0), order.count - 1)
        }
        return .handled
    }

    // MARK: Changes

    private func toggle(_ page: Int) {
        if marked.remove(page) == nil { marked.insert(page) }
        announce(marked.contains(page) ? "Page \(page) will be removed" : "Page \(page) kept")
    }

    private func move(from: Int, to target: Int) {
        let to = min(max(target, 0), order.count - 1)
        guard order.indices.contains(from), from != to else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            let page = order.remove(at: from)
            order.insert(page, at: to)
        }
        focus = to
        announce("Page \(order[to]) moved to position \(to + 1) of \(total)")
    }

    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch mode {
        case .remove:
            let count = marked.count
            Text(count == total ? "At least one page has to stay."
                 : count == 0 ? "No pages marked yet." : "\(count) of \(total) pages will be left out.")
                .font(.callout)
                .foregroundStyle(count == total ? .red : .secondary)
            HStack {
                Button("Clear") { marked = [] }.disabled(count == 0)
                Spacer()
                Button(count == 1 ? "Remove 1 Page" : "Remove \(count) Pages") { finish(.deletePages(marked.sorted())) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0 || count == total)
            }
        case .reorder:
            HStack {
                Button("Move Earlier") { if let focus { move(from: focus, to: focus - 1) } }
                    .disabled((focus ?? 0) == 0)
                Button("Move Later") { if let focus { move(from: focus, to: focus + 1) } }
                    .disabled((focus ?? total) >= total - 1)
                Button("Reset") { withAnimation { order = original } }
                    .disabled(order == original)
                Spacer()
                Button("Save New Order") { finish(.reorder(order)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(order == original)
            }
        }
    }
}

/// Drag and drop between thumbnails, for reordering with the mouse or trackpad.
private struct ReorderDrag: ViewModifier {
    let enabled: Bool
    let page: Int
    let dropped: (Int) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(String(page))
                .dropDestination(for: String.self) { items, _ in
                    guard let first = items.first, let dragged = Int(first) else { return false }
                    return dropped(dragged)
                }
        } else {
            content
        }
    }
}
