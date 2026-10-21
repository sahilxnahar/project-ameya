import AmeyaCore
import Foundation

/// vCard 2.1, 3.0 and 4.0 contacts, read and written by Ameya's own code.
///
/// The Contacts framework's `CNContactVCardSerialization` was tried first. It needs no address
/// book permission, but it reads vCard 2.1 files without a CHARSET as Mac Roman (garbling
/// accented names) and silently drops NOTE when writing unless the app holds Apple's restricted
/// contacts-notes entitlement. A small parser is more predictable.
struct Contact: Equatable {
    var firstName = ""
    var lastName = ""
    var fullName = ""
    var organization = ""
    var emails: [String] = []
    var phones: [String] = []
    var addresses: [String] = []
    var birthday = ""
    var note = ""

    var isEmpty: Bool {
        firstName.isEmpty && lastName.isEmpty && fullName.isEmpty && organization.isEmpty
            && emails.isEmpty && phones.isEmpty && addresses.isEmpty && birthday.isEmpty && note.isEmpty
    }

    /// The name to show: FN, else given + family name, else organisation, email or phone.
    var displayName: String {
        if !fullName.isEmpty { return fullName }
        let joined = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return [joined, organization, emails.first ?? "", phones.first ?? ""].first { !$0.isEmpty } ?? ""
    }
}

enum VCard {
    static let maxContacts = 100_000

    // MARK: Reading

    static func parse(_ data: Data) throws -> [Contact] {
        let text = try TextRecoder.text(from: data)
        var contacts: [Contact] = []
        var current: Contact?
        for line in unfold(text) {
            guard let property = Property(line) else { continue }
            switch property.name {
            case "BEGIN" where property.rawValue.uppercased() == "VCARD":
                current = Contact()
            case "END" where property.rawValue.uppercased() == "VCARD":
                if var contact = current, !contact.isEmpty {
                    if contact.firstName.isEmpty, contact.lastName.isEmpty, !contact.fullName.isEmpty {
                        // No N property (allowed in vCard 4.0): split FN at its last space.
                        var words = contact.fullName.split(separator: " ").map(String.init)
                        contact.lastName = words.count > 1 ? words.removeLast() : ""
                        contact.firstName = words.joined(separator: " ")
                    }
                    contacts.append(contact)
                }
                current = nil
                guard contacts.count <= maxContacts else {
                    throw ConversionError.mediaFailed("the file has more than \(maxContacts) contacts")
                }
            default:
                if current != nil { apply(property, to: &current!) }
            }
        }
        guard !contacts.isEmpty else { throw ConversionError.mediaFailed("no contacts were found in this vCard file") }
        return contacts
    }

    private static func apply(_ property: Property, to contact: inout Contact) {
        let value = property.value
        switch property.name {
        case "FN": contact.fullName = unescape(value)
        case "N":
            let parts = splitUnescaped(value, on: ";")
            contact.lastName = parts.first.map(unescapeList) ?? ""
            contact.firstName = parts.count > 1 ? unescapeList(parts[1]) : ""
        case "ORG":
            contact.organization = splitUnescaped(value, on: ";").map(unescape).filter { !$0.isEmpty }.joined(separator: ", ")
        case "EMAIL": appendNonEmpty(unescape(value), to: &contact.emails)
        case "TEL":
            var number = unescape(value)
            if number.lowercased().hasPrefix("tel:") { number = String(number.dropFirst(4)) }
            appendNonEmpty(number, to: &contact.phones)
        case "ADR":
            // PO box; extended; street; locality; region; postal code; country
            let parts = splitUnescaped(value, on: ";").map(unescapeList)
            appendNonEmpty(parts.filter { !$0.isEmpty }.joined(separator: ", "), to: &contact.addresses)
        case "BDAY": contact.birthday = unescape(value)
        case "NOTE": contact.note = TextRecoder.normalizedLineEndings(unescape(value))
        default: break
        }
    }

