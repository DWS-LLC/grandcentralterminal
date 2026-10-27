// Clipboard embedder: libghostty's read/confirm/write callbacks over
// NSPasteboard. Serves OSC 52 and the Kitty clipboard protocol (OSC 5522:
// any MIME type, paste events, session grants).
//
//   libghostty core --read/confirm/write cb--> GhosttyClipboard --> NSPasteboard
//        ^                                           |
//        |                                           +--> NSAlert sheet (ask)
//        +---- complete/deny_clipboard_request <-----+
//
// Callbacks arrive on the main thread (the app mailbox pump).

import AppKit
import CGhostty
import UniformTypeIdentifiers

// One clipboard representation, copied out of borrowed C memory.
private struct Rep {
    let mime: String
    let data: Data
}

// How a read completion was authorized.
private enum Consent {
    case policy
    case granted
    case grantedForSession
}

private enum Verdict {
    case deny
    case allow
    case allowForSession
}

// What the program is asking for; picks the prompt wording.
private enum Ask {
    case paste
    case read
    case write

    init?(_ request: ghostty_clipboard_request_e) {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE: self = .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
             GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ: self = .read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
             GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE: self = .write
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .paste: return "Paste potentially unsafe text?"
        case .read: return "Allow this program to read the clipboard?"
        case .write: return "Allow this program to write the clipboard?"
        }
    }

    // The Kitty protocol's program-supplied name is never shown: it is
    // attacker-controlled text in a trusted prompt.
    var detail: String {
        switch self {
        case .paste: return "Pasting this text may run commands."
        case .read: return "The current clipboard contents:"
        case .write: return "The contents to be written:"
        }
    }
}

enum GhosttyClipboard {
    private static let previewBytes = 2048
    private static let previewImageMax = NSSize(width: 320, height: 240)
    private static let rememberTitle = "Remember for this session"

    // MARK: libghostty callbacks

    static func read(
        _ ud: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?,
        _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        _ count: Int,
        _ list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surface = openSurface(ud),
              location == GHOSTTY_CLIPBOARD_STANDARD else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        // Only the requested representations are read, so unrelated (maybe
        // huge) clipboard contents are never loaded.
        let board = NSPasteboard.general
        let reps = requested(mimes, count).compactMap { mime in
            board.data(forMime: mime).map { Rep(mime: mime, data: $0) }
        }

        // A paste event lists types and must not read any data.
        let available = list ? board.availableMimes() : []
        guard !reps.isEmpty || list else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        complete(surface, state, reps, available, .policy)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    // The core asks before serving a read, or before applying a write
    // that policy marks as "ask". The prompt is async: the request is
    // answered with exactly what the user saw, never re-read.
    static func confirm(
        _ ud: UnsafeMutableRawPointer?,
        _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        _ state: UnsafeMutableRawPointer?,
        _ request: ghostty_clipboard_request_e
    ) {
        guard let host = host(ud), let surface = host.surfaceIfOpen() else { return }
        guard let confirm, let ask = Ask(request) else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }

        let c = confirm.pointee
        let reps = reps(c.contents, c.contents_len)
        let available = mimeList(c.available, c.available_len)

        prompt(ask, reps, canRemember: c.can_remember) { [weak host] verdict in
            guard let surface = host?.surfaceIfOpen() else { return }

            switch verdict {
            case .deny:
                ghostty_surface_deny_clipboard_request(surface, state)
            case .allow:
                complete(surface, state, reps, available, .granted)
            case .allowForSession:
                complete(surface, state, reps, available, .grantedForSession)
            }
        }
    }

    static func write(
        _ ud: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
        _ count: Int,
        _ confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }

        let reps = reps(contents, count)
        guard !reps.isEmpty else { return }

        guard confirm else {
            store(reps)
            return
        }

