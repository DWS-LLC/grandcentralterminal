// Reach a remote gctd through an ssh jump host.
//
//   canvas <--socketpair--> ssh -W host:port proxy ---> host:port (gctd)
//
// ssh's stdin/stdout are one end of a socketpair, so the result is a plain
// socket fd and the framed Conn doesn't know the difference. Closing the
// fd makes ssh see EOF and exit; ssh dying gives the reader an EOF.

import Foundation
import Common

private let sshPath = "/usr/bin/ssh"
private let sshConnectTimeoutSecs = 5

/// Connected fd tunneled through `proxy`, or -1 if ssh couldn't launch.
/// Auth failures surface later as EOF (BatchMode: never prompts).
func connectSSHProxy(proxy: String, host: String, port: UInt16) -> Int32 {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, sockStream, 0, &pair) == 0 else { return -1 }

    let child = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: sshPath)
    p.arguments = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=\(sshConnectTimeoutSecs)",
        "-o", "ServerAliveInterval=15",
        "-W", "\(host):\(port)",
        proxy,
    ]
    p.standardInput = child
    p.standardOutput = child
    p.standardError = FileHandle.nullDevice

    do {
        try p.run()
    } catch {
        _ = closeSocket(pair[0])
        _ = closeSocket(pair[1])
        return -1
    }

    // Parent keeps only its end; the child owns the other.
    _ = closeSocket(pair[1])
    return pair[0]
}
