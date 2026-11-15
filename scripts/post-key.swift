// One real key press, aimed at one process, for tests that need the keyboard path.
//   swiftc -O scripts/post-key.swift -o /tmp/post-key
//   /tmp/post-key <pid> <virtual keycode> [ctrl] [alt] [shift] [cmd]
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]), let code = UInt16(args[2]) else { exit(2) }

var flags = CGEventFlags()
for m in args.dropFirst(3) {
    switch m {
    case "ctrl": flags.insert(.maskControl)
    case "alt": flags.insert(.maskAlternate)
    case "shift": flags.insert(.maskShift)
    case "cmd": flags.insert(.maskCommand)
    default: break
    }
}

for down in [true, false] {
    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { exit(3) }

    e.flags = flags
    e.postToPid(pid)
    usleep(30_000)
}
