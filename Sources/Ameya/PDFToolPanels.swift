import AmeyaCore
import PDFKit
import SwiftUI

// Settings panels for the PDF toolbox (see ToolCatalog.pdfToolbox). Each calls `finish` with the
// chosen action; the surrounding sheet adds Cancel (Escape).

/// The single pending PDF, opened here only to count and show its pages. Conversions themselves
/// always run in the sandboxed worker.
@MainActor
final class PendingPDF: ObservableObject {
    let document: PDFDocument?
    let problem: String?

    init(_ url: URL?) {
        guard let url, let document = PDFDocument(url: url) else {
            document = nil
            problem = "Ameya couldn't open this PDF to show its pages."
            return
        }
        if document.isLocked {
            self.document = nil
            problem = "This PDF has a password. Use “Remove password…” first."
        } else if document.pageCount == 0 {
            self.document = nil
            problem = "This PDF has no pages."
        } else {
            self.document = document
            problem = nil
        }
    }

    var pageCount: Int { document?.pageCount ?? 0 }
}

/// Shows a problem in place of a panel's controls.
struct PanelProblem: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .accessibilityLabel(message)
    }
}

struct ExtractPagesPanel: View {
    let finish: (AmeyaCore.PDFAction) -> Void
    @EnvironmentObject private var store: JobStore
    @State private var text = ""
    @State private var count: Int?
    @FocusState private var focused: Bool

    var body: some View {
        let parsed = Result { try PageRanges.parse(text, pageCount: count ?? PageRanges.maxPages) }
        VStack(alignment: .leading, spacing: 10) {
            if let count {
                Text("This PDF has \(count) page\(count == 1 ? "" : "s"). Type the pages to copy into a new PDF.")
            }
            TextField("Pages", text: $text, prompt: Text("For example 1-3, 7, 9-"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityLabel("Pages to extract")
                .accessibilityHint("Type page numbers and ranges separated by commas. 9- means page 9 to the end.")
                .onSubmit { if case .success(let pages) = parsed { finish(.reorder(pages)) } }
            Group {
                switch parsed {
                case .success(let pages): Text("\(pages.count) page\(pages.count == 1 ? "" : "s") will be copied, in this order.")
                case .failure(let error) where !text.isEmpty: Text(error.localizedDescription).foregroundStyle(.red)
                case .failure: Text("Ranges like 2-5 and single pages both work.")
                }
            }
            .font(.callout)
            .accessibilityAddTraits(.updatesFrequently)
            HStack {
                Spacer()
                Button("Extract Pages") { if case .success(let pages) = parsed { finish(.reorder(pages)) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled((try? parsed.get()) == nil)
            }
        }
        .frame(width: 380)
        .onAppear {
            count = PendingPDF.count(store.pending.first?.url)
            focused = true
        }
    }
}

extension PendingPDF {
    /// Page count without keeping the document open; `nil` when it can't be read.
    static func count(_ url: URL?) -> Int? {
        PendingPDF(url).document?.pageCount
    }
}

struct PageNumbersPanel: View {
    let finish: (AmeyaCore.PDFAction) -> Void
    @State private var style: PageNumberStyle = .number

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Small numbers go at the bottom centre of every page.")
            Picker("Style", selection: $style) {
                ForEach(PageNumberStyle.allCases, id: \.self) { style in
                    Text(style.label(page: 3, of: 12)).tag(style)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint("How each page number is written.")
            HStack {
                Spacer()
                Button("Add Page Numbers") { finish(.addPageNumbers(style)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 340)
    }
}

struct WatermarkPanel: View {
    let finish: (AmeyaCore.PDFAction) -> Void
    @State private var text = "CONFIDENTIAL"
    @State private var opacity = 0.25
    @FocusState private var focused: Bool

    private var words: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Text", text: $text, prompt: Text("For example DRAFT"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityLabel("Watermark text")
            HStack {
                Text("Strength")
                Slider(value: $opacity, in: 0.1...0.6)
                    .accessibilityLabel("Watermark strength")
                    .accessibilityValue("\(Int(opacity * 100)) percent")
                Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            preview
            HStack {
                Spacer()
                Button("Add Watermark") { finish(.watermark(text: words, opacity: opacity)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(words.isEmpty || words.count > 200)
            }
        }
        .frame(width: 360)
        .onAppear { focused = true }
    }

    /// A page-shaped sketch of the result.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.white).shadow(radius: 1)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<7, id: \.self) { line in
                    Capsule().fill(.gray.opacity(0.25)).frame(width: line % 3 == 2 ? 50 : 80, height: 4)
                }
            }
            Text(words.isEmpty ? " " : words)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.gray.opacity(opacity))
                .lineLimit(1).minimumScaleFactor(0.3)
                .frame(width: 120)
                .rotationEffect(.degrees(-54))
        }
        .frame(width: 100, height: 130)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct PasswordPanel: View {
    enum Mode { case protect, remove }
    let mode: Mode
    let finish: (AmeyaCore.PDFAction) -> Void
    @State private var password = ""
    @State private var repeated = ""
    @FocusState private var focused: Bool

    private var problem: String? {
        if password.isEmpty { return nil }
        if mode == .protect {
            if !password.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) {
                return "Use letters, numbers and symbols from a standard keyboard (no accents or emoji)."
            }
            if password.count > 127 { return "That password is too long." }
            if !repeated.isEmpty && repeated != password { return "The two passwords don't match." }
        }
        return nil
    }

    private var ready: Bool {
        !password.isEmpty && problem == nil && (mode == .remove || repeated == password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .protect
                 ? "Anyone opening the copy will need this password. Ameya can't recover it if it's forgotten."
                 : "Type the password that opens this PDF. The copy will open without one.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField(mode == .protect ? "Password" : "Current password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityLabel(mode == .protect ? "New password" : "Current password")
                .onSubmit(submit)
            if mode == .protect {
                SecureField("Type it again", text: $repeated)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Repeat the password")
                    .onSubmit(submit)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            Text("The password is used only on this Mac and is never saved.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(mode == .protect ? "Protect PDF" : "Remove Password", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .frame(width: 360)
        .onAppear { focused = true }
        .onDisappear {
            password = ""
            repeated = ""
        }
    }

    private func submit() {
        guard ready else { return }
        finish(mode == .protect ? .protect(password: password) : .removePassword(password: password))
    }
}