    private static func appendNonEmpty(_ value: String, to list: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { list.append(trimmed) }
    }

    /// Joins folded lines (a line break followed by a space or tab) and vCard 2.1
    /// quoted-printable soft line breaks (a line ending in "=").
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else if let last = lines.last, last.hasSuffix("="), isQuotedPrintable(last) {
                lines[lines.count - 1] = String(last.dropLast()) + line
            } else {
                lines.append(line)
            }
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func isQuotedPrintable(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        return line[..<colon].uppercased().contains("QUOTED-PRINTABLE")
    }

    /// One content line: `[group.]NAME[;PARAM...]:value`.
    struct Property {
        var name: String
        var parameters: [String]
        var rawValue: String

        init?(_ line: String) {
            // The first colon outside a quoted parameter value separates name and value.
            var inQuotes = false
            var split: String.Index?
            for index in line.indices {
                if line[index] == "\"" { inQuotes.toggle() }
                if line[index] == ":" && !inQuotes { split = index; break }
            }
            guard let split else { return nil }
            var head = line[..<split].split(separator: ";").map(String.init)
            guard !head.isEmpty else { return nil }
            var name = head.removeFirst().uppercased()
            if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
            self.name = name
            self.parameters = head
            self.rawValue = String(line[line.index(after: split)...])
        }

        /// The value with quoted-printable and the declared charset decoded.
        var value: String {
            let upper = parameters.map { $0.uppercased() }
            guard upper.contains(where: { $0 == "QUOTED-PRINTABLE" || $0 == "ENCODING=QUOTED-PRINTABLE" }) else {
                return rawValue
            }
            let charset = upper.first { $0.hasPrefix("CHARSET=") }.map { String($0.dropFirst(8)) }
            let bytes = VCard.decodeQuotedPrintable(rawValue)
            if let charset, let encoding = TextRecoder.encoding(named: charset), let text = String(data: bytes, encoding: encoding) {
                return text
            }
            return (try? TextRecoder.decode(bytes).text) ?? rawValue
        }
    }

