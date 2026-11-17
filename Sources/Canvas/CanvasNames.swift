// Auto names: panes without a custom name get one from what runs in them
// (see Common/AutoName). Recomputed whenever a pane appears, goes, or its
// cwd / foreground command / program title changes.
//
//   daemon meta (cwd, proc, repo) ─┐
//   OSC title (pane.reportedTitle) ─┴─► AutoName.names ─► pane.autoName
//
// Remote panes are named per host: their paths live on another disk.

import AppKit
import Common

// Runs `work` once per main-thread turn however often it is scheduled:
// a spinner title can change many times a second.
final class Coalescer {
    private var pending = false
    private let work: () -> Void

    init(_ work: @escaping () -> Void) { self.work = work }

    func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.work()
        }
    }
}

extension CanvasView {
    func refreshAutoNames() {
        var byHost = [String: [AutoName.Pane]]()

        for pane in panes.values {
            let m = pane.meta
            let auto = AutoName.Pane(
                id: m.id, cwd: m.cwd, proc: m.proc, title: pane.reportedTitle,
                repoRoot: m.repoRoot, worktree: m.worktree)
            // The titlebar reads these even when the pane is named.
            let parts = AutoName.parts(auto, home: m.host == "local" ? NSHomeDirectory() : "")
            pane.titleParts = parts
            pane.iconLookup = Self.iconLookup(m, parts)

            guard m.name == nil else {
                pane.autoName = nil
                continue
            }

            byHost[m.host, default: []].append(auto)
        }

        for (host, group) in byHost {
            let home = host == "local" ? NSHomeDirectory() : ""
            for (id, name) in AutoName.names(group, home: home) {
                panes[id]?.autoName = name
            }
        }
    }

    // A program's icon comes from where it runs, which only this machine's
    // disk knows: remote panes and idle shells wear the plain >_.
    private static func iconLookup(_ meta: PaneMeta, _ parts: AutoName.Parts) -> PaneIcons.Lookup? {
        let local = meta.host == "local" || meta.host.isEmpty
        guard local, let program = parts.program else {
            return nil
        }

        let command = program.split(separator: " ").first.map(String.init)
        return PaneIcons.Lookup(exe: meta.exe, program: command)
    }
}
