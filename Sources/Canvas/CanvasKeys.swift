// Every key binding, one engine. The config's [keybinds] and any script's
// gct.bind feed the same KeyEngine; keyDown asks it first.
//
//   config.toml [keybinds] ──┐
//   script keymap (daemon) ──┼─► KeyEngine ─► pass      ─► the terminal
//   gctd press / gct.press ──┘                consumed  ─► eaten (prefix, mode)
//                                             fire      ─► built-in action, or
//                                                          state.key ─► the script
//
// A key bound to a script's function waits for the script: it returns true to
// keep the key, anything else lets it through to the terminal. The canvas holds
// the key (and queues the ones typed after it) until the answer, or until the
// deadline, when the key stays eaten. Named actions need no answer.
//
//   keyDown ─► engine ─► fire fn ─► hold key ─► state.key ─► script runs fn
//                                      ▲                          │
//                                      └──── .reply(handled) ◄────┘
//                                   handled: eaten · not: to the terminal

import AppKit
import Common

private let hudMargin: CGFloat = 28
private let hudPadding = NSSize(width: 16, height: 8)
private let hudRadius: CGFloat = 8
private let hudAlpha: CGFloat = 0.82
// How long a held key waits for its script. A busy script, or a far host, is
// slower than a keystroke should be; past this the key stays eaten.
private let keyReplyDeadline: TimeInterval = 0.25

// What a key event is called in a binding. Virtual keycodes, US layout.
private let namedKeyCodes: [UInt16: String] = [
    49: "space", 48: "tab", 36: "enter", 76: "enter", 53: "escape", 51: "delete",
    123: "left", 124: "right", 125: "down", 126: "up",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
    98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
]

// The key without shift, for the symbols shift turns into something else:
// shift+5 is a "5" key, not the "%" it types.
private let unshiftedCodes: [UInt16: String] = [
    18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
]

extension KeyStroke {
    init?(event: NSEvent) {
        guard let key = Self.keyName(of: event) else { return nil }

        var mods = Mods()
        let flags = event.modifierFlags
        if flags.contains(.command) { mods.insert(.cmd) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.shift) { mods.insert(.shift) }

        self.init(mods: mods, key: key)
    }

    private static func keyName(of event: NSEvent) -> String? {
        if let named = namedKeyCodes[event.keyCode] { return named }

        if event.modifierFlags.contains(.shift), let base = unshiftedCodes[event.keyCode] { return base }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return nil }

        return chars
    }
}

extension CanvasView {
    // MARK: Config

    // The [keybinds] table, as the engine's oldest source (scripts override it).
    func loadConfigKeys() {
        var entries = [KeymapWire.Entry]()
        let all = GCTAction.allCases

        // Earlier actions win a tie on the same key, as they always did.
        for (i, action) in all.enumerated() {
            guard let seq = GCTConfig.current.keybinds[action] else { continue }

            entries.append(.init(serial: all.count - i, keys: seq.description, action: action.rawValue))
        }

        keyEngine.replace(KeymapWire(token: KeyEngine.configSource, entries: entries))
        showKeyStatus()
    }

    // MARK: Keys

    // True when the engine took the key: a binding ran, or it was part of one.
    func routeKey(_ event: NSEvent) -> Bool {
        // A key is waiting on a script: this one waits behind it, in order.
        if keyHold.isHolding {
            keyHold.queue.append(event)
            return true
        }

        guard let stroke = KeyStroke(event: event) else { return false }

        return route(stroke, from: event)
    }

    // `event` is nil for keys a script typed with press: nothing to hand on.
    private func route(_ stroke: KeyStroke, from event: NSEvent?) -> Bool {
        let outcome = keyEngine.feed(stroke)
        showKeyStatus()
        watchSequence()

        switch outcome {
        case .pass:
            return false
        case .consumed:
            return true
        case .fire(let f):
            run(f, from: event)
            return true
        }
    }

    private func run(_ f: KeyFire, from event: NSEvent?) {
        switch f.target {
        case .action(let name, let args):
            guard GCTAction(rawValue: name) == nil else {
                runCanvasCommand(CanvasCommand(verb: .action, action: name))
                return
            }

            var what: [String: Any] = ["action": name]
            if let args { what["args"] = args }

            tell(f, what)
        case .function(let id):
            // A typed key can be handed on, so the script gets to decide.
            let req = event.map { _ in UUID().uuidString }
            var what: [String: Any] = ["fn": id]
            if let req { what["req"] = req }

            guard tell(f, what), let req, let event else { return }

            hold(event, req: req)
        default:
            break
        }
    }

    // A script's binding was hit: say so on the link the script's daemon is
    // on. The script finds its own by token. False: nobody to tell.
    private func tell(_ f: KeyFire, _ what: [String: Any]) -> Bool {
        guard let owner = keyOwners[f.source], let conn = hub.conn(forOwner: owner) else {
            NSLog("[gct] key \(f.key) is bound by a script that is gone; ignored")
            return false
        }

        var fields = what
        fields["token"] = f.source
        fields["key"] = f.key.description
        fields["prefix"] = f.prefix.map(\.description)
        if let mode = f.mode { fields["mode"] = mode }

        // The focused pane, by the id that daemon knows it by.
        if let id = focusedID, hub.owner(of: id) == owner, let theirs = hub.daemonID(of: id) {
            fields["pane_id"] = theirs.description
        }

        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return false }

