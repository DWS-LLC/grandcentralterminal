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
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let win = CanvasWindow(
            contentRect: screen,
            styleMask: [.borderless, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        win.title = "Grand Central Terminal"
        win.backgroundColor = NSColor(white: 0.03, alpha: 1)
        win.isOpaque = true
        win.level = .normal
        win.collectionBehavior = [.fullScreenNone]
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        window = win

        let view = CanvasView(frame: NSRect(origin: .zero, size: screen.size))
        win.contentView = view
        canvas = view
        win.makeFirstResponder(view)

        // Daemon first (or reuse the running one), then connect.
        CanvasView.ensureDaemon()
        view.setup()

        NSApp.activate(ignoringOtherApps: true)
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
