// swift-tools-version:5.10
import PackageDescription

let manifestPath = #filePath
let root = String(manifestPath[..<manifestPath.firstRange(of: "/Package.swift")!.lowerBound])

let package = Package(
    name: "GrandCentralTerminal",
    platforms: [.macOS(.v14)],
    targets: [
        // C module over libghostty's embedding API.
        .systemLibrary(
            name: "CGhostty",
            path: "Sources/CGhostty"
        ),

        // Small C shim for reading a process's cwd (libproc).
        .target(
            name: "ProcInfo",
            path: "Sources/ProcInfo"
        ),

        // setsid + ctty + exec helper: the daemon spawns this instead of the
        // shell so panes get a real controlling terminal (SIGWINCH, ^C...).
        .executableTarget(
            name: "ptyexec",
            path: "Sources/PtyExec"
        ),

        .target(
            name: "Common",
            path: "Sources/Common"
        ),

        // Headless daemon that owns PTYs, panes, and persistence.
        .executableTarget(
            name: "gctd",
            dependencies: ["Common", "ProcInfo"],
            path: "Sources/Daemon"
        ),

        // The infinite-canvas terminal app.
        .executableTarget(
            name: "GrandCentralTerminal",
            dependencies: [
                "Common", "CGhostty",
                .byName(name: "ProcInfo"),
            ],
            path: "Sources/Canvas",
            linkerSettings: [
                .unsafeFlags(["-L\(root)/lib"]),
                .linkedLibrary("ghostty"),
                .linkedFramework("Metal"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
                .linkedLibrary("c++"),
                .linkedLibrary("bz2"),
                .linkedLibrary("z"),
            ]
        ),
    ]
)
