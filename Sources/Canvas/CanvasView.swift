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

    // IME composition state (NSTextInputClient below). markedText mirrors
    // the input context's preedit; keyTextAccumulator collects text the IME
    // commits while we're inside keyDown (nil when we're not in keyDown).
    private var markedText = NSMutableAttributedString()
    // Surface the preedit is drawn on — tracks the pane across focus moves
    // so preedit cleanup always targets the surface that shows it.
    private var markedHost: SurfaceHost?
    private var keyTextAccumulator: [String]?
    // Korean IMEs: a lone high surrogate delivered by insertText, waiting
    // for its trail half.
    private var pendingLeadSurrogate: LeadSurrogate?

    private var focusedHost: SurfaceHost? { focusedID.flatMap { panes[$0]?.host } }

    // Abandon any in-progress composition: clear marked text and the
    // preedit the surface is rendering. Focus is leaving the pane.
    private func dropComposition() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        if let host = markedHost, let surface = host.surfaceIfOpen() {
            ghostty_surface_preedit(surface, nil, 0)
        }
        markedHost = nil
    }

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

    // Recompute the theme from config + ghostty and apply it everywhere.
    func applyTheme() {
        GCTTheme.refresh(ghosttyBackground: ghosttyApp?.background)
        window?.backgroundColor = GCTTheme.current.canvasBackground
        for pane in panes.values { pane.applyChrome() }
    }

    // appearance = "system": light/dark follows macOS, so re-resolve on change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
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
            dropComposition()
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
        // App shortcuts first, from the config's keybinds.
        if let action = GCTAction.allCases.first(where: {
            GCTConfig.current.keybinds[$0]?.matches(event) ?? false
        }) {
            perform(action)
            return
        }

        guard let host = focusedHost else {
            super.keyDown(with: event)
            return
        }

        handleKey(event, to: host)
    }

    private func perform(_ action: GCTAction) {
        switch action {
        case .newPane: newPane()
        case .closePane: if let id = focusedID { closePane(id) }
        case .renamePane: if let id = focusedID { renamePane(id) }
        case .switcher: toggleSwitcher()
        case .fitAll: fitAll()
        case .copy: copyFromFocused()
        case .paste: pasteIntoFocused()
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
        _ = keyAction(action, event: event, translationEvent: nil, to: host)
    }

    // Route a key event through the text input system first (so dead keys
    // and IMEs see it), then encode both the raw key and any committed text
    // to ghostty. Mirrors Ghostty's macOS SurfaceView.keyDown.
    private func handleKey(_ event: NSEvent, to host: SurfaceHost) {
        guard let surface = host.surfaceIfOpen() else { return }

        // Translate the mods to honor configs such as option-as-alt.
        let translated = ghostty_surface_key_translation_mods(
            surface, GhosttyMods(event.modifierFlags)).rawValue
        var translationMods = event.modifierFlags
        for (flag, mask) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT.rawValue),
                             (.control, GHOSTTY_MODS_CTRL.rawValue),
                             (.option, GHOSTTY_MODS_ALT.rawValue),
                             (.command, GHOSTTY_MODS_SUPER.rawValue)] {
            if translated & mask != 0 {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // IMPORTANT: reuse the original event when the mods match. AppKit
        // keys off event object equality for Korean input to work.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action: ghostty_input_action_e =
            event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // interpretKeyEvents feeds the event to the active input method,
        // which calls back into insertText/setMarkedText.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0

        // If the layout changes while handling this event, an input method
        // grabbed it and we do nothing.
        let keyboardIdBefore = markedTextBefore ? nil : KeyboardLayout.id

        interpretKeyEvents([translationEvent])

        if !markedTextBefore, keyboardIdBefore != KeyboardLayout.id { return }

        // Push the preedit the IME left behind to the surface, which
        // renders the in-progress composition inline at the cursor.
        syncPreedit(clearIfNeeded: markedTextBefore)

        // Composing if preedit exists now or existed before: the key press
        // itself belongs to the IME. Example: Japanese composing, then
        // backspace or ctrl+h should only cancel the composition, not
        // delete previously committed input.
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            // The IME committed (part of) the preedit while handling this
            // key. Send the committed text on its own, then replay only
            // keys that still affect the terminal after committing.
            for text in list {
                if Self.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }
                _ = committedTextAction(action, text: text, to: host)
            }
            if Self.shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(action, event: event,
                              translationEvent: translationEvent,
                              composing: false, to: host)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            // The IME committed text for this key; encode each chunk with
            // the key event so programs treat it as typed input.
            for text in list {
                if Self.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }
                _ = keyAction(action, event: event,
                              translationEvent: translationEvent,
                              text: text, to: host)
            }
        } else {
            // Raw control characters arriving during composition belong to
            // the IME, not the terminal.
            if Self.shouldSuppressComposingControlInput(event.characters,
                                                        composing: composing) {
                return
            }

            // Normal key event: ghostty encodes from the keycode.
            _ = keyAction(action, event: event,
                          translationEvent: translationEvent,
                          text: Self.ghosttyCharacters(translationEvent),
                          composing: composing, to: host)
        }
    }

    // Encode a key event (with optional text) to the surface.
    private func keyAction(_ action: ghostty_input_action_e,
                           event: NSEvent,
                           translationEvent: NSEvent?,
                           text: String? = nil,
                           composing: Bool = false,
                           to host: SurfaceHost) -> Bool {
        var ev = Self.ghosttyKeyEvent(event, action,
                                      translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text = text?.keyEventText {
            return text.withCString { ptr in
                ev.text = UnsafePointer(ptr)
                return host.key(ev)
            }
        }
        return host.key(ev)
    }

    // Committed IME text outside a key event (dictation, etc.): a
    // text-only key event with no key or mods.
    private func committedTextAction(_ action: ghostty_input_action_e,
                                     text: String, to host: SurfaceHost) -> Bool {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = 0
        ev.text = nil
        ev.composing = false
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.unshifted_codepoint = 0
        return text.withCString { ptr in
            ev.text = UnsafePointer(ptr)
            return host.key(ev)
        }
    }

    // NSEvent -> ghostty key event, mirrors Ghostty's own macOS conversion.
    private static func ghosttyKeyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                                        translationMods: NSEvent.ModifierFlags?)
        -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = GhosttyMods(event.modifierFlags)
        // control/command never contribute to text translation.
        ev.consumed_mods = GhosttyMods(
            (translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    // event.characters filtered for ghostty key events: control characters
    // are re-derived without control (ghostty encodes control keys itself,
    // from the key enum), and PUA function-key values are dropped.
    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers:
                    event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return chars
    }

    // True when `text` is a single C0 control character arriving while the
    // IME is composing; such input belongs to the IME, not the terminal.
    private static func shouldSuppressComposingControlInput(_ text: String?,
                                                            composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }

    // After an IME commits preedit while handling a key, replay only keys
    // that still affect the terminal (arrows). Plain left-arrow is excluded:
    // AppKit already leaves the caret in place after Korean IMEs commit.
    private static func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124, 125, 126: return true // right, down, up
        case 123: // left
            return !event.modifierFlags.isDisjoint(
                with: [.shift, .control, .option, .command])
        default: return false
        }
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

    // Push the current preedit (or clear it) to the focused surface so the
    // in-progress composition renders inline at the cursor.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let host = markedHost ?? focusedHost,
              let surface = host.surfaceIfOpen() else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract 1 for the null terminator.
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // Swallow unhandled input-context commands so interpretKeyEvents
    // doesn't fall through to a system NSBeep.
    override func doCommand(by selector: Selector) {}

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
        if markedHost === pane.host { dropComposition() }
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
        dropComposition()
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