        conn.reportEvent(PaneEvent(id: nil, name: PaneEventName.keyFired, payload: String(decoding: data, as: UTF8.self)))
        return true
    }

    // MARK: Held keys

    private func hold(_ event: NSEvent, req: String) {
        keyHold.event = event
        keyHold.req = req
        keyHold.timer = Timer.scheduledTimer(withTimeInterval: keyReplyDeadline, repeats: false) { [weak self] _ in
            NSLog("[gct] a script didn't answer a key in time; the key stays eaten")
            self?.settle(req: req, handled: true)
        }
    }

    // The script answered (or the deadline did): the key goes on or stays
    // eaten, then whatever was typed meanwhile runs, in order.
    private func settle(req: String, handled: Bool) {
        // A late answer, after the deadline, finds nothing held.
        guard keyHold.req == req, let event = keyHold.event else { return }

        keyHold.timer?.invalidate()
        keyHold.timer = nil
        keyHold.event = nil
        keyHold.req = nil

        if !handled { passKey(event) }

        replayQueued()
    }

    private func replayQueued() {
        var rest = keyHold.queue
        keyHold.queue = []

        while !rest.isEmpty {
            let event = rest.removeFirst()
            if !routeKey(event) { passKey(event) }

            // That key started a hold of its own: the rest wait behind it.
            if keyHold.isHolding {
                keyHold.queue = rest
                return
            }
        }
    }

    // MARK: Sequence timeout

    // A half-typed sequence is dropped after sequence-timeout, like Escape.
    private func watchSequence() {
        keyHold.sequenceTimer?.invalidate()
        keyHold.sequenceTimer = nil

        let seconds = GCTConfig.current.sequenceTimeout
        guard keyEngine.isPending, seconds > 0 else { return }

        keyHold.sequenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.keyEngine.cancelPending()
            self?.showKeyStatus()
        }
    }

    // MARK: Commands from scripts

    // A script's whole keymap, a key sequence typed for it, or its answer to a key.
    func scriptedKeys(_ cmd: CanvasCommand, owner: String) {
        if cmd.verb == .press {
            press(cmd.keys ?? "")
            return
        }
        if cmd.verb == .reply {
            if let r = cmd.reply { settle(req: r.req, handled: r.handled) }
            return
        }

        guard let wire = cmd.keymap else { return }

        if wire.isEmpty {
            keyEngine.remove(source: wire.token)
            keyOwners[wire.token] = nil
        } else {
            keyOwners[wire.token] = owner
            keyEngine.replace(wire)
        }

        showKeyStatus()
    }

    // As if typed: "ctrl+b>c" is two key presses. Unbound keys just fall away.
    private func press(_ spec: String) {
        guard let seq = KeySequence(spec) else {
            NSLog("[gct] press: bad key \(spec)")
            return
        }

        for stroke in seq.strokes {
            _ = route(stroke, from: nil)
        }
    }

    // A daemon went away: so did the bindings its scripts put here.
    func dropKeys(owner: String) {
        for (token, from) in keyOwners where from == owner {
            keyEngine.remove(source: token)
            keyOwners[token] = nil
        }

        showKeyStatus()
    }

    // Tell the owner's scripts a canvas is here, so they send their keymaps.
    func announceCanvas(owner: String) {
        hub.conn(forOwner: owner)?.reportEvent(PaneEvent(id: nil, name: PaneEventName.canvasUp))
    }

    // MARK: Readout

    private func showKeyStatus() {
        guard let text = keyEngine.status else {
            keyHUD?.hide()
            return
        }

        let hud = keyHUD ?? KeyHUD(host: self)
        keyHUD = hud
        hud.show(text, in: self)
    }
}

// The key a script is deciding about, the keys typed behind it, and the timer
// that gives up on a half-typed sequence.
final class KeyHold {
    var event: NSEvent?
    var req: String?
    var timer: Timer?
    var queue = [NSEvent]()
    var sequenceTimer: Timer?

    var isHolding: Bool { req != nil }
}

// Bottom-center pill: the modes in force and the keys typed so far, so an
// exclusive mode or a half-typed sequence is never a mystery.
final class KeyHUD {
    private let field = NSTextField(labelWithString: "")

    init(host: NSView) {
        field.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        field.textColor = .white
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.black.withAlphaComponent(hudAlpha).cgColor
        field.layer?.cornerRadius = hudRadius
        field.isHidden = true
        field.autoresizingMask = host.isFlipped ? [.minXMargin, .maxXMargin, .minYMargin] : [.minXMargin, .maxXMargin, .maxYMargin]
        host.addSubview(field)
    }

    func show(_ text: String, in host: NSView) {
        field.stringValue = text
        field.sizeToFit()

        var f = field.frame
        f.size.width += hudPadding.width * 2
        f.size.height += hudPadding.height
        f.origin.x = (host.bounds.width - f.width) / 2
        f.origin.y = host.isFlipped ? host.bounds.height - f.height - hudMargin : hudMargin
        field.frame = f
        field.isHidden = false

        // Over the panes added since.
        host.addSubview(field, positioned: .above, relativeTo: nil)
    }

    func hide() {
        field.isHidden = true
    }
}
