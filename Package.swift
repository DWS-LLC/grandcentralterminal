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

        // GLSL -> MSL over the glslang/SPIRV-Cross symbols in libghostty.
        .target(
            name: "ShaderXlate",
            path: "Sources/ShaderXlate"
        ),

        // Lua 5.4 (vendored, MIT): the interpreter behind `gctd lua`. No
        // dlopen, so it links static on Linux; scripts get Lua modules only.
        .target(
            name: "CLua",
            path: "Sources/CLua",
            cSettings: [.define("LUA_USE_POSIX")]
        ),

        // setsid + ctty + exec helper: the daemon spawns this instead of the
        // shell so panes get a real controlling terminal (SIGWINCH, ^C...).
        .executableTarget(
            name: "ptyexec",
            path: "Sources/PtyExec"
        ),

        // Executable of the daemon's own app bundle: supervises gctd so the
        // app has an identity of its own for Local Network permission.
        .executableTarget(
            name: "GCTDaemon",
            path: "Sources/DaemonLauncher"
        ),

        .target(
            name: "Common",
            path: "Sources/Common"
        ),

        // Key notation + the key engine: pure logic, tested without a canvas.
        .testTarget(
            name: "CommonTests",
            dependencies: ["Common"],
            path: "Tests/CommonTests"
        ),

        // Headless daemon that owns PTYs, panes, and persistence.
        .executableTarget(
            name: "gctd",
            dependencies: ["Common", "ProcInfo", "CLua"],
            path: "Sources/Daemon"
        ),

        // The infinite-canvas terminal app.
        .executableTarget(
            name: "GrandCentralTerminal",
            dependencies: [
                "Common", "CGhostty",
                .byName(name: "ProcInfo"),
                .byName(name: "ShaderXlate"),
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
