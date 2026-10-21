import AmeyaCore
import SwiftUI

/// "Edit details…" for photos: date taken (set, or shift every photo by N hours for a camera
/// whose clock was wrong), title, description, author, copyright and keywords.
struct PhotoDetailsPanel: View {
    let count: Int
    let done: (ConversionOptions) -> Void

    enum DateMode: String, CaseIterable, Identifiable {
        case keep = "Keep", shift = "Shift", set = "Set"
        var id: String { rawValue }
    }

    @State private var dateMode: DateMode = .keep
    @State private var shiftHours = 0
    @State private var newDate = Date()
    @State private var fields: [Field: FieldState] = [:]

    enum Field: String, CaseIterable, Identifiable {
        case title = "Title", description = "Description", author = "Author", copyright = "Copyright", keywords = "Keywords"
        var id: String { rawValue }
        var prompt: String {
            switch self {
            case .keywords: "For example holiday, beach, 2024"
            case .copyright: "For example © 2024 Your Name"
            default: rawValue
            }
        }
    }

    struct FieldState {
        var change = false
        var text = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Date taken", selection: $dateMode) {
                ForEach(DateMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Keep the dates, shift them all by some hours, or set one date.")
            switch dateMode {
            case .keep:
                Text("Dates stay as they are.").font(.callout).foregroundStyle(.secondary)
            case .shift:
                Stepper(value: $shiftHours, in: -72...72) {
                    Text(shiftDescription)
                }
                .accessibilityValue(shiftDescription)
                Text("Use this when the camera's clock was wrong, for example after travelling to another time zone.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .set:
                DatePicker("New date", selection: $newDate, displayedComponents: [.date, .hourAndMinute])
                if count > 1 {
                    Text("All \(count) photos will get this same date.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(Field.allCases) { field in row(field) }
            Text("Changed fields left empty are removed.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(count == 1 ? "Save Copy" : "Save \(count) Copies") { done(options) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(edit.isEmpty)
                    .accessibilityIdentifier("details-save")
            }
        }
        .frame(minWidth: 420)
    }

    private func row(_ field: Field) -> some View {
        let binding = Binding(get: { fields[field] ?? FieldState() }, set: { fields[field] = $0 })
        return HStack {
            Toggle(field.rawValue, isOn: binding.change)
                .frame(width: 130, alignment: .leading)
                .accessibilityHint("Turn on to change or remove the \(field.rawValue.lowercased()).")
            TextField(field.rawValue, text: binding.text, prompt: Text(binding.wrappedValue.change ? field.prompt : "Unchanged"))
                .textFieldStyle(.roundedBorder)
                .disabled(!binding.wrappedValue.change)
                .accessibilityLabel("New \(field.rawValue.lowercased())")
        }
    }

    private var shiftDescription: String {
        switch shiftHours {
        case 0: "Don't move the dates"
        case 1: "1 hour later"
        case -1: "1 hour earlier"
        case let hours where hours > 0: "\(hours) hours later"
        default: "\(-shiftHours) hours earlier"
        }
    }

    private func value(_ field: Field) -> String? {
        guard let state = fields[field], state.change else { return nil }
        return state.text
    }

    private var edit: PhotoDetailsEdit {
        let date: PhotoDetailsEdit.DateChange = switch dateMode {
        case .keep: .keep
        case .shift: shiftHours == 0 ? .keep : .shift(hours: Double(shiftHours))
        case .set: .set(Self.cameraClock(newDate))
        }
        return PhotoDetailsEdit(
            date: date, title: value(.title), description: value(.description), author: value(.author),
            copyright: value(.copyright),
            keywords: value(.keywords).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        )
    }

    private var options: ConversionOptions {
        var options = ConversionOptions()
        options.task = .editDetails(edit)
        return options
    }

    /// The picked time as a camera writes it: the local wall clock, no time zone.
    static func cameraClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
