// Daemon staging + CLI install.
//
// The release zip ships gctd/ptyexec inside the bundle. The app runs them
// from Application Support so the path stays stable across app updates
// (hooks, symlink) and a running daemon is never rewritten in place.
//
//   GCT.app/Contents/MacOS/{gctd,ptyexec}
//        │  stage(): cp + rename-swap
//        ▼
//   ~/Library/Application Support/Grand Central Terminal/bin/{gctd,ptyexec}
//        ▲  installCLI(): symlink (admin prompt) + agent hooks
//   /usr/local/bin/gctd

import AppKit

enum CLIInstallResult {
    case done
    case cancelled
    case failed(String)
}

enum DaemonInstall {
    private static let helperNames = ["gctd", "ptyexec"]
    private static let cliLink = "/usr/local/bin/gctd"
    private static let askedKey = "gctCLIPromptShown"

    private static var bundleDir: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path
    }

    private static var stagedDir: String {
        CanvasPaths.supportDir + "/bin"
    }

    // Copy missing or stale helpers from the bundle into bin/. No-op when
    // the bundle has none (swift run) or they already match (make build).
    static func stage() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: stagedDir, withIntermediateDirectories: true)

        for name in helperNames {
            let src = bundleDir + "/" + name
            let dst = stagedDir + "/" + name
            guard fm.isExecutableFile(atPath: src) else { continue }
            guard !fm.contentsEqual(atPath: src, andPath: dst) else { continue }
            swap(src, dst)
        }

        stageSkill()
    }

    // The daemon reads the skill from Support/skills/gct (../skills from
    // bin/); the bundle copy is only the source.
    private static func stageSkill() {
        let fm = FileManager.default
        guard let src = Bundle.main.path(forResource: "SKILL", ofType: "md") else { return }
        let dir = CanvasPaths.supportDir + "/skills/gct"
        let dst = dir + "/SKILL.md"
        guard !fm.contentsEqual(atPath: src, andPath: dst) else { return }

        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dst)
        do {
            try fm.copyItem(atPath: src, toPath: dst)
        } catch {
            NSLog("[gct] stage skill failed: \(error)")
        }
    }

    // cp to .new, then rename over dst: rewriting a running image in place
    // invalidates its code signature and macOS SIGKILLs every new exec.
    private static func swap(_ src: String, _ dst: String) {
        let fm = FileManager.default
        let tmp = dst + ".new"
        try? fm.removeItem(atPath: tmp)

        do {
            try fm.copyItem(atPath: src, toPath: tmp)
        } catch {
            NSLog("[gct] stage \(src) failed: \(error)")
            return
        }

        if Darwin.rename(tmp, dst) != 0 {
            NSLog("[gct] stage rename \(tmp) failed: errno \(errno)")
        }
    }

    private static var cliInstalled: Bool {
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink)
        return target == stagedDir + "/gctd"
    }

    // One-time opt-in on first launch; the menu item stays for later.
    static func offerOnce() {
        let defaults = UserDefaults.standard
        guard !cliInstalled, !defaults.bool(forKey: askedKey) else { return }
        defaults.set(true, forKey: askedKey)

        let alert = NSAlert()
        alert.messageText = "Install the gctd command?"
        alert.informativeText = "Links gctd into /usr/local/bin and adds the agent skill + "
            + "Claude session hook. Needs an administrator password. "
            + "You can do this later from the app menu."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        report(installCLI())
    }

    static func report(_ result: CLIInstallResult) {
        let alert = NSAlert()
        switch result {
        case .cancelled:
            return
        case .done:
            alert.messageText = "gctd installed"
            alert.informativeText = "\(cliLink) is ready, agent skill and hook installed."
        case .failed(let why):
            alert.alertStyle = .warning
            alert.messageText = "gctd install failed"
            alert.informativeText = why
        }
        alert.runModal()
    }

    static func installCLI() -> CLIInstallResult {
        stage()
        let gctd = stagedDir + "/gctd"

        let link = "mkdir -p /usr/local/bin && ln -sf \(shQuote(gctd)) \(cliLink)"
        switch runAdmin(link) {
        case .done: break
        case let other: return other
        }

        // Unprivileged: skill + hook land in the user's home. Runs after the
        // link so the hook command resolves to /usr/local/bin/gctd.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gctd)
        p.arguments = ["agent-setup", "install", "--hooks", "--yes"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            return .failed("agent-setup: \(error)")
        }
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            return .failed("agent-setup exited \(p.terminationStatus)")
        }
        return .done
    }

    private static let userCancelled = -128

    private static func runAdmin(_ shell: String) -> CLIInstallResult {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(
            source: "do shell script \"\(escaped)\" with administrator privileges")

        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        guard let err else { return .done }

        if err[NSAppleScript.errorNumber] as? Int == userCancelled {
            return .cancelled
        }
        return .failed(err[NSAppleScript.errorMessage] as? String ?? "link failed")
    }

    // 'a b' -> 'a b'; embedded ' -> '\''
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
