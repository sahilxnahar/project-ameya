// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ameya",
    platforms: [.macOS(.v14)],
    targets: [
        // Formats, capability matrix, output naming, worker protocol and runner. No UI.
        .target(name: "AmeyaCore"),
        // The system libarchive (BSD-2-Clause), which macOS ships without headers.
        .target(name: "CArchive", linkerSettings: [.linkedLibrary("archive")]),
        // Vendored libwebp 1.6.0 (BSD-3-Clause): WebP and animated WebP encoding, which ImageIO lacks.
        // SIMD (SSE2 on x86_64, NEON on arm64) is chosen by libwebp's own compiler/runtime checks.
        .target(
            name: "CWebP",
            exclude: ["COPYING", "PATENTS", "AUTHORS"],
            cSettings: [
                .headerSearchPath("."),
                .define("NDEBUG"),
            ]
        ),
        // Conversion engines. Linked only into the worker process.
        .target(name: "AmeyaEngines", dependencies: ["AmeyaCore", "CArchive", "CWebP"]),
        // One short-lived, sandboxed process per job. Reads stdin, writes stdout.
        .executableTarget(name: "AmeyaWorker", dependencies: ["AmeyaCore", "AmeyaEngines"]),
        // The menu bar app.
        .executableTarget(name: "Ameya", dependencies: ["AmeyaCore"]),

        .testTarget(name: "AmeyaCoreTests", dependencies: ["AmeyaCore"]),
        .testTarget(name: "AmeyaEnginesTests", dependencies: ["AmeyaEngines", "AmeyaCore"]),
        .testTarget(name: "AmeyaIntegrationTests", dependencies: ["AmeyaCore", "AmeyaWorker"]),
    ]
)
