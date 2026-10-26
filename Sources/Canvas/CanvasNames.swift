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
            guard pane.meta.name == nil else {
                pane.autoName = nil
                continue
            }

            let m = pane.meta
            byHost[m.host, default: []].append(AutoName.Pane(
                id: m.id, cwd: m.cwd, proc: m.proc, title: pane.reportedTitle,
                repoRoot: m.repoRoot, worktree: m.worktree))
        }

        for (host, group) in byHost {
            let home = host == "local" ? NSHomeDirectory() : ""
            for (id, name) in AutoName.names(group, home: home) {
                panes[id]?.autoName = name
            }
        }
    }
}
