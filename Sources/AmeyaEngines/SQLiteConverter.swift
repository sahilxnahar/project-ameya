import AmeyaCore
import Foundation
import CSQLite
import SQLite3

/// Exports SQLite databases to CSV (the largest table), JSON (every table) and an SQL dump.
///
/// The database is opened read-only with `immutable=1`, so SQLite never writes, locks or
/// replays a journal: the file is treated as a snapshot. Blobs become Base64 in CSV and JSON
/// and `X'…'` literals in SQL.
enum SQLiteConverter {
    struct Limits {
        var maxFileBytes: Int64 = 2 << 30
        /// Rows held in memory for CSV and JSON. The SQL dump streams, so it gets `maxDumpRows`.
        var maxRows = 1_000_000
        var maxDumpRows = 5_000_000
        /// Largest single value (text or blob) SQLite may make, e.g. from a generated column.
        var maxValueBytes: Int32 = 100_000_000
        /// Reading stops after this long, so a database built to run forever can't.
        var maxSeconds: Double = 600
    }

    struct Table {
        var name: String
        var createSQL: String
        var rows: Int
    }

    static func convert(input: URL, to target: FileFormat, output: URL,
                        limits: Limits = Limits(), progress: (Double) -> Void) throws -> [ConversionNote] {
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? 0)
        guard size <= limits.maxFileBytes else { throw ConversionError.dataLimit("databases over 2 GB aren't supported") }
        let database = try Database(url: input, limits: limits)
        let tables = try database.tables()
        guard !tables.isEmpty else { throw ConversionError.invalidData("the database has no tables") }
        progress(0.1)

        switch target {
        case .csv:
            let largest = tables.max { $0.rows < $1.rows }!
            guard largest.rows <= limits.maxRows else { throw tooManyRows(limits.maxRows) }
            var rows: [[DataValue]] = [try database.columns(of: largest.name).map(DataValue.string)]
            var sawBlob = false
            try database.forEachRow(of: largest.name) { values, blob in
                rows.append(values)
                sawBlob = sawBlob || blob
            }
            try DelimitedText.write(rows, delimiter: DelimitedText.comma).write(to: output)
            var notes: [ConversionNote] = tables.count > 1 ? [.onlyLargestTableKept] : []
            if sawBlob { notes.append(.binaryAsBase64) }
            return notes

        case .json:
            guard tables.reduce(0, { $0 + $1.rows }) <= limits.maxRows else { throw tooManyRows(limits.maxRows) }
            var fields: [DataValue.Field] = []
            var sawBlob = false
            for (index, table) in tables.enumerated() {
                let columns = try database.columns(of: table.name)
                var objects: [DataValue] = []
                try database.forEachRow(of: table.name) { values, blob in
                    objects.append(.object(zip(columns, values).map { DataValue.Field(key: $0, value: $1) }))
                    sawBlob = sawBlob || blob
                }
                fields.append(DataValue.Field(key: table.name, value: .array(objects)))
                progress(0.1 + 0.8 * Double(index + 1) / Double(tables.count))
            }
            try JSONWriter.write(.object(fields)).write(to: output)
            return sawBlob ? [.binaryAsBase64] : []

        case .sql:
            guard tables.reduce(0, { $0 + $1.rows }) <= limits.maxDumpRows else { throw tooManyRows(limits.maxDumpRows) }
            try SQLDump.write(database: database, tables: tables, to: output, progress: progress)
            return []

        default:
            throw ConversionError.unsupportedTarget(target)
        }
    }

    private static func tooManyRows(_ limit: Int) -> ConversionError {
        .dataLimit("it has more than \(limit.formatted()) rows")
    }
}

/// A read-only connection to one database file.
final class Database {
    private var handle: OpaquePointer?
    private let deadline: Date
    private let limits: SQLiteConverter.Limits

