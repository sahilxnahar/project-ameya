import AmeyaCore
import Foundation
import SQLite3

extension SelfTest {
    /// 3D models (including the GPU-rendered preview), single-file compression and SQLite,
    /// run through the real sandboxed worker.
    static func checkQuickWins(_ check: inout Checker, in directory: URL) async throws {
        // A square made of two triangles.
        let obj = directory.appendingPathComponent("square.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3\nf 1 3 4\n".utf8).write(to: obj)
        if let usdz = await check.convert(obj, from: .obj, to: .usdz) {
            await check.convert(usdz, from: .usdz, to: .stl)
        }
        await check.convert(obj, from: .obj, to: .png)

        let text = directory.appendingPathComponent("story.txt")
        let original = Data(String(repeating: "Once upon a time, ünïcødé. ", count: 200).utf8)
        try original.write(to: text)
        if let gz = await check.convert(text, from: .txt, to: .gz),
           let restored = await check.convert(gz, from: .gz, to: .decompressed) {
            let same = (try? Data(contentsOf: restored)) == original && restored.lastPathComponent.hasPrefix("story")
            print("\(same ? "PASS" : "FAIL") gz -> decompressed: \(restored.lastPathComponent) matches the original")
            if !same { check.allPassed = false }
        }

        let database = directory.appendingPathComponent("library.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let sql = "CREATE TABLE books (title TEXT, year INTEGER, cover BLOB);"
            + "INSERT INTO books VALUES ('Ameya', 2026, x'FF00'), ('Zoë', NULL, NULL);"
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        guard status == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        await check.convert(database, from: .sqlite, to: .csv)
    }
}
