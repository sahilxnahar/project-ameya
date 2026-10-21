import AmeyaCore
import SwiftUI

/// Settings for "Passport photo…": pick a country (searchable), digital or print, background.
/// Fully keyboard-driven: type to search, arrows to pick, Return to make the photo.
struct PassportPhotoPanel: View {
    let done: (ConversionOptions) -> Void

    @State private var search = ""
    @State private var selection: String? = PassportPhotoPanel.defaultSpec.id
    @State private var printSheet = false
    @State private var replaceBackground = true
    @State private var customWidth = 35.0
    @State private var customHeight = 45.0
    @State private var customBackground = PassportBackground.white
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Mac's region picks the first choice (India on an Indian Mac), else the first preset.
    static var defaultSpec: PassportSpec {
        PassportSpec.preset(forRegion: Locale.current.region?.identifier) ?? PassportSpec.presets[0]
    }

    private var matches: [PassportSpec] { PassportSpec.search(search) }
    private var isCustom: Bool { selection == PassportSpec.customID }
    private var customIsValid: Bool { (10...200).contains(customWidth) && (10...200).contains(customHeight) }

    private var spec: PassportSpec? {
        if isCustom {
            return customIsValid ? .custom(widthMM: customWidth, heightMM: customHeight, background: customBackground) : nil
        }
        return PassportSpec.presets.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search countries", text: $search, prompt: Text("Search countries or visas"))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityHint("Narrows the list below. Press Return to pick the first match.")
                .onSubmit { if let first = matches.first { selection = first.id } }
                .onChange(of: search) {
                    if !matches.contains(where: { $0.id == selection }) && !isCustom { selection = matches.first?.id }
                }

            List(selection: $selection) {
                ForEach(matches) { preset in
                    row(preset.name, detail: preset.sizeText).tag(Optional(preset.id))
                }
                row("Custom size", detail: "Choose the width and height").tag(Optional(PassportSpec.customID))
            }
            .frame(height: 210)
            .accessibilityLabel("Country or document")

            if isCustom { customFields }
            if let spec { details(spec) }

            Picker("Make", selection: $printSheet) {
                Text("Digital photo").tag(false)
                Text("Digital photo and a 4×6 in print sheet").tag(true)
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint("A print sheet holds several copies to print at a photo shop or at home.")

            Toggle(isOn: $replaceBackground) {
                Text("Plain \(spec?.background.displayName ?? "white") background")
            }
            .help("Replaces what's behind you with the plain colour the rules ask for. Turn off to keep your own background.")

            Label("Everything happens on this Mac. Your photo is never uploaded.", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Make Photo") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(spec == nil)
                    .accessibilityHint("Makes the photo next to the original.")
            }
        }
        .frame(minWidth: 420)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isCustom)
        .onAppear { searchFocused = true }
    }

    private func row(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var customFields: some View {
        HStack(spacing: 8) {
            TextField("Width", value: $customWidth, format: .number)
                .frame(width: 60).accessibilityLabel("Width in millimetres")
            Text("×").accessibilityHidden(true)
            TextField("Height", value: $customHeight, format: .number)
                .frame(width: 60).accessibilityLabel("Height in millimetres")
            Text("mm").accessibilityHidden(true)
            Picker("Background", selection: $customBackground) {
                ForEach(PassportBackground.allCases, id: \.self) { Text($0.displayName.capitalized).tag($0) }
            }
            .fixedSize()
        }
        .textFieldStyle(.roundedBorder)
    }

    private func details(_ spec: PassportSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spec.summary).font(.callout)
            if spec.needsCheck {
                Label("Rules vary; check the official requirements before you submit.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func make() {
        guard let spec else { return }
        var options = ConversionOptions()
        options.passport = PassportPhotoOptions(spec: spec, printSheet: printSheet, replaceBackground: replaceBackground)
        done(options)
    }
}
