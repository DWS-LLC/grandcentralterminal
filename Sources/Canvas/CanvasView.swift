// The infinite canvas: all mouse/keyboard routing, camera, pane lifecycle.

import AppKit
import CGhostty
import Common

final class CanvasView: NSView {
    // MARK: State

    let worldView = NSView(frame: .zero)
    private(set) var camera = Camera()
    var panes = [PaneID: PaneView]()
    var zOrder = [PaneID]()
    private(set) var focusedID: PaneID?

    var conn: CanvasConn?
    private(set) var ghosttyApp: GhosttyApp?

    // Drag state machine.
    private enum Drag {
        case none
        case pan(start: CGPoint, offset0: CGPoint)
        case move(id: PaneID, grabDelta: CGPoint)
        case resize(id: PaneID, zone: PaneView.ResizeZone, rect0: NSRect)
        case surfaceClick(id: PaneID, button: ghostty_input_mouse_button_e)
    }
    private var drag = Drag.none

    // Weak: removeFromSuperview drops the last strong reference, so the
    // property self-clears after dismissal.
    private weak var switcher: SwitcherView?
    var firstRunHandled = false

    // MARK: Setup

    func setup() {
        ghosttyApp = GhosttyApp(delegate: self)
        worldView.wantsLayer = true
        addSubview(worldView)
        worldView.frame = bounds
        worldView.autoresizingMask = [.width, .height]
        window?.acceptsMouseMovedEvents = true

        conn = CanvasConn(sockPath: CanvasPaths.sockPath)
        conn?.delegate = self
        conn?.start()
    }

    override var acceptsFirstResponder: Bool { true }

