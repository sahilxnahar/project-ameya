import AppKit
import ServiceManagement
import SwiftUI

/// Ameya → Settings…  Everything is off or harmless by default.
struct SettingsView: View {
    @AppStorage(AutoConverter.enabledKey) private var autoConvert = false
    @AppStorage(AutoConverter.originalKey) private var original = AutoConverter.Original.keep.rawValue
    @AppStorage(OutputLocation.choiceKey) private var location = OutputLocation.Choice.downloads.rawValue
    @State private var folderName = OutputLocation.chosenFolder()?.lastPathComponent
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Save converted files to") {
                Picker("Save converted files to", selection: $location) {
                    Text("Ameya folder in Downloads").tag(OutputLocation.Choice.downloads.rawValue)
                    Text(folderName.map { "Folder: \($0)" } ?? "A folder I choose…").tag(OutputLocation.Choice.folder.rawValue)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel("Save converted files to")
                .onChange(of: location) { _, newValue in
                    if newValue == OutputLocation.Choice.folder.rawValue, folderName == nil { chooseFolder() }
                }
                if location == OutputLocation.Choice.folder.rawValue {
                    Button("Choose Folder…", action: chooseFolder)
                        .accessibilityHint("Pick the folder Ameya saves converted files in")
                }
            }

            Section("iPhone photos") {
                Toggle("Automatically convert iPhone photos (HEIC) in Downloads to JPEG", isOn: $autoConvert)
                    .accessibilityHint("New HEIC photos that arrive in Downloads get a JPEG copy next to them")
                Picker("After converting, the original photo", selection: $original) {
                    Text("Stays where it is").tag(AutoConverter.Original.keep.rawValue)
                    Text("Moves to the Trash (you can put it back)").tag(AutoConverter.Original.trash.rawValue)
                }
                .disabled(!autoConvert)
                Text("Only photos that arrive while Ameya is open are converted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: autoConvert) { _, _ in AppDelegate.shared?.autoConverter.applySettings() }

            WheelSettingsSection()

            Section("Startup") {
                Toggle("Open Ameya when I log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where Ameya saves converted files."
        if panel.runModal() == .OK, let url = panel.url, (try? OutputLocation.choose(url)) != nil {
            folderName = url.lastPathComponent
            location = OutputLocation.Choice.folder.rawValue
        } else if folderName == nil {
            location = OutputLocation.Choice.downloads.rawValue
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS didn't allow this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