// MARK: - NSTextInputClient
// Conformance is what makes the text input system route dead keys and IMEs
// through this view while it is first responder.

extension CanvasView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let host = focusedHost,
              let surface = host.surfaceIfOpen(),
              ghostty_surface_has_selection(surface) else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }

        if markedText.length > 0, markedHost == nil {
            markedHost = focusedHost
        }

        // Outside a keyDown (e.g. the keyboard layout changed mid-composition)
        // update the preedit immediately; inside keyDown the caller does it.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
        markedHost = nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // We must have an associated event.
        guard NSApp.currentEvent != nil else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as NSString:
            // Korean IMEs can deliver a surrogate pair as two separate
            // insertText calls; buffer the lead half until the trail lands.
            if let lead = LeadSurrogate(v) {
                pendingLeadSurrogate = lead
                return
            }
            if let trail = TrailSurrogate(v) {
                chars = pendingLeadSurrogate?.encode(trail: trail) ?? ""
                pendingLeadSurrogate = nil
            } else {
                chars = v as String
                pendingLeadSurrogate = nil
            }
        default:
            return
        }

        // insertText ends any in-progress composition.
        unmarkText()

        // Inside a keyDown we just accumulate; keyDown sends it.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Committed text outside a key event is still typed input, so it
        // must go through as a key event, never as a paste.
        if !chars.isEmpty, let host = focusedHost {
            _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chars, to: host)
        }
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window,
              let id = focusedID, let pane = panes[id], let host = pane.host,
              let pt = host.imePoint() else {
            return .zero
        }

        var x = pt.x
        let y = pt.y
        var w = pt.width
        let h = pt.height

        // Dictation wants a point, not a rect.
        if range.length == 0, w > 0 {
            w = 0
            x += pt.width * Double(range.location)
        }

        // ghostty coordinates are top-left origin; AppKit is bottom-left.
        let hostHeight = pane.surfaceHostView.bounds.height
        let viewRect = NSRect(x: x, y: hostHeight - y, width: w, height: max(h, 0))

        // View geometry ignores the camera sublayerTransform, so convert
        // host -> world with AppKit, then apply the camera by hand.
        let worldRect = pane.surfaceHostView.convert(viewRect, to: worldView)
        let canvasRect = NSRect(
            origin: camera.worldToScreen(worldRect.origin),
            size: NSSize(width: worldRect.width * camera.scale,
                         height: worldRect.height * camera.scale))

        let winRect = convert(canvasRect, to: nil)
        return window.convertToScreen(winRect)
    }
}
