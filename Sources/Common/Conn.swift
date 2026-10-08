// Framed connection over a unix socket fd, used by both sides.
// One reader thread per connection; writes are serialized.

import Foundation

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
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    public func close() {
        if !closed {
            closed = true
            FileHandle.standardError.write(Data("[conn] close fd=\(fd)\n".utf8))
            _ = Darwin.close(fd)
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
            var u = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            payload.withUnsafeBytes { raw in
                withUnsafeMutableBytes(of: &u) { dst in
                    // payload[0] is the tag; uuid starts at byte 1.
                    memcpy(dst.baseAddress!, raw.baseAddress! + 1, 16)
                }
            }
            let id = PaneID(UUID(uuid: u))
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
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
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
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
        _ = Darwin.close(fd)
        return -1
    }
    return fd
}
