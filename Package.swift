// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ameya",
    platforms: [.macOS(.v14)],
    targets: [
        // Formats, capability matrix, output naming, worker protocol and runner. No UI.
        // Uses libarchive only to peek at the start of .gz/.bz2/.xz files (TAR or single file?).
        .target(name: "AmeyaCore", dependencies: ["CArchive"]),
        // The system libarchive (BSD-2-Clause), which macOS ships without headers.
        .target(name: "CArchive", linkerSettings: [.linkedLibrary("archive")]),
        // Conversion engines. Linked only into the worker process.
        .target(name: "AmeyaEngines", dependencies: ["AmeyaCore", "CArchive"],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // One short-lived, sandboxed process per job. Reads stdin, writes stdout.
        .executableTarget(name: "AmeyaWorker", dependencies: ["AmeyaCore", "AmeyaEngines"]),
        // The menu bar app.
        .executableTarget(name: "Ameya", dependencies: ["AmeyaCore"]),

        .testTarget(name: "AmeyaCoreTests", dependencies: ["AmeyaCore"]),
        .testTarget(name: "AmeyaEnginesTests", dependencies: ["AmeyaEngines", "AmeyaCore"]),
        .testTarget(name: "AmeyaIntegrationTests", dependencies: ["AmeyaCore", "AmeyaWorker"]),
    ]
)