        // Confirmed writes are text only (OSC 52); the prompt shows one entry.
        prompt(.write, reps, canRemember: false) { verdict in
            guard verdict != .deny else { return }
            store(reps)
        }
    }

    // MARK: Pasteboard

    // Every representation lands on the pasteboard in one declare, so
    // a reader sees them as one item (text + image + html).
    private static func store(_ reps: [Rep]) {
        let board = NSPasteboard.general
        let typed = reps.compactMap { rep in
            NSPasteboard.PasteboardType(mimeType: rep.mime).map { ($0, rep.data) }
        }
        guard !typed.isEmpty else { return }

        board.declareTypes(typed.map(\.0), owner: nil)
        for (type, data) in typed {
            board.setData(data, forType: type)
        }
    }

    // MARK: C marshalling

    private static func host(_ ud: UnsafeMutableRawPointer?) -> SurfaceHost? {
        guard let ud else { return nil }
        return Unmanaged<SurfaceHost>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func openSurface(_ ud: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        host(ud)?.surfaceIfOpen()
    }

    // Requested MIME types, de-duplicated, order kept.
    private static func requested(
        _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        _ count: Int
    ) -> [String] {
        var seen = Set<String>()
        return mimeList(mimes, count).filter { seen.insert($0).inserted }
    }

    private static func mimeList(
        _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        _ count: Int
    ) -> [String] {
        guard let mimes else { return [] }
        return (0..<count).compactMap { i in
            mimes[i].map { String(cString: $0) }
        }
    }

    private static func reps(
        _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
        _ count: Int
    ) -> [Rep] {
        guard let contents else { return [] }
        return (0..<count).compactMap { i in
            let c = contents[i]
            guard let mime = c.mime else { return nil }

            let data = c.data.map { Data(bytes: $0, count: c.len) } ?? Data()
            return Rep(mime: String(cString: mime), data: data)
        }
    }

    // Hand the core a copy in C memory; it only borrows for the call.
    private static func complete(
        _ surface: UnsafeMutableRawPointer,
        _ state: UnsafeMutableRawPointer?,
        _ reps: [Rep],
        _ available: [String],
        _ consent: Consent
    ) {
        var owned = [UnsafeMutableRawPointer]()
        defer { owned.forEach { free($0) } }

        func cString(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }

        let cReps = reps.map { rep -> ghostty_clipboard_content_s in
            let buf = malloc(max(rep.data.count, 1))!
            owned.append(buf)
            rep.data.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: rep.data.count)

            return ghostty_clipboard_content_s(
                mime: cString(rep.mime),
                data: UnsafePointer(buf.assumingMemoryBound(to: CChar.self)),
                len: rep.data.count)
        }
        let cAvailable = available.map { Optional(cString($0)) }

        cReps.withUnsafeBufferPointer { contents in
            cAvailable.withUnsafeBufferPointer { avail in
                var done = ghostty_clipboard_complete_s(
                    contents: contents.baseAddress,
                    contents_len: contents.count,
                    available: avail.baseAddress,
                    available_len: avail.count,
                    confirmed: consent != .policy,
                    remember: consent == .grantedForSession)
                ghostty_surface_complete_clipboard_request(surface, &done, state)
            }
        }
    }

    // MARK: Prompt

    private static func prompt(
        _ ask: Ask,
        _ reps: [Rep],
        canRemember: Bool,
        done: @escaping (Verdict) -> Void
    ) {
        // No window to hang a sheet on: deny rather than guess.
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else {
            done(.deny)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ask.title
        alert.informativeText = "\(ask.detail)\n\n\(preview(reps))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.accessoryView = previewImage(reps)

        if canRemember {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = rememberTitle
        }

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                done(.deny)
                return
            }
            done(alert.suppressionButton?.state == .on ? .allowForSession : .allow)
        }
    }

    // Text when there is some, else one "mime (N bytes)" line per entry.
    private static func preview(_ reps: [Rep]) -> String {
        guard let text = reps.first(where: { $0.mime == "text/plain" }) else {
            return reps.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")
        }

        let shown = String(decoding: text.data.prefix(previewBytes), as: UTF8.self)
        guard text.data.count > previewBytes else { return shown }
        return "\(shown)…\n(\(text.data.count) bytes)"
    }

    // Shows exactly what would be disclosed, scaled to fit.
    private static func previewImage(_ reps: [Rep]) -> NSView? {
        let image = reps.lazy
            .filter { $0.mime.hasPrefix("image/") }
            .compactMap { NSImage(data: $0.data) }
            .first
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }

        let fit = min(previewImageMax.width / image.size.width,
                      previewImageMax.height / image.size.height, 1)
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }
}

private extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        guard mimeType != "text/plain" else {
            self = .string
            return
        }
        guard let type = UTType(mimeType: mimeType) else {
            self.init(mimeType)
            return
        }
        self.init(type.identifier)
    }
}

private extension NSPasteboard {
    // The data for a MIME type, if the pasteboard can serve it. Copied
    // files are also served as a "text/uri-list" (RFC 2483), the type
    // X11/Wayland clipboards carry file copies under.
    func data(forMime mime: String) -> Data? {
        switch mime {
        case "text/plain":
            return string(forType: .string).map { Data($0.utf8) }
        case "text/uri-list":
            let urls = fileURLs
            guard !urls.isEmpty else { return nil }
            return Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)
        default:
            guard let type = PasteboardType(mimeType: mime) else { return nil }
            return data(forType: type)
        }
    }

    // MIME types the pasteboard declares. Only inspects declared types:
    // paste events are metadata-only, and lazy providers must not be asked.
    func availableMimes() -> [String] {
        var result = [String]()
        var seen = Set<String>()

        func add(_ mime: String) {
            guard seen.insert(mime).inserted else { return }
            result.append(mime)
        }

        let declared = types ?? []
        if declared.contains(.fileURL) {
            add("text/uri-list")
        }
        for type in declared {
            guard let mime = UTType(type.rawValue)?.preferredMIMEType else { continue }
            add(mime == "text/plain;charset=utf-8" ? "text/plain" : mime)
        }
        return result
    }

    private var fileURLs: [URL] {
        (pasteboardItems ?? []).compactMap { item in
            guard let plist = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
                  url.isFileURL else { return nil }
            return url
        }
    }
}
