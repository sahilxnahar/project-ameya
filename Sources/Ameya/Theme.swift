import AmeyaCore
import AppKit
import SwiftUI

/// Ameya's look: one gold accent, SF Symbols in hierarchical rendering, gentle springs.
enum Theme {
    /// Ameya gold, from the brand mark (#C9A95D), tuned per appearance for contrast:
    /// - light: #7D5F1A — white button text 6.0:1, as text on window background 5.0:1
    /// - light, Increase Contrast: #5E4612 — 8.9:1 / 7.5:1
    /// - dark: #A8873A — white button text 3.4:1 (bold control labels), as text on dark 4.9:1
    /// - dark, Increase Contrast: #AF8E44 — as text on dark 5.4:1, white button text 3.1:1
    ///   (Increase Contrast also strengthens card borders; see `CardBackground`)
    static let accent = Color(nsColor: NSColor(name: "AmeyaAccent") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .accessibilityHighContrastDarkAqua]) != nil
        let highContrast = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) != nil
        switch (dark, highContrast) {
        case (false, false): return NSColor(srgbRed: 0x7D / 255, green: 0x5F / 255, blue: 0x1A / 255, alpha: 1)
        case (false, true): return NSColor(srgbRed: 0x5E / 255, green: 0x46 / 255, blue: 0x12 / 255, alpha: 1)
        case (true, false): return NSColor(srgbRed: 0xA8 / 255, green: 0x87 / 255, blue: 0x3A / 255, alpha: 1)
        case (true, true): return NSColor(srgbRed: 0xAF / 255, green: 0x8E / 255, blue: 0x44 / 255, alpha: 1)
        }
    })

    /// The brand gold itself, for decoration only (the mark, confetti), never for text.
    static let brandGold = Color(red: 0xC9 / 255, green: 0xA9 / 255, blue: 0x5D / 255)

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