    // Manual routing: the world layer transform means AppKit hit-testing
    // is meaningless for panes; we take every event ourselves. Screen-space
    // overlays (the switcher) still get normal hit-testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let switcher, switcher.window != nil,
           switcher.frame.contains(convert(point, from: superview)) {
            return switcher
        }
        return self
    }

    private func applyCamera() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        worldView.layer?.sublayerTransform = camera.transform()
        CATransaction.commit()
    }

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func worldPoint(_ event: NSEvent) -> CGPoint {
        camera.screenToWorld(viewPoint(event))
    }

    // MARK: Pane lookup helpers

    private func topPane(at worldPoint: CGPoint) -> PaneView? {
        for id in zOrder.reversed() {
            if let pane = panes[id], pane.containsWorld(worldPoint) { return pane }
        }
        return nil
    }

    private func bringToFront(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        zOrder.removeAll { $0 == id }
        zOrder.append(id)
        pane.removeFromSuperview()
        worldView.addSubview(pane)
    }

    func focusPane(_ id: PaneID) {
        guard panes[id] != nil else { return }
        if let old = focusedID, old != id {
            panes[old]?.host?.setFocus(false)
            panes[old]?.isFocused = false
        }
        focusedID = id
        if let pane = panes[id] {
            pane.isFocused = true
            pane.host?.setFocus(true)
            window?.makeFirstResponder(self)
        }
        bringToFront(id)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let world = worldPoint(event)

        if let pane = topPane(at: world) {
            focusPane(pane.id)
            if let zone = pane.resizeZone(at: world,
                                          screenTolerance: camera.worldToScreenDistance(5)) {
                drag = .resize(id: pane.id, zone: zone, rect0: pane.frame)
                return
            }
            if pane.isInTitlebar(world) {
                drag = .move(id: pane.id,
                             grabDelta: CGPoint(x: world.x - pane.frame.minX,
                                                y: world.y - pane.frame.minY))
                return
            }
            // Terminal surface click.
            let local = paneLocal(pane, world)
            let mods = GhosttyMods(event.modifierFlags)
            let button: ghostty_input_mouse_button_e =
                event.buttonNumber == 1 ? GHOSTTY_MOUSE_RIGHT : GHOSTTY_MOUSE_LEFT
            pane.host?.mousePos(x: local.x, y: local.y, mods: mods)
            pane.host?.mouseButton(GHOSTTY_MOUSE_PRESS, button, mods)
            drag = .surfaceClick(id: pane.id, button: button)
            return
        }

        drag = .pan(start: viewPoint(event), offset0: camera.offset)
    }

    override func mouseDragged(with event: NSEvent) {
        switch drag {
        case .pan(let start, let offset0):
            let p = viewPoint(event)
            camera.offset = CGPoint(x: offset0.x + (p.x - start.x),
                                    y: offset0.y + (p.y - start.y))
            applyCamera()
        case .move(let id, let grabDelta):
            guard let pane = panes[id] else { return }
            let world = worldPoint(event)
            pane.setRect(NSRect(x: world.x - grabDelta.x, y: world.y - grabDelta.y,
                                width: pane.frame.width,
                                height: pane.frame.height),
                         notifySurface: false)
        case .resize(let id, let zone, let rect0):
            guard let pane = panes[id] else { return }
            let world = worldPoint(event)
            var rect = rect0
            let minW: CGFloat = 160, minH: CGFloat = 120
            if zone.resizesW {
                rect.origin.x = min(world.x, rect0.maxX - minW)
                rect.size.width = rect0.maxX - rect.origin.x
            }
            if zone.resizesE { rect.size.width = max(minW, world.x - rect0.minX) }
            if zone.resizesS {
                rect.origin.y = min(world.y, rect0.maxY - minH)
                rect.size.height = rect0.maxY - rect.origin.y
            }
            if zone.resizesN { rect.size.height = max(minH, world.y - rect0.minY) }
            pane.setRect(rect, notifySurface: true)
        case .surfaceClick, .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .surfaceClick(let id, let button) = drag, let pane = panes[id] {
            let world = worldPoint(event)
            let local = paneLocal(pane, world)
            let mods = GhosttyMods(event.modifierFlags)
            pane.host?.mousePos(x: local.x, y: local.y, mods: mods)
            pane.host?.mouseButton(GHOSTTY_MOUSE_RELEASE, button, mods)
        }
        if case .move(let id, _) = drag, let pane = panes[id] {
            conn?.movePane(MovePane(id: id, rect: pane.meta.rect))
        }
        drag = .none
    }

    override func mouseMoved(with event: NSEvent) {
        guard let id = focusedID, let pane = panes[id] else { return }
        let world = worldPoint(event)
        guard pane.containsWorld(world) else { return }
        let local = paneLocal(pane, world)
        pane.host?.mousePos(x: local.x, y: local.y, mods: GhosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        // Shift+wheel (or horizontal) = terminal scrollback; plain wheel zooms.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            let pane = topPane(at: worldPoint(event)) ?? focusedID.flatMap { panes[$0] }
            let dx = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 2 : 12)
            pane?.host?.mouseScroll(x: -dx, y: 0, precision: event.hasPreciseScrollingDeltas)
            return
        }
        if event.modifierFlags.contains(.shift) {
            let pane = topPane(at: worldPoint(event)) ?? focusedID.flatMap { panes[$0] }
            let dy = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 2 : 12)
            pane?.host?.mouseScroll(x: 0, y: dy, precision: event.hasPreciseScrollingDeltas)
            return
        }
        let factor = exp(-event.scrollingDeltaY / 400)
        camera.zoom(at: viewPoint(event), factor: factor)
        applyCamera()
    }

    private func paneLocal(_ pane: PaneView, _ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x - pane.frame.minX, y: world.y - pane.frame.minY)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // App shortcuts first.
        if event.modifierFlags.contains(.command),
           let c = event.charactersIgnoringModifiers {
            switch c {
            case "t": newPane(); return
            case "w": if let id = focusedID { closePane(id) }; return
            case "r": if let id = focusedID { renamePane(id) }; return
            case "k": toggleSwitcher(); return
            case "0": fitAll(); return
            case "v": pasteIntoFocused(); return
            case "c": copyFromFocused(); return
            default: break
            }
        }

        guard let id = focusedID, let pane = panes[id], let host = pane.host else {
            super.keyDown(with: event)
            return
        }

        let action: ghostty_input_action_e =
            event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if sendKey(event, action, to: host) { return }

        // Surface didn't encode it; fall back to literal characters when
        // no command modifier is held.
        if let chars = event.characters, !chars.isEmpty,
           event.modifierFlags.intersection([.command]).isEmpty {
            host.text(chars)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let id = focusedID, let pane = panes[id], let host = pane.host else {
            super.flagsChanged(with: event)
            return
        }
        let mods = GhosttyMods(event.modifierFlags)
        let mod: UInt32
        switch event.keyCode {
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        let action: ghostty_input_action_e =
            mods.rawValue & mod != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        _ = sendKey(event, action, to: host)
    }

    // NSEvent -> ghostty key event, mirrors Ghostty's own macOS conversion.
    private func sendKey(_ event: NSEvent, _ action: ghostty_input_action_e,
                         to host: SurfaceHost) -> Bool {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.mods = GhosttyMods(event.modifierFlags)
        // control/command never contribute to text translation.
        ev.consumed_mods = GhosttyMods(
            event.modifierFlags.subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        ev.composing = false

        // Filter control chars and PUA function keys out of the text, then
        // strdup so the buffer outlives the call.
        var textStr = event.characters
        if let s = textStr, s.count == 1, let u = s.unicodeScalars.first {
            if u.value < 0x20 {
                textStr = event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control))
            } else if u.value >= 0xF700 && u.value <= 0xF8FF {
                textStr = nil
            }
        }
        let cText: UnsafeMutablePointer<CChar>? = textStr.map { strdup($0) }
        if let c = cText { ev.text = UnsafePointer(c) }
        defer { free(cText) }
        return host.key(ev)
    }

    private func pasteIntoFocused() {
        guard let id = focusedID, let pane = panes[id] else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        pane.host?.text(text)
    }

    private func copyFromFocused() {
        guard let id = focusedID, let pane = panes[id] else { return }
        if let selection = pane.host?.copySelection() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection, forType: .string)
            return
        }
        // No selection: cmd+c acts like ^C.
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.mods = GHOSTTY_MODS_CTRL
        let c = strdup("\u{03}")
        if let c { ev.text = UnsafePointer(c) }
        defer { free(c) }
        _ = pane.host?.key(ev)
    }

    override func insertText(_ insertString: Any) {
        guard let id = focusedID, let pane = panes[id] else { return }
        if let str = insertString as? String { pane.host?.text(str) }
    }

    // MARK: Pane lifecycle

    func newPane() {
        let cwd = focusedID.flatMap { panes[$0]?.meta.cwd }
        if let id = focusedID, let pane = panes[id] {
            let r = pane.frame
            conn?.createPane(CreatePane(
                rect: Rect(x: r.minX + 40, y: r.minY + 40,
                           w: r.width, h: r.height),
                cwd: cwd))
        } else {
            conn?.createPane(CreatePane(
                rect: Rect(x: 0, y: 0, w: 900, h: 560), cwd: cwd))
        }
    }

    func closePane(_ id: PaneID) {
        conn?.closePane(id)
    }

    func renamePane(_ id: PaneID) {
        guard let pane = panes[id], let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename pane"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = pane.meta.name ?? ""
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.conn?.renamePane(RenamePane(id: id, name: name.isEmpty ? nil : name))
        }
    }

    func removePane(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        pane.host?.close()
        pane.removeFromSuperview()
        panes.removeValue(forKey: id)
        zOrder.removeAll { $0 == id }
        if focusedID == id {
            focusedID = nil
            if let last = zOrder.last { focusPane(last) }
        }
    }

    func makePaneView(_ meta: PaneMeta) {
        guard panes[meta.id] == nil else { return }
        let pane = PaneView(meta: meta)
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        let host = SurfaceHost(paneID: meta.id, hostView: pane.surfaceHostView,
                               scale: scale, app: ghosttyApp!.app,
                               delegate: self)
        host.connSend = { [weak self] id, data in
            self?.conn?.sendInput(id, data)
        }
        pane.install(host: host)
        panes[meta.id] = pane
        zOrder.append(meta.id)
        worldView.addSubview(pane)

        // Attach after the surface exists; the daemon answers with the
        // scrollback ring, then live output.
        conn?.attachPane(AttachPane(id: meta.id, cols: 80, rows: 24))
        focusPane(meta.id)

        // One layout pass later, push the real pixel size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.panes[meta.id]?.syncSurfaceSize()
        }
    }

    // MARK: Camera actions

    func zoomToPane(_ id: PaneID) {
        guard let pane = panes[id], let window else { return }
        let screen = window.frame.size
        let r = pane.frame
        let fit = min(CGFloat(0.8) * screen.width / r.width,
                      CGFloat(0.8) * screen.height / r.height,
                      Camera.maxScale)
        animateCamera(to: Camera(
            offset: CGPoint(x: screen.width / 2 - r.midX * fit,
                            y: screen.height / 2 - r.midY * fit),
            scale: fit))
    }

    func fitAll() {
        guard !zOrder.isEmpty, let window else { return }
        var bbox = CGRect.null
        for pane in panes.values { bbox = bbox.union(pane.frame) }
        let screen = window.frame.size
        let fit = min(screen.width / bbox.width,
                      screen.height / bbox.height,
                      Camera.maxScale) * 0.92
        animateCamera(to: Camera(
            offset: CGPoint(x: screen.width / 2 - bbox.midX * fit,
                            y: screen.height / 2 - bbox.midY * fit),
            scale: fit))
    }

    private var cameraAnim: (Timer, Camera, Camera, Double)?

    func animateCamera(to target: Camera) {
        cameraAnim?.0.invalidate()
        let from = camera
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.stepCamera()
        }
        RunLoop.main.add(timer, forMode: .common)
        cameraAnim = (timer, from, target, CACurrentMediaTime())
    }

    private func stepCamera() {
        guard let anim = cameraAnim else { return }
        let t = min((CACurrentMediaTime() - anim.3) / 0.28, 1)
        let ease = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        camera = Camera(
            offset: CGPoint(x: anim.1.offset.x + (anim.2.offset.x - anim.1.offset.x) * ease,
                            y: anim.1.offset.y + (anim.2.offset.y - anim.1.offset.y) * ease),
            scale: anim.1.scale + (anim.2.scale - anim.1.scale) * ease)
        applyCamera()
        if t >= 1 {
            anim.0.invalidate()
            cameraAnim = nil
        }
    }

    // MARK: Switcher

    func toggleSwitcher() {
        if let switcher {
            switcher.dismiss()
            window?.makeFirstResponder(self)
            return
        }
        let s = SwitcherView(frame: NSRect(x: bounds.midX - 320, y: bounds.midY - 240,
                                           width: 640, height: 480))
        s.onSelect = { [weak self] id in
            self?.focusPane(id)
            self?.zoomToPane(id)
        }
        s.onDismiss = { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
        addSubview(s)
        switcher = s
        s.present(panes.values.map(\.meta), order: zOrder)
    }
}

// MARK: Resize zones as flags

extension PaneView.ResizeZone {
    var resizesW: Bool {
        switch self { case .w, .nw, .sw: return true; default: return false }
    }
    var resizesE: Bool {
        switch self { case .e, .ne, .se: return true; default: return false }
    }
    var resizesS: Bool {
        switch self { case .s, .sw, .se: return true; default: return false }
    }
    var resizesN: Bool {
        switch self { case .n, .nw, .ne: return true; default: return false }
    }
}

// MARK: Shared paths

enum CanvasPaths {
    static let supportDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Grand Central Terminal")
    static let sockPath = supportDir + "/daemon.sock"
    static let daemonPath = supportDir + "/bin/gctd"
}
