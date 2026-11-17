// The icon a pane's program wears in its titlebar, found off the main thread
// and cached.
//
//   exe ─► the .app it lives in ─► that app's icon      docker, code
//    │ none
//    ▼
//   program name ─► Homebrew cask of that name ─► its .app's icon   ghostty
//    │ none
//    ▼
//   nil: the titlebar draws >_
//
// Disk probing runs on a utility queue; the icon itself is made on main,
// where NSWorkspace is at home.

import AppKit
import Common

final class PaneIcons {
    static let shared = PaneIcons()

    // What a pane runs: the executable's path (local panes only, from the
    // daemon) and the command's name.
    struct Lookup: Hashable {
        var exe: String?
        var program: String?
    }

    private static let caskrooms = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    private static let appSuffix = ".app"
    // Source bitmap edge in pixels: sharp at 4x camera zoom on a retina bar.
    private static let bitmapEdge: CGFloat = 128

    private enum Entry {
        case miss
        case hit(CGImage)

        var image: CGImage? {
            guard case .hit(let image) = self else {
                return nil
            }
            return image
        }
    }

    private var entries = [Lookup: Entry]()
    private var byApp = [String: CGImage]()
    private let queue = DispatchQueue(label: "gct.paneicons", qos: .utility)

    private init() {}

    /// Calls `done` on main with the icon, or nil when the program has none.
    /// Instantly when the answer is already known.
    func fetch(_ look: Lookup, done: @escaping (CGImage?) -> Void) {
        if let known = entries[look] {
            done(known.image)
            return
        }

        queue.async {
            let app = Self.appPath(for: look)
            DispatchQueue.main.async {
                let image = app.flatMap { self.image(ofApp: $0) }
                self.entries[look] = image.map(Entry.hit) ?? .miss
                done(image)
            }
        }
    }

    private func image(ofApp path: String) -> CGImage? {
        if let known = byApp[path] {
            return known
        }

        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: Self.bitmapEdge, height: Self.bitmapEdge)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }

        byApp[path] = image
        return image
    }

    private static func appPath(for look: Lookup) -> String? {
        if let exe = look.exe, let app = AppBundle.root(of: exe) {
            return app
        }
        guard let program = look.program else {
            return nil
        }
        return caskApp(named: program.lowercased())
    }

    // <Caskroom>/<token>/<version>/Name.app, newest version first.
    private static func caskApp(named token: String) -> String? {
        // A command name is never a path: keep it inside the Caskroom.
        guard !token.isEmpty, !token.hasPrefix("."), !token.contains("/") else {
            return nil
        }

        let files = FileManager.default
        for room in caskrooms {
            let dir = room + "/" + token
            let versions = (try? files.contentsOfDirectory(atPath: dir)) ?? []
            for version in versions.filter({ !$0.hasPrefix(".") }).sorted(by: >) {
                let versionDir = dir + "/" + version
                let items = (try? files.contentsOfDirectory(atPath: versionDir)) ?? []
                if let app = items.first(where: { $0.hasSuffix(appSuffix) }) {
                    return versionDir + "/" + app
                }
            }
        }
        return nil
    }
}
