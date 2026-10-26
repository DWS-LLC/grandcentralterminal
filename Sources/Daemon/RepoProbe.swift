// Which git work tree a directory is in, found by reading .git directly:
// no `git` process per pane per poll.
//
//   /code/gct/Sources            .git is a directory  ──► root /code/gct
//   /wt/gct-feat                 .git is a file       ──► linked worktree
//     .git: "gitdir: /code/gct/.git/worktrees/gct-feat"
//     <gitdir>/HEAD: "ref: refs/heads/feat-x"          ──► branch feat-x

import Foundation

enum RepoProbe {
    struct Info: Equatable {
        var root: String
        // Branch of a linked worktree; nil for a main checkout (or submodule).
        var worktree: String?
    }

    private static let maxDepth = 40
    private static let gitdirPrefix = "gitdir:"
    private static let linkedMarker = "/worktrees/"
    private static let refPrefix = "ref: refs/heads/"
    private static let shortSHA = 7

    static func probe(cwd: String) -> Info? {
        let fm = FileManager.default
        var dir = cwd

        for _ in 0..<maxDepth {
            var isDir: ObjCBool = false
            let git = dir + "/.git"

            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                return Info(root: dir, worktree: isDir.boolValue ? nil : linkedBranch(git))
            }

            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
        return nil
    }

    private static func linkedBranch(_ gitFile: String) -> String? {
        guard let text = try? String(contentsOfFile: gitFile, encoding: .utf8),
              text.hasPrefix(gitdirPrefix) else { return nil }

        let gitdir = text.dropFirst(gitdirPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard gitdir.contains(linkedMarker),
              let head = try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8)
        else { return nil }

        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(refPrefix) { return String(line.dropFirst(refPrefix.count)) }
        return String(line.prefix(shortSHA))
    }
}
