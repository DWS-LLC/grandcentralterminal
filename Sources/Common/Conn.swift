// Framed connection over a socket fd (unix or TCP), used by both sides.
// One reader thread per connection; writes are serialized.
//
// Portable: no Darwin module — Glibc on Linux, Darwin on macOS.
// Linux has no SO_NOSIGPIPE, so writes use MSG_NOSIGNAL there;
// unix fds keep SO_NOSIGPIPE where available.

import Foundation

// Default TCP port for remote daemons (config/CLI override per host).
public let GCTDefaultPort: UInt16 = 7420
public struct Frame {
    public var tag: MsgTag
    public var paneID: PaneID?
    public var data: Data
    public var json: Data

    public func decode<T: Decodable>() -> T? {
        try? JSONDecoder().decode(T.self, from: json)
    }
}

public final class Conn: @unchecked Sendable {
    public let fd: Int32
    private let writeLock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
#if os(macOS)
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
#endif
    }

    deinit {
        close()
    }

    public func close() {
        if !closed {
            closed = true
            FileHandle.standardError.write(Data("[conn] close fd=\(fd)\n".utf8))
            _ = closeSocket(fd)
        }
    }

    // Reader loop; calls handler synchronously until EOF/error.
    public func readLoop(_ handler: @escaping (Frame) -> Void) {
        while let frame = readFrame() {
            handler(frame)
        }
    }

    public func readFrame() -> Frame? {
        guard let hdr = readExact(4) else { return nil }
        let len = hdr.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        guard len >= 1, len <= 32 << 20 else { return nil }
        guard let payload = readExact(Int(len)) else { return nil }
        guard let tag = MsgTag(rawValue: payload[0]) else { return nil }

        if tag == .inputPane || tag == .outputPane {
            guard payload.count >= 17 else { return nil }
            // Portable UUID load: uuid_t isn't constructible under the
            // static SDK's C import, so go through the 16 raw bytes.
            let uuidBytes = (0..<16).map { payload[1 + $0] }
            let u = UUID(uuid: (
                uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
            ))
            let id = PaneID(u)
            let data = payload.subdata(in: 17..<payload.count)
            return Frame(tag: tag, paneID: id, data: data, json: Data())
        }
        return Frame(tag: tag, paneID: nil, data: Data(),
                     json: payload.subdata(in: 1..<payload.count))
    }

    private func readExact(_ n: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress!.advanced(by: got), n - got)
            }
            if r < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if r == 0 { return nil }
            got += r
        }
        return Data(buf[0..<n])
    }

    @discardableResult
    public func send(tag: MsgTag, json: some Codable & Sendable) -> Bool {
        guard var payload = try? JSONEncoder().encode(json) else { return false }
        payload.insert(tag.rawValue, at: 0)
        return writeFrame(payload)
    }

    @discardableResult
    public func sendData(tag: MsgTag, paneID: PaneID, data: Data) -> Bool {
        var payload = Data(capacity: data.count + 17)
        payload.append(tag.rawValue)
        withUnsafeBytes(of: paneID.uuid.uuid) { payload.append(contentsOf: $0) }
        payload.append(data)
        return writeFrame(payload)
    }

    // Blocking write with a short timeout: a wedged peer stalls the caller
    // briefly, then fails so the server can mark it and move on — instead
    // of wedging every pane reader on a full socket buffer forever.
    private func writeFrame(_ payload: Data) -> Bool {
        if closed { return false }
        writeLock.lock(); defer { writeLock.unlock() }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)  // 200ms per frame
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        var hdr = UInt32(payload.count).bigEndian
        var out = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: &hdr) { out.append(contentsOf: $0) }
        out.append(payload)
        let result = out.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
#if os(Linux)
                // Musl (static SDK) takes Int32 flags directly; Glibc's
                // MSG_NOSIGNAL is plain Int, hence the cast. SwiftGlibc
                // re-exports musl's send — bare send would hit
                // Conn.send(tag:) instead.
                let n = SwiftGlibc.send(fd, raw.baseAddress! + off,
                                        raw.count - off, Int32(MSG_NOSIGNAL))
