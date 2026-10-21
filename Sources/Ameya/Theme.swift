import AmeyaCore
import AppKit
import SwiftUI

/// Ameya's look: one warm accent, SF Symbols in hierarchical rendering, gentle springs.
enum Theme {
    /// Tangerine. Dark enough for white button text in light mode, bright enough on dark backgrounds.
    static let accent = Color(nsColor: NSColor(name: "AmeyaAccent") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .accessibilityHighContrastDarkAqua]) != nil
        let highContrast = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) != nil
        switch (dark, highContrast) {
        case (false, false): return NSColor(srgbRed: 0.76, green: 0.30, blue: 0.10, alpha: 1)
        case (false, true): return NSColor(srgbRed: 0.62, green: 0.22, blue: 0.05, alpha: 1)
        case (true, false): return NSColor(srgbRed: 0.90, green: 0.42, blue: 0.17, alpha: 1)
        case (true, true): return NSColor(srgbRed: 0.98, green: 0.56, blue: 0.30, alpha: 1)
        }
    })

    static let cornerRadius: CGFloat = 12

    /// The one spring used for things arriving (dropped files, results). Reduce Motion gets a short fade.
    static func arrival(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.78)
    }

    /// Cards appear slightly scaled; with Reduce Motion they only fade.
    static func cardTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity)
    }

    /// The symbol for a file of this format.
    static func symbol(for format: FileFormat) -> String {
        format == .pdf ? "doc.richtext" : FormatKind(format.family).systemImage
    }
}

/// Card background that respects Increase Contrast and Reduce Transparency.
struct CardBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(highlighted ? Theme.accent : Color.primary.opacity(contrast == .increased ? 0.55 : 0.12),
                                  lineWidth: highlighted || contrast == .increased ? 1.5 : 1)
            )
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View { modifier(CardBackground(highlighted: highlighted)) }
}

/// A small section title read as a heading by VoiceOver.
struct SectionTitle: View {
    let text: String
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.headline)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Settings keys for the fun bits.
enum Preferences {
    static let playSoundsKey = "playSounds"
    static let celebrateKey = "celebrateBatches"
    static let hasSeenOnboardingKey = "hasSeenOnboarding"

    static var playSounds: Bool { UserDefaults.standard.bool(forKey: playSoundsKey) }
    static var celebrate: Bool { UserDefaults.standard.object(forKey: celebrateKey) as? Bool ?? true }
}
