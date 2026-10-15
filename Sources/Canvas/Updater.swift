// Auto-update from GitHub releases.
//
//   api.github.com/.../releases/latest
//        │  newer than CFBundleShortVersionString?
//        ▼
//   download GrandCentralTerminal-<ver>-macos-arm64.zip  ──► unzip
//        │  codesign --verify + same Team ID as the running app
//        ▼
//   spawn swap script (waits for our pid)
//        │  killDaemonAndQuit(): old gctd + app exit together
//        ▼
//   script: replace .app, `open` it ──► new app stages + spawns new gctd
//
// App and daemon ship in one bundle, so updating the bundle updates both.
// The daemon restart ends running panes; the prompt says so.
//
// Install on quit: same download + verify, but the swap waits for the
// user's own quit (staged .app held in memory until then).
//
// Rollback: the swap moves the old bundle to Support/updates/previous.app
// and drops a probation marker. A launch that never reaches HEALTHY_AFTER
// seconds leaves the marker behind; the next launch sees it, swaps the
// old bundle back, restarts the daemon, and skips that version.
//
//   swap ─► marker{attempts:0} ─► launch#1: attempts=1 ─► 30s alive: marker gone
//                                      └─ crash ─► launch#2: attempts>=1 ─► ROLLBACK

import AppKit

enum UpdateCheckMode {
    case silent  // launch/daily: only speak up when there is an update
    case manual  // menu: always answer
}

enum UpdateTiming {
    case now
    case onQuit
}

private enum Relaunch {
    case yes
    case no
}

private enum SwapResult {
    case started
    case cancelled
}

enum GCTUpdater {
    private static let releaseAPI =
        "https://api.github.com/repos/DWS-LLC/grandcentralterminal/releases/latest"
    private static let assetSuffix = "-macos-arm64.zip"
    private static let teamID = "P3FJ87836G"
    private static let lastCheckKey = "gctUpdateCheckedAt"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let launchDelay: TimeInterval = 10
    private static let httpOK = 200
    private static let skippedKey = "gctUpdateSkipped"
    private static let healthyAfter: TimeInterval = 30
    private static let maxLaunchAttempts = 1

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    private static var running = false
    private static var pendingApp: URL?
    private static var pendingTag = ""

    private struct Probation: Codable {
        var version: String
        var attempts: Int
    }

    private static var updatesDir: String { CanvasPaths.supportDir + "/updates" }
    private static var previousPath: String { updatesDir + "/previous.app" }
    private static var markerPath: String { updatesDir + "/probation.json" }
    private static var logPath: String { updatesDir + "/update.log" }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var skipped: [String] {
        UserDefaults.standard.stringArray(forKey: skippedKey) ?? []
    }

    private static func skip(_ tag: String) {
        UserDefaults.standard.set(skipped + [tag], forKey: skippedKey)
    }

