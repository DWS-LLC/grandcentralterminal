// canvasd — headless daemon owning pane PTYs.

import Foundation
import Common

func log(_ s: String) {
    FileHandle.standardError.write(Data("[canvasd] \(s)\n".utf8))
}

let supportDir = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Application Support/tmuxInfiniteCanvas")
let sockPath = supportDir + "/daemon.sock"
let statePath = supportDir + "/state.json"
let pidPath = supportDir + "/daemon.pid"

let args = CommandLine.arguments.dropFirst()

if args.contains("status") {
    let fd = connectUnixSocket(sockPath)
    guard fd >= 0 else {
        print("not running")
        exit(1)
    }
    let c = Conn(fd: fd)
    _ = c.send(tag: .listPanes, json: Hello(version: ProtoVersion))
    if let frame = c.readFrame(),
       let w: Welcome = frame.decode() {
        if w.panes.isEmpty { print("no panes") }
        for p in w.panes {
            let name = p.name ?? "Terminal"
            print("\(p.id)  \(name)  \(p.cwd)  exited=\(p.exited)")
        }
    }
    exit(0)
}

if args.contains("stop") {
    let fd = connectUnixSocket(sockPath)
    guard fd >= 0 else {
        print("not running")
        exit(1)
    }
    _ = Conn(fd: fd).send(tag: .killDaemon, json: Hello(version: ProtoVersion))
    exit(0)
}

// Single instance via pid file.
if let data = FileManager.default.contents(atPath: pidPath),
   let old = Int(String(decoding: data, as: UTF8.self)
       .trimmingCharacters(in: .whitespacesAndNewlines)),
   old != ProcessInfo.processInfo.processIdentifier,
   kill(pid_t(old), 0) == 0 {
    log("another daemon (pid \(old)) already running")
    exit(0)
}
try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
    .write(to: URL(fileURLWithPath: pidPath), options: .atomic)

let state = StateStore(path: statePath)
let server = Server(state: state, sockPath: sockPath)

signal(SIGPIPE, SIG_IGN)
// On TERM/INT: children get EIO on their pty master once we die and exit.
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

server.run()