    static func decodeQuotedPrintable(_ text: String) -> Data {
        var out = Data()
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "="), index + 2 < bytes.count,
               let byte = UInt8(String(decoding: bytes[index + 1...index + 2], as: UTF8.self), radix: 16) {
                out.append(byte)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    /// Splits on a separator that isn't escaped with a backslash. Escapes are kept.
    static func splitUnescaped(_ value: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        parts.append(current)
        return parts
    }

    static func unescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for character in value {
            if escaped {
                out.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// A structured component whose own items are comma-separated (e.g. several given names).
    private static func unescapeList(_ value: String) -> String {
        splitUnescaped(value, on: ",").map(unescape).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Writing

    /// vCard 3.0 with CRLF line endings, lines folded at 75 bytes.
    static func write(_ contacts: [Contact]) -> Data {
        var out = ""
        for contact in contacts {
            var lines = ["BEGIN:VCARD", "VERSION:3.0"]
            lines.append("N:" + [contact.lastName, contact.firstName, "", "", ""].map(escape).joined(separator: ";"))
            lines.append("FN:" + escape(contact.displayName))
            if !contact.organization.isEmpty { lines.append("ORG:" + escape(contact.organization)) }
            lines += contact.emails.map { "EMAIL;TYPE=INTERNET:" + escape($0) }
            lines += contact.phones.map { "TEL:" + escape($0) }
            // The address was flattened to one line, so it goes in the street field.
            lines += contact.addresses.map { "ADR:;;" + escape($0) + ";;;;" }
            if !contact.birthday.isEmpty { lines.append("BDAY:" + escape(contact.birthday)) }
            if !contact.note.isEmpty { lines.append("NOTE:" + escape(contact.note)) }
            lines.append("END:VCARD")
            out += lines.map(fold).joined(separator: "\r\n") + "\r\n"
        }
        return Data(out.utf8)
    }

    static func escape(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case ";": out += "\\;"
            case ",": out += "\\,"
            case "\n", "\r\n", "\r": out += "\\n"
            default: out.append(character)
            }
        }
        return out
    }

    /// Folds a line into chunks of at most 75 UTF-8 bytes without splitting a character.
    static func fold(_ line: String) -> String {
        var chunks: [String] = []
        var current = ""
        var size = 0
        for character in line {
            let length = String(character).utf8.count
            let limit = chunks.isEmpty ? 75 : 74 // continuation lines start with a space
            if size + length > limit {
                chunks.append(current)
                current = ""
                size = 0
            }
            current.append(character)
            size += length
        }
        chunks.append(current)
        return chunks.joined(separator: "\r\n ")
    }

    // MARK: CSV and JSON

    static let csvColumns = ["First Name", "Last Name", "Organization", "Email", "Phone", "Address", "Birthday", "Note"]
    static let listSeparator = "; "

    static func csv(_ contacts: [Contact]) -> Data {
        let rows = [csvColumns] + contacts.map { contact in
            [contact.firstName, contact.lastName, contact.organization,
             contact.emails.joined(separator: listSeparator), contact.phones.joined(separator: listSeparator),
             contact.addresses.joined(separator: listSeparator), contact.birthday, contact.note]
        }
        return DelimitedText.write(rows.map { $0.map(DataValue.string) }, delimiter: DelimitedText.comma)
    }

    /// Header names accepted for each column, compared without case, spaces or punctuation.
    private static let aliases: [String: [String]] = [
        "First Name": ["firstname", "givenname", "first"],
        "Last Name": ["lastname", "familyname", "surname", "last"],
        "Organization": ["organization", "organisation", "company", "org"],
        "Email": ["email", "emailaddress", "email1", "emails", "e-mail"],
        "Phone": ["phone", "phonenumber", "telephone", "mobile", "mobilephone", "phones", "tel"],
        "Address": ["address", "addresses", "homeaddress", "postaladdress"],
        "Birthday": ["birthday", "birthdate", "dateofbirth", "bday"],
        "Note": ["note", "notes", "comment"],
        "Name": ["name", "fullname", "displayname"],
    ]

    static func contacts(fromCSV data: Data) throws -> [Contact] {
        let rows = try DelimitedText.parse(try TextRecoder.text(from: data), delimiter: nil)
        guard let header = rows.first else { throw ConversionError.mediaFailed("the CSV file is empty") }
        func key(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
        var column: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            let normalized = key(name)
            for (field, names) in aliases where column[field] == nil && names.map(key).contains(normalized) {
                column[field] = index
            }
        }
        guard !column.isEmpty else {
            throw ConversionError.mediaFailed("the CSV file has no contact columns (such as First Name, Email or Phone)")
        }
        func list(_ text: String) -> [String] {
            text.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let contacts = rows.dropFirst().map { row -> Contact in
            func cell(_ field: String) -> String {
                guard let index = column[field], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }
            return Contact(
                firstName: cell("First Name"), lastName: cell("Last Name"), fullName: cell("Name"),
                organization: cell("Organization"), emails: list(cell("Email")), phones: list(cell("Phone")),
                addresses: list(cell("Address")), birthday: cell("Birthday"), note: cell("Note")
            )
        }.filter { !$0.isEmpty }
        guard !contacts.isEmpty else { throw ConversionError.mediaFailed("the CSV file has no contacts") }
        return contacts
    }

    static func json(_ contacts: [Contact]) throws -> Data {
        let objects: [[String: Any]] = contacts.map { contact in
            [
                "firstName": contact.firstName, "lastName": contact.lastName, "fullName": contact.displayName,
                "organization": contact.organization, "emails": contact.emails, "phones": contact.phones,
                "addresses": contact.addresses, "birthday": contact.birthday, "note": contact.note,
            ]
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