#else
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
#endif
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                off += n
            }
            return true
        }
        if !result {
            FileHandle.standardError.write(Data("[conn] write fd=\(fd) errno=\(errno)\n".utf8))
        }
        return result
    }
}

public func connectUnixSocket(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, sockStream, 0)
    guard fd >= 0 else { return -1 }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr) { p in
        let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
        let off = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        let dst = raw.advanced(by: off)
        let bytes = Array(path.utf8CString.prefix(104))
        for (i, b) in bytes.enumerated() { dst[i] = b }
    }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if r != 0 {
        _ = closeSocket(fd)
        return -1
    }
    return fd
}

public func connectTCP(host: String, port: UInt16) -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = sockStream
    var res: UnsafeMutablePointer<addrinfo>?
    let portStr = String(port)
    let rc = host.withCString { h in
        portStr.withCString { p in
            getaddrinfo(h, p, &hints, &res)
        }
    }
    guard rc == 0, let list = res else { return -1 }
    defer { freeaddrinfo(list) }
    var fd: Int32 = -1
    var ai: UnsafeMutablePointer<addrinfo>? = list
    while let cur = ai {
        let a = cur.pointee
        let s = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
        if s >= 0 {
            // Short connect timeout so a dead host fails fast, not in 75s.
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))
            if connect(s, a.ai_addr, a.ai_addrlen) == 0 {
                // Connected: back to blocking (framing does its own short
                // write timeouts per frame).
                tv = timeval(tv_sec: 0, tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv,
                           socklen_t(MemoryLayout<timeval>.size))
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv,
                           socklen_t(MemoryLayout<timeval>.size))
                fd = s
                break
            }
            _ = closeSocket(s)
        }
        ai = a.ai_next
    }
    return fd
}

public func listenTCP(port: UInt16) -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = sockStream
    hints.ai_flags = AI_PASSIVE
    var res: UnsafeMutablePointer<addrinfo>?
    let portStr = String(port)
    guard portStr.withCString({ getaddrinfo(nil, $0, &hints, &res) }) == 0,
          let list = res else { return -1 }
    defer { freeaddrinfo(list) }
    var listenFD: Int32 = -1
    var ai: UnsafeMutablePointer<addrinfo>? = list
    while let cur = ai {
        let a = cur.pointee
        let s = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
        if s >= 0 {
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one,
                       socklen_t(MemoryLayout<Int32>.size))
            // Dual-stack: accept v4 on the v6 socket when the OS allows.
            var v6only: Int32 = 0
#if os(Linux)
#if canImport(Musl)
            // Musl imports these as plain Int32 — direct call.
            setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &v6only,
                       socklen_t(MemoryLayout<Int32>.size))
#else
            // IPPROTO_IPV6 is Int, IPV6_V6ONLY is Int32 on Glibc.
            setsockopt(s, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6only,
                       socklen_t(MemoryLayout<Int32>.size))
#endif
#else
            setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &v6only,
                       socklen_t(MemoryLayout<Int32>.size))
#endif
            if bind(s, a.ai_addr, a.ai_addrlen) == 0, listen(s, 8) == 0 {
                listenFD = s
                break
            }
            _ = closeSocket(s)
        }
        ai = a.ai_next
    }
    return listenFD
}
// SOCK_STREAM is Int32 on Darwin, a typed enum on Glibc, plain
// Int32 on Musl — one shim each.
#if os(Linux)
#if canImport(Musl)
public let sockStream: Int32 = SOCK_STREAM
#else
public let sockStream: Int32 = Int32(SOCK_STREAM.rawValue)
#endif
#else
public let sockStream: Int32 = SOCK_STREAM
#endif

// Portable close: Darwin.close vs Glibc.close without importing either.
public func closeSocket(_ fd: Int32) -> Int32 {
    close(fd)
}
