import AmeyaCore
import Foundation
import SQLite3

/// Writes an SQL dump like `sqlite3 db .dump`: a transaction with each table's CREATE statement
/// and one INSERT per row, then indexes, views and triggers. Streams to disk in 1 MB chunks.
enum SQLDump {
    static func write(database: Database, tables: [SQLiteConverter.Table], to output: URL,
                      progress: (Double) -> Void) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var buffer = ""
        func emit(_ text: String) throws {
            buffer += text
            if buffer.utf8.count >= 1 << 20 {
                try handle.write(contentsOf: Data(buffer.utf8))
                buffer = ""
            }
        }

        let totalRows = max(tables.reduce(0) { $0 + $1.rows }, 1)
        var done = 0
        try emit("PRAGMA foreign_keys=OFF;\nBEGIN TRANSACTION;\n")
        for table in tables {
            try emit(table.createSQL + ";\n")
            let prefix = "INSERT INTO \(Database.quoted(table.name)) VALUES("
            try database.query("SELECT * FROM \(Database.quoted(table.name))") { row in
                let values = (0..<sqlite3_column_count(row)).map { literal(row, $0) }
                try emit(prefix + values.joined(separator: ",") + ");\n")
                done += 1
                if done % 10_000 == 0 { progress(0.1 + 0.85 * Double(done) / Double(totalRows)) }
            }
        }
        for statement in try database.otherSchemaSQL() {
            try emit(statement + ";\n")
        }
        try emit("COMMIT;\n")
        try handle.write(contentsOf: Data(buffer.utf8))
    }

    /// One value as an SQL literal that reads back to the same value and type.
    static func literal(_ row: OpaquePointer, _ column: Int32) -> String {
        switch sqlite3_column_type(row, column) {
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(row, column))
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(row, column)
            if value.isInfinite { return value > 0 ? "1e999" : "-1e999" }
            // %!.17g keeps full precision and always marks the value as REAL (e.g. "2.0").
            return Database.text(row, column).map { $0.contains(where: { ".eE".contains($0) }) ? $0 : $0 + ".0" }
                ?? String(value)
        case SQLITE_TEXT:
            let text = Database.text(row, column) ?? ""
            return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        case SQLITE_BLOB:
            let hex = Database.blob(row, column).map { String(format: "%02X", $0) }.joined()
            return "X'\(hex)'"
        default:
            return "NULL"
        }
    }
}
