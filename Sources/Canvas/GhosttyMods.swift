// NSEvent modifier flags -> ghostty mods enum (mirrors Ghostty's macOS app).

import AppKit
import CGhostty

func GhosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    // Side info we don't distinguish, but keep the right-side bits if the
    // raw flags carry them.
    let raw = flags.rawValue
    if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(mods)
}

// NSEvent scroll phases -> ghostty's packed scroll-mods int: bit 0 =
// precision, bits 1-3 = momentum (matches src/input/mouse.zig
// ScrollMods/Momentum and Ghostty.Input.ScrollMods).
func GhosttyScrollMods(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
    var v: Int32 = 0
    if event.hasPreciseScrollingDeltas { v |= 0b0000_0001 }
    let m: Int32
    switch event.momentumPhase {
    case .began: m = 1
    case .stationary: m = 2
    case .changed: m = 3
    case .ended: m = 4
    case .cancelled: m = 5
    case .mayBegin: m = 6
    default: m = 0
    }
    v |= m << 1
    return v
}
