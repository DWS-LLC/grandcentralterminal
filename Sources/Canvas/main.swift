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
            styleMask: [.borderless, .resizable, .miniaturizable],
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
        win.makeKeyAndOrderFront(nil)

        // Menubar/Dock autohide changes the visible frame live — follow
        // it without a restart. Fires on menubar show/hide, Dock
        // show/hide, display reconfigure, and resolution changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.conformToVisibleFrame()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-fit the window to the screen's visible frame (below the
    /// menubar, above the Dock). Called live on screen changes.
    func conformToVisibleFrame() {
        guard let win = window,
              let vf = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        // Skip while minimized — never fight the user.
        guard !win.isMiniaturized else { return }
        if win.frame != vf {
            win.setFrame(vf, display: true, animate: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // closing the canvas detaches; panes keep running
    }
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
