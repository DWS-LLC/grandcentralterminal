// Doom mode: Quake-style global-hotkey dropdown for the canvas window.
//
// When [doom] is enabled, a Carbon hotkey (no Accessibility permission,
// fires while hidden/backgrounded) summons the fullscreen canvas with a
// slide-down or fade animation; the same hotkey hides it and restores the
// previously frontmost app. Hotkey only — panning the canvas never hides
// it. The PTYs keep running either way; doom only owns the window.

import AppKit
import Carbon
import ServiceManagement

extension Notification.Name {
    /// Local doom-toggle fallback: CanvasView posts this when its own
    /// keyDown sees the toggle combo (e.g. Carbon registration failed
    /// but the window is frontmost). Carbon eats registered combos
    /// system-wide, so this never double-fires with the hotkey.
    static let gctToggleDoom = Notification.Name("dev.dubey.gct.toggleDoom")
}

// MARK: - GCTKeybind doom matching

extension GCTKeybind {
    /// Layout-independent match on virtual keycode. The only local match
    /// for named keys (space, F12, ...) that produce no single character.
    func matchesKeyCode(_ event: NSEvent) -> Bool {
        guard let code = carbonKeyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(relevant) == mods.intersection(relevant) else {
            return false
        }
        return event.keyCode == UInt16(code)
    }
}

// MARK: - Carbon global hotkey

/// System-wide hotkey via RegisterEventHotKey: no permission prompt, fires
/// while hidden/backgrounded. The combo is eaten system-wide while GCT
/// runs (shells never see it). Single instance via `current`.
final class DoomHotkey {
    static weak var current: DoomHotkey?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// False when the combo has no keycode or the system refuses it
    /// (already taken). Callers must treat false as loud failure.
    func register(bind: GCTKeybind) -> Bool {
        guard let code = bind.carbonKeyCode else { return false }
        DoomHotkey.current = self
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(
            GetApplicationEventTarget(),
            doomHotKeyHandler,
            1, &spec, nil, &handlerRef) == noErr else { return false }
        let id = EventHotKeyID(signature: 0x47435444, id: 1) // 'GCTD'
        let status = RegisterEventHotKey(
            code, bind.carbonModifiers, id,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handlerRef = nil
            return false
        }
        return true
    }

    fileprivate func fire() { action() }
}

/// Runs on the main thread (application event target). Async so Carbon
/// dispatch never reenters; DoomController.toggle debounces the case where
/// the system delivers both the Carbon event and a local keyDown.
private func doomHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async { DoomHotkey.current?.fire() }
    return noErr
}

// MARK: - Doom controller

/// Owns doom-mode window presentation: summon/hide with slide-or-fade,
/// screen picking, previous-app restore, launch-hidden, login item.
final class DoomController {
    private weak var window: NSWindow?
    private weak var canvas: CanvasView?
    private var hotkey: DoomHotkey?
    private var animating = false
    private var lastToggle = Date.distantPast
    private var previousApp: NSRunningApplication?
    private var observers = [NSObjectProtocol]()

    /// True once the global hotkey owns the window. Launch-hidden gates
    /// on this, never on `enabled` alone: without an armed hotkey there
    /// is no way back except the Dock, so a fallback window stays visible.
    private(set) var hotkeyArmed = false