    // Bare `swift run` has no .app to replace.
    private static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // Launch hook: delayed so it never competes with startup, throttled to
    // once a day.
    static func checkOnLaunch() {
        guard isBundled else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > checkInterval else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + launchDelay) {
            check(.silent)
        }
    }

    static func check(_ mode: UpdateCheckMode) {
        guard !running else { return }
        guard isBundled else {
            if mode == .manual { info("Not running from an app bundle.", "") }
            return
        }
        running = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        fetchLatest { release in
            running = false
            guard let release else {
                if mode == .manual { info("Couldn't reach GitHub.", "Try again later.") }
                return
            }
            guard isNewer(release.tag_name, than: currentVersion) else {
                if mode == .manual { info("You're up to date.", "Version \(currentVersion).") }
                return
            }
            if mode == .silent, skipped.contains(release.tag_name) { return }
            offer(release)
        }
    }

    // MARK: - Flow

    private static func offer(_ release: Release) {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(assetSuffix) }),
              let url = URL(string: asset.browser_download_url)
        else { return }

        let alert = NSAlert()
        alert.messageText = "GCT \(release.tag_name) is available"
        alert.informativeText = "You have \(currentVersion). Updating restarts the app and "
            + "the daemon; running panes will end."
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Install on Quit")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)

        let timing: UpdateTiming
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            timing = .now
        case .alertSecondButtonReturn:
            timing = .onQuit
        case .alertThirdButtonReturn:
            skip(release.tag_name)
            return
        default:
            return
        }

        running = true
        download(url) { staged in
            running = false
            guard let staged else { return fail("Download failed.") }
            guard verify(staged) else { return fail("Signature check failed; nothing was changed.") }

            switch timing {
            case .now:
                guard swap(staged, tag: release.tag_name, relaunch: .yes) == .started else { return }
                killDaemonAndQuit()
            case .onQuit:
                pendingApp = staged
                pendingTag = release.tag_name
            }
        }
    }

    private static func fetchLatest(_ done: @escaping (Release?) -> Void) {
        var req = URLRequest(url: URL(string: releaseAPI)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == httpOK
            let release = ok ? data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) } : nil
            DispatchQueue.main.async { done(release) }
        }.resume()
    }

    // Zip -> unzipped .app inside a fresh temp dir. nil on any failure.
    private static func download(_ url: URL, _ done: @escaping (URL?) -> Void) {
        URLSession.shared.downloadTask(with: url) { tmp, _, _ in
            let app = tmp.flatMap(unzip)
            DispatchQueue.main.async { done(app) }
        }.resume()
    }

    private static func unzip(_ zip: URL) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gct-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]).status == 0 else { return nil }
        let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let name = items.first(where: { $0.hasSuffix(".app") }) else { return nil }
        return dir.appendingPathComponent(name)
    }

    // Valid signature AND ours: a hijacked release must not self-install.
    private static func verify(_ app: URL) -> Bool {
        let strict = run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        guard strict.status == 0 else { return false }

        let info = run("/usr/bin/codesign", ["-dv", app.path])
        return info.output.contains("TeamIdentifier=\(teamID)")
    }

    // AppDelegate.applicationWillTerminate: the user quit with an update
    // staged. Same swap, no relaunch; the daemon goes too so the next
    // launch doesn't pair a new app with an old gctd.
    static func installPendingOnQuit() {
        guard let staged = pendingApp else { return }
        pendingApp = nil

        guard swap(staged, tag: pendingTag, relaunch: .no) == .started else { return }
        killDaemon()
    }

    // Detached swap script outlives us: wait for our pid, park the old
    // bundle in previous.app, move the new one in, arm probation, reopen.
    //
    // A bundle we don't own (`sudo cp -R` installs are root's) can't be
    // moved across directories or emptied by us, so that swap runs as root
    // behind one admin prompt. The new bundle comes from our own unzip,
    // so every later update is unprivileged.
    private static func swap(_ staged: URL, tag: String, relaunch: Relaunch) -> SwapResult {
        let dst = Bundle.main.bundleURL.path
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: (dst as NSString).deletingLastPathComponent) else {
            fail("\(dst) isn't writable; move the app somewhere you own.")
            return .cancelled
        }
        try? fm.createDirectory(atPath: updatesDir, withIntermediateDirectories: true)

        let admin = !fm.isWritableFile(atPath: dst)
        let marker = #"{"version":"\#(tag)","attempts":0}"#
        let uid = getuid()

        // Reopen whatever is at dst, even when the swap failed: never
        // leave the user with a dead app.
        let open = relaunch == .no ? "" : admin
            ? "/usr/bin/sudo -u #\(uid) /usr/bin/open \(shq(dst))"
            : "/usr/bin/open \(shq(dst))"
        let chown = admin ? "/usr/sbin/chown -R \(uid) \(shq(updatesDir))" : ""

        let script = """
            exec >> \(shq(logPath)) 2>&1
            echo "== swap to \(tag) =="
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            rm -rf \(shq(previousPath))
            if mv \(shq(dst)) \(shq(previousPath)) && mv \(shq(staged.path)) \(shq(dst)); then
                printf '%s' '\(marker)' > \(shq(markerPath))
            elif [ -d \(shq(previousPath)) ] && [ ! -e \(shq(dst)) ]; then
                mv \(shq(previousPath)) \(shq(dst))
            fi
            \(chown)
            \(open)
            """
        let file = updatesDir + "/swap.sh"
        try? script.write(toFile: file, atomically: true, encoding: .utf8)

        guard admin else {
            spawn("/bin/sh \(shq(file))")
            return .started
        }
        return runAdmin("/bin/sh \(shq(file)) >/dev/null 2>&1 &")
    }

    private static func runAdmin(_ shell: String) -> SwapResult {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(
            source: "do shell script \"\(escaped)\" with administrator privileges")

        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        guard let err else { return .started }

        NSLog("[gct] updater admin swap failed: \(err)")
        return .cancelled
    }

    // Launch guard (see header). Called first thing at startup.
    static func guardLaunch() {
        guard isBundled,
              let data = FileManager.default.contents(atPath: markerPath),
              var probation = try? JSONDecoder().decode(Probation.self, from: data)
        else { return }

        guard probation.attempts >= maxLaunchAttempts else {
            probation.attempts += 1
            try? JSONEncoder().encode(probation).write(to: URL(fileURLWithPath: markerPath))
            DispatchQueue.main.asyncAfter(deadline: .now() + healthyAfter) {
                try? FileManager.default.removeItem(atPath: markerPath)
            }
            return
        }

        rollBack(failed: probation.version)
    }

    private static func rollBack(failed tag: String) {
        try? FileManager.default.removeItem(atPath: markerPath)
        guard FileManager.default.fileExists(atPath: previousPath) else { return }

        skip(tag)
        let dst = Bundle.main.bundleURL.path
        let script = """
            while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
            rm -rf \(shq(dst)) && mv \(shq(previousPath)) \(shq(dst)) && open \(shq(dst))
            """
        spawn(script)
        killDaemonAndQuit()
    }

    private static func spawn(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            NSLog("[gct] updater spawn failed: \(error)")
        }
    }

    // MARK: - Helpers

    // "v0.4.1" vs "0.4.0": numeric, component-wise.
    private static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)

        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func run(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe  // codesign -dv writes to stderr

        do {
            try p.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func fail(_ why: String) {
        info("Update failed", why)
    }

    private static func info(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}
