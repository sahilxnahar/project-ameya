// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Ameya",
    platforms: [.macOS(.v14)],
    targets: [
        // Formats, capability matrix, output naming, worker protocol and runner. No UI.
        // Detection uses names and magic bytes only; nothing here decodes file contents,
        // so neither AmeyaCore nor the app links libarchive.
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
        .target(name: "AmeyaEngines", dependencies: ["AmeyaCore", "CArchive", "CWebP"],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // One short-lived, sandboxed process per job. Reads stdin, writes stdout.
        // Its embedded Info.plist lets a copy run under its own sandbox for the ameya CLI (build-app.sh).
        .executableTarget(name: "AmeyaWorker", dependencies: ["AmeyaCore", "AmeyaEngines"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                                         "-Xlinker", "\(packageRoot)/Resources/AmeyaWorker-Info.plist"])]),
        // The menu bar app.
        .executableTarget(name: "Ameya", dependencies: ["AmeyaCore"]),

        .testTarget(name: "AmeyaCoreTests", dependencies: ["AmeyaCore"]),
        .testTarget(name: "AmeyaEnginesTests", dependencies: ["AmeyaEngines", "AmeyaCore"]),
        .testTarget(name: "AmeyaIntegrationTests", dependencies: ["AmeyaCore", "AmeyaWorker"]),
        // Shortcuts actions and the ameya command-line tool (Sources/Ameya/Automation).
        .testTarget(name: "AmeyaAppTests", dependencies: ["Ameya", "AmeyaCore", "AmeyaWorker"]),
    ]
)