    init(window: NSWindow, canvas: CanvasView) {
        self.window = window
        self.canvas = canvas
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .gctToggleDoom, object: nil, queue: .main
        ) { [weak self] _ in self?.toggle() })
        observers.append(center.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Cmd+H: the system hid us; drop stale restore state. The
            // occlusion check reads window visibility live, no sync needed.
            self?.previousApp = nil
            self?.canvas?.refreshOcclusion()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Hotkey

    @discardableResult
    func registerHotkey(bind: GCTKeybind) -> Bool {
        let hk = DoomHotkey { [weak self] in self?.toggle() }
        guard hk.register(bind: bind) else { return false }
        hotkey = hk
        hotkeyArmed = true
        NSLog("[gct] doom: global hotkey armed")
        return true
    }

    // MARK: Toggle

    func toggle() {
        // Debounce: a single press delivered twice (Carbon event plus a
        // local keyDown) lands here in the same tick; the second must not
        // undo the first. Costs: intentional re-toggles under ~250ms drop.
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.25, !animating else { return }
        if window?.isVisible == true {
            hide(restorePrevious: true)
        } else {
            show()
        }
    }

    func show() {
        guard let win = window, !animating else { return }
        if win.isMiniaturized {
            lastToggle = Date()
            win.deminiaturize(nil)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            afterVisible()
            return
        }
        let screen = targetScreen() ?? win.screen ?? NSScreen.main
        guard let screen else { return }
        lastToggle = Date()
        let final = screen.visibleFrame
        let cfg = GCTConfig.current.doom

        // Stash the app to restore on hide — never ourselves.
        if !NSApp.isActive,
           let prev = NSWorkspace.shared.frontmostApplication,
           prev.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = prev
        }

        animating = true
        switch cfg.animation {
        case .slide:
            // Park above the visible area, order front, slide down.
            win.setFrame(NSRect(
                x: final.minX, y: final.maxY,
                width: final.width, height: final.height), display: false)
            win.alphaValue = 1
        case .fade:
            win.setFrame(final, display: false)
            win.alphaValue = 0
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runAnimation(duration: cfg.animationDuration, frame: final, alpha: 1) { [weak self] in
            self?.animating = false
            self?.afterVisible()
        }
    }

    func hide(restorePrevious: Bool) {
        guard let win = window, !animating, win.isVisible else { return }
        // A rename/group sheet lives on this window; hiding under it
        // strands the prompt. Hotkey does nothing until it closes.
        guard win.attachedSheet == nil else { return }
        lastToggle = Date()
        // Restore BEFORE animating out: macOS picks the next frontmost
        // app when we order out, and doing it first keeps that choice ours.
        if restorePrevious, let prev = previousApp, !prev.isTerminated {
            prev.activate(options: [])
        }
        previousApp = nil
        let cfg = GCTConfig.current.doom
        animating = true
        var off = win.frame
        off.origin.y = off.maxY // slide back up past the visible area
        let target: NSRect
        let alpha: CGFloat
        switch cfg.animation {
        case .slide: target = off; alpha = 1
        case .fade: target = win.frame; alpha = 0
        }
        runAnimation(duration: cfg.animationDuration, frame: target, alpha: alpha) { [weak self] in
            guard let self, let win = self.window else { return }
            win.orderOut(nil)
            win.alphaValue = 1
            self.animating = false
            self.canvas?.refreshOcclusion()
        }
    }

    // MARK: Internals

    private func runAnimation(
        duration: Double, frame: NSRect, alpha: CGFloat, done: @escaping () -> Void
    ) {
        guard let win = window, duration > 0 else {
            window?.setFrame(frame, display: true)
            window?.alphaValue = alpha
            done()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().setFrame(frame, display: true)
            win.animator().alphaValue = alpha
        }, completionHandler: done)
    }

    private func afterVisible() {
        guard let win = window else { return }
        win.makeFirstResponder(canvas)
        canvas?.refreshOcclusion()
    }

    private func targetScreen() -> NSScreen? {
        switch GCTConfig.current.doom.screen {
        case .main:
            return NSScreen.main
        case .menubar:
            return NSScreen.screens.first
        case .mouse:
            let loc = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { $0.frame.contains(loc) })
                ?? NSScreen.main
        }
    }

    // MARK: Login item

    /// Idempotent against the stored status: register when asked,
    /// unregister when not. Scoped to doom mode; called once at launch.
    static func syncLoginItem() {
        let want = GCTConfig.current.doom.launchAtLogin
        let svc = SMAppService.mainApp
        do {
            if want, svc.status != .enabled {
                try svc.register()
                NSLog("[gct] doom: registered login item")
            } else if !want, svc.status == .enabled {
                try svc.unregister()
                NSLog("[gct] doom: removed login item")
            }
        } catch {
            NSLog("[gct] doom: login item sync failed: \(error)")
        }
    }
}
