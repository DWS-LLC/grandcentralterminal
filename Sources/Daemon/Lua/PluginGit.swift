// git, and nothing else about plugins: runs the binary and hands back its words.
//
// Plugins always sit on a detached commit, so what the lockfile pins is what
// runs. Prompts are off (GIT_TERMINAL_PROMPT=0): a private repo fails with
// git's message instead of hanging a CLI nobody is typing at.

import Foundation

enum PluginGit {
    private static let git = "git"
    private static let noPrompt = "GIT_TERMINAL_PROMPT"

    static func clone(_ url: String, to dir: String) throws {
        // `--`: a url that starts with a dash is a url, not an option.
        _ = try run(["clone", "--quiet", "--", url, dir], in: nil)
    }

    static func fetch(in dir: String) throws {
        _ = try run(["fetch", "--quiet", "--tags", "--force", "origin"], in: dir)
    }

    // `--` ends the revisions: a tag named like a file is still a tag.
    static func checkout(_ target: String, in dir: String) throws {
        _ = try run(["checkout", "--quiet", "--detach", target, "--"], in: dir)
    }

    static func head(in dir: String) throws -> String {
        try run(["rev-parse", "HEAD"], in: dir)
    }

    // True when the name resolves to a commit here (a branch, tag or hash).
    static func has(_ target: String, in dir: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", target + "^{commit}"], in: dir)) != nil
    }

    private static func run(_ args: [String], in dir: String?) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [git] + args
        if let dir {
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        var env = ProcessInfo.processInfo.environment
        env[noPrompt] = "0"
        p.environment = env
        p.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        do {
            try p.run()
        } catch {
            throw PluginError("can't run git: \(error.localizedDescription)")
        }

        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            throw PluginError("git \(args.first ?? ""): \(text.isEmpty ? "failed" : text)")
        }

        return text
    }
}
