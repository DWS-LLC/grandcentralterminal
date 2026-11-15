// For tests that need the doom hotkey: a key press into the system's event
// stream (post-key.swift aims at one process, which Carbon global hotkeys
// never see), and whether a process has a window on screen.
//   swiftc -O scripts/hotkey.swift -o /tmp/hotkey
//   /tmp/hotkey press <virtual keycode> [ctrl] [alt] [shift] [cmd]
//   /tmp/hotkey visible <pid>          prints 1 when it has a big window on screen, else 0
//   /tmp/hotkey bounds <pid>           x y w h of that window, in screen points
//   /tmp/hotkey click <x> <y>          a left click there, in screen points
import CoreGraphics
import Foundation

private let minWidth = 400.0
private let minHeight = 300.0

private func press(_ args: [String]) -> Never {
    guard let first = args.first, let code = UInt16(first) else { exit(2) }

    var flags = CGEventFlags()
    for m in args.dropFirst() {
        switch m {
        case "ctrl": flags.insert(.maskControl)
        case "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "cmd": flags.insert(.maskCommand)
        default: break
        }
    }

    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { exit(3) }

        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    exit(0)
}

// The process's big window on screen, if it has one.
private func bigWindow(_ pid: Int32) -> [String: Double]? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { w -> [String: Double]? in
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }

        return (b["Width"] ?? 0) >= minWidth && (b["Height"] ?? 0) >= minHeight ? b : nil
    }.first
}

private func visible(_ args: [String]) -> Never {
    guard let first = args.first, let pid = Int32(first) else { exit(2) }

    print(bigWindow(pid) == nil ? 0 : 1)
    exit(0)
}

private func bounds(_ args: [String]) -> Never {
    guard let first = args.first, let pid = Int32(first), let b = bigWindow(pid) else { exit(2) }

    print("\(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0))")
    exit(0)
}

private func click(_ args: [String]) -> Never {
    guard args.count == 2, let x = Double(args[0]), let y = Double(args[1]) else { exit(2) }

    let at = CGPoint(x: x, y: y)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                              mouseCursorPosition: at, mouseButton: .left) else { exit(3) }

        e.post(tap: .cghidEventTap)
        usleep(40_000)
    }
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst(2))
switch CommandLine.arguments.dropFirst().first {
case "press": press(args)
case "visible": visible(args)
case "bounds": bounds(args)
case "click": click(args)
default: exit(2)
}
