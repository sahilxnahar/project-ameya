import AppKit
import ServiceManagement
import SwiftUI

/// Ameya → Settings…  Everything is off or harmless by default.
struct SettingsView: View {
    @AppStorage(OutputLocation.choiceKey) private var location = OutputLocation.Choice.downloads.rawValue
    @State private var folderName = OutputLocation.chosenFolder()?.lastPathComponent
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage(Preferences.playSoundsKey) private var playSounds = false
    @AppStorage(Preferences.celebrateKey) private var celebrate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            WatchFoldersSection() // WatchFoldersSettings.swift; includes the old iPhone-photos setting
            Section("Recipes") {
                Button("Edit Recipes…") { RecipeEditorWindow.show() }
                    .accessibilityHint("Opens the window where you build step-by-step recipes")
            }

            WheelSettingsSection()
            Section("Fun") {
                Toggle("Celebrate finished batches", isOn: $celebrate)
                    .disabled(reduceMotion)
                    .accessibilityHint("Shows a short confetti burst when all your files are done.")
                    .accessibilityIdentifier("settings-celebrate")
                if reduceMotion {
                    Text("Off while Reduce Motion is on in System Settings › Accessibility. You'll still see a checkmark.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Play sounds", isOn: $playSounds)
                    .accessibilityHint("Plays a soft sound when files are added and when they're done.")
                    .accessibilityIdentifier("settings-sounds")
                    .onChange(of: playSounds) { _, on in if on { Feedback.play(.done) } }
            }

            Section("Startup") {
                Toggle("Open Ameya when I log in", isOn: $launchAtLogin)
                    .accessibilityHint("Ameya starts quietly in the menu bar when you log in.")
                    .accessibilityIdentifier("settings-login")
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
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