    init(url: URL, limits: SQLiteConverter.Limits = SQLiteConverter.Limits()) throws {
        self.limits = limits
        deadline = Date().addingTimeInterval(limits.maxSeconds)
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string else { throw ConversionError.unreadable }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            throw ConversionError.invalidData("it isn't a readable SQLite database")
        }
        // The file comes from anywhere, so its schema isn't trusted: views, triggers, defaults and
        // generated columns may only use harmless functions, values are capped in size, nothing
        // can be attached, and a progress check stops reading at the deadline. Extension loading
        // stays off, and `query` refuses any statement that writes.
        guard ameya_sqlite_harden(UnsafeMutableRawPointer(handle)) == 0 else {
            sqlite3_close(handle)
            handle = nil
            throw ConversionError.invalidData("it couldn't be opened safely")
        }
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, limits.maxValueBytes)
        sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 10_000_000)
        sqlite3_limit(handle, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(handle, SQLITE_LIMIT_EXPR_DEPTH, 1_000)
        sqlite3_limit(handle, SQLITE_LIMIT_COMPOUND_SELECT, 500)
        sqlite3_limit(handle, SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 10_000)
        sqlite3_limit(handle, SQLITE_LIMIT_TRIGGER_DEPTH, 10)
        sqlite3_progress_handler(handle, 10_000, { context in
            guard let context else { return 1 }
            return Date() > Unmanaged<Database>.fromOpaque(context).takeUnretainedValue().deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { sqlite3_close(handle) }

    /// User tables (not SQLite's own, not virtual-table shadows), by name, with row counts.
    func tables() throws -> [SQLiteConverter.Table] {
        var tables: [SQLiteConverter.Table] = []
        try query("SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name") { row in
            let name = Self.text(row, 0) ?? ""
            let sql = Self.text(row, 1) ?? ""
            // Virtual tables need modules that may not exist here; their data lives in shadow tables.
            guard !sql.uppercased().hasPrefix("CREATE VIRTUAL") else { return }
            tables.append(SQLiteConverter.Table(name: name, createSQL: sql, rows: 0))
        }
        for index in tables.indices {
            try query("SELECT count(*) FROM \(Self.quoted(tables[index].name))") { row in
                tables[index].rows = Int(sqlite3_column_int64(row, 0))
            }
        }
        return tables
    }

    /// Indexes, views and triggers, for the SQL dump.
    func otherSchemaSQL() throws -> [String] {
        var statements: [String] = []
        try query("SELECT sql FROM sqlite_master WHERE type IN ('index', 'view', 'trigger') AND sql IS NOT NULL ORDER BY type = 'trigger', rowid") { row in
            if let sql = Self.text(row, 0) { statements.append(sql) }
        }
        return statements
    }

    func columns(of table: String) throws -> [String] {
        var names: [String] = []
        try query("SELECT name FROM pragma_table_info(?)", bind: table) { row in
            names.append(Self.text(row, 0) ?? "")
        }
        return names
    }

    /// Calls `body` with each row as data values; the flag says whether the row held a blob.
    func forEachRow(of table: String, _ body: ([DataValue], Bool) throws -> Void) throws {
        try query("SELECT * FROM \(Self.quoted(table))") { row in
            var blob = false
            let values = (0..<sqlite3_column_count(row)).map { column -> DataValue in
                switch sqlite3_column_type(row, column) {
                case SQLITE_INTEGER: return .number(String(sqlite3_column_int64(row, column)))
                case SQLITE_FLOAT:
                    let value = sqlite3_column_double(row, column)
                    return value.isFinite ? .number(Self.text(row, column) ?? String(value)) : .null
                case SQLITE_TEXT: return .string(Self.text(row, column) ?? "")
                case SQLITE_BLOB:
                    blob = true
                    return .string(Self.blob(row, column).base64EncodedString())
                default: return .null
                }
            }
            try body(values, blob)
        }
    }

    /// Runs a read-only statement, calling `body` for each result row.
    func query(_ sql: String, bind parameter: String? = nil, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ConversionError.invalidData(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw ConversionError.invalidData("a statement would write") }
        if let parameter {
            sqlite3_bind_text(statement, 1, parameter, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(statement)
            case SQLITE_DONE: return
            case SQLITE_INTERRUPT:
                throw ConversionError.dataLimit("reading it took longer than \(Int(limits.maxSeconds / 60)) minutes")
            case SQLITE_TOOBIG:
                throw ConversionError.dataLimit("it holds a value larger than \(limits.maxValueBytes / 1_000_000) MB")
            default: throw ConversionError.invalidData(errorMessage)
            }
        }
    }

    private var errorMessage: String {
        sqlite3_errmsg(handle).map { String(cString: $0) } ?? "the database is damaged"
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(row, column) else { return nil }
        let count = Int(sqlite3_column_bytes(row, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, let pointer = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    /// An identifier in double quotes, with embedded quotes doubled.
    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
