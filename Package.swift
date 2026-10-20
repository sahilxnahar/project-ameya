// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ameya",
    platforms: [.macOS(.v14)],
    targets: [
        // Formats, capability matrix, output naming, worker protocol and runner. No UI.
        .target(name: "AmeyaCore"),
        // Conversion engines. Linked only into the worker process.
        .target(name: "AmeyaEngines", dependencies: ["AmeyaCore"]),
        // One short-lived, sandboxed process per job. Reads stdin, writes stdout.
        .executableTarget(name: "AmeyaWorker", dependencies: ["AmeyaCore", "AmeyaEngines"]),
        // The menu bar app.
        .executableTarget(name: "Ameya", dependencies: ["AmeyaCore"]),

        .testTarget(name: "AmeyaCoreTests", dependencies: ["AmeyaCore"]),
        .testTarget(name: "AmeyaEnginesTests", dependencies: ["AmeyaEngines", "AmeyaCore"]),
        .testTarget(name: "AmeyaIntegrationTests", dependencies: ["AmeyaCore", "AmeyaWorker"]),
    ]
)
