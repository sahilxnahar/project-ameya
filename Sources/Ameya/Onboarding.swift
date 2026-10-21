import SwiftUI

/// Three short steps on first launch. Skippable (Escape), keyboard-driven (← →, Return).
struct OnboardingView: View {
    let done: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    struct Page {
        let symbol: String
        let title: String
        let text: String
    }

    static let pages = [
        Page(symbol: "tray.and.arrow.down",
             title: "Drop it in",
             text: "Drag files onto Ameya, or press ⌘O to choose them. Pasting with ⌘V works too."),
        Page(symbol: "wand.and.stars",
             title: "Pick what you want",
             text: "Choose a format like JPEG or MP3, or a tool like “Make it smaller”. The likeliest choices come first, and you can type to find any format."),
        Page(symbol: "lock.shield",
             title: "Find it in Downloads",
             text: "New files appear in Downloads › Ameya, and your originals are never changed. Everything happens on this Mac: nothing is uploaded, ever."),
    ]

    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Spacer()
                Button("Skip", action: done)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes the welcome tour. You can see it again from the menu bar.")
                    .accessibilityIdentifier("onboarding-skip")
            }

            let current = Self.pages[page]
            VStack(spacing: 16) {
                Image(systemName: current.symbol)
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 64)
                    .accessibilityHidden(true)
                Text(current.title)
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(current.text)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(page)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(page + 1) of \(Self.pages.count). \(current.title). \(current.text)")

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                ForEach(0..<Self.pages.count, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Theme.accent : Color.secondary.opacity(0.35))
                        .frame(width: index == page ? 18 : 7, height: 7)
                }
            }
            .accessibilityHidden(true)

            HStack {
                Button("Back") { go(-1) }
                    .disabled(page == 0)
                    .accessibilityIdentifier("onboarding-back")
                Spacer()
                Button(isLast ? "Let’s Go" : "Next") { isLast ? done() : go(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(isLast ? "Closes the tour and starts Ameya." : "Shows the next step.")
                    .accessibilityIdentifier("onboarding-next")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440, height: 420)
        .tint(Theme.accent)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onAppear { focused = true }
        .accessibilityIdentifier("onboarding")
    }

    private func go(_ step: Int) {
        let next = min(max(page + step, 0), Self.pages.count - 1)
        guard next != page else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.9)) {
            page = next
        }
    }
}
