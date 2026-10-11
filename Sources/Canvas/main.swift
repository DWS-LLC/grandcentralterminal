// Grand Central Terminal — infinite-canvas terminal app entry point.

import AppKit
import Common

// Borderless windows are not key by default; without a key window nothing
// ever receives keyDown.
final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var canvas: CanvasView!
    var doom: DoomController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Visible frame, not full frame: the borderless window sits below
        // the OS menubar (and above the Dock) instead of under them.
        // Tracks autohide automatically — when the menubar hides, the
        // visible frame grows and the window follows on next launch.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Config first; created with defaults if it doesn't exist yet.
        GCTConfig.current = GCTConfig.load()

        let win = CanvasWindow(
            contentRect: screen,
            styleMask: [.borderless, .miniaturizable],
            backing: .buffered,
            defer: false)
        win.title = "Grand Central Terminal"
        win.backgroundColor = .black  // replaced by the theme below
        win.isOpaque = false  // applyTheme sets true when background is opaque
        win.level = .normal
        win.collectionBehavior = [.fullScreenNone]
        win.isReleasedWhenClosed = false
        window = win

        let view = CanvasView(frame: NSRect(origin: .zero, size: screen.size))
        win.contentView = view
        canvas = view
        win.makeFirstResponder(view)

        // Daemon first (or reuse the running one), then connect.
        CanvasView.ensureDaemon()
        view.setup()

        // Theme last: the "ghostty" canvas background needs ghostty's
        // resolved config. Applied before the window is shown.
        view.applyTheme()

        // Doom mode: login item sync is unconditional (also unregisters a
        // stale item when the key flips off); hotkey + hidden launch only
        // when enabled.
        DoomController.syncLoginItem()
        let doom = DoomController(window: win, canvas: view)
        self.doom = doom
        // Config reload re-arms the global hotkey when [doom] toggle
        // changes (no relaunch). Structural keys still need one.
        NotificationCenter.default.addObserver(
            forName: .gctDoomHotkeyChanged, object: nil, queue: .main) { [weak doom] _ in
            doom?.reregisterHotkey(bind: GCTConfig.current.doom.toggle)
        }
        if GCTConfig.current.doom.enabled {
            // Follows the window across Spaces + over fullscreen apps,
            // like Ghostty's quick-terminal space behavior.
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            if let bind = GCTConfig.current.doom.toggle, doom.registerHotkey(bind: bind) {
                if GCTConfig.current.doom.startHidden {
                    // Visible-first: applyTheme/layout need a realized
                    // window for one tick, then order out.
                    win.makeKeyAndOrderFront(nil)
                    view.refreshOcclusion()
                    // Order out on the next tick, then pause every
                    // renderer: nothing can present while ordered-out.
                    DispatchQueue.main.async {
                        win.orderOut(nil)
                        view.refreshOcclusion()
                    }
                } else {
                    win.makeKeyAndOrderFront(nil)
                }
            } else {
                // Loud failure: a silent hotkey strands a hidden window
                // with the Dock as the only way back. Stay visible and
                // keep a local fallback (toggle works while frontmost).
                NSLog("[gct] doom: global hotkey registration FAILED — staying visible, local fallback only")
                win.makeKeyAndOrderFront(nil)
            }
        } else {
            win.makeKeyAndOrderFront(nil)
        }

        // Menubar/Dock autohide changes the visible frame live — follow
        // it without a restart. Fires on menubar show/hide, Dock
        // show/hide, display reconfigure, and resolution changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.conformToVisibleFrame()
        }
        // Borderless windows still resize from edges (we dropped .resizable
        // but AppKit keeps the zones live): snap back to the visible frame.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil,
            queue: .main) { [weak self] _ in
            self?.conformToVisibleFrame()
        }
        // Launch-hidden doom: don't steal focus; the hotkey summons.
        let doomHidden = GCTConfig.current.doom.enabled
            && GCTConfig.current.doom.startHidden && doom.hotkeyArmed
        if !doomHidden {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Re-fit the window to the screen's visible frame (below the
    /// menubar, above the Dock). Called live on screen changes.
    func conformToVisibleFrame() {
        guard let win = window,
              let vf = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        // Skip while minimized — never fight the user.
        guard !win.isMiniaturized else { return }
        // Doom-hidden: no frame to conform; show() re-targets the screen.
        guard win.isVisible else { return }
        if win.frame != vf {
            win.setFrame(vf, display: true, animate: true)
        }
    }

    // Dock click with no visible windows (doom-hidden, minimized, or
    // hidden-by-Cmd+H): summon the canvas. Doom owns the presentation
    // (screen pick, animation, previous-app stash); take the plain
    // path without doom. Returning false (not "open untitled") still
    // brings the ordered-out window back via show().
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        NSApp.unhide(nil)
        if let doom {
            doom.show()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return false
    }

    // Cmd+Q quits the canvas UI normally; panes keep running in gctd
    // (relaunch reattaches). The Dock menu's Quit Daemon kills gctd.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // closing the canvas detaches; panes keep running
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Canvas",
                              action: #selector(AppDelegate.dockShow(_:)),
                              keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let quit = NSMenuItem(
            title: "Quit Daemon (kills all terminals)",
            action: #selector(AppDelegate.dockQuitDaemon(_:)),
            keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }
    @objc func dockShow(_ sender: Any?) {
        NSApp.unhide(nil)
        if let doom {
            doom.show()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc func dockQuitDaemon(_ sender: Any?) {
        killDaemonAndQuit()
    }
}
// Ask gctd to shut down (kills every pane), then quit the canvas.
// Best-effort socket write; the daemon reaps panes and exits itself.
func killDaemonAndQuit() {
    let fd = connectUnixSocket(CanvasPaths.sockPath)
    if fd >= 0 {
        let conn = Conn(fd: fd)
        _ = conn.send(tag: .killDaemon, json: Hello(version: ProtoVersion))
        conn.close()
    }
    NSApp.terminate(nil)
}

// Minimal app menu: Cmd+Q only (terminal key handling is our own).
let app = NSApplication.shared
let menu = NSMenu()
let appMenuItem = NSMenuItem()
menu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(
    title: "Quit Grand Central Terminal", action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"))
appMenuItem.submenu = appMenu
app.mainMenu = menu

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
