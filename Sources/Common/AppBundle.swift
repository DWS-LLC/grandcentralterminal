// The app a program ships in, found from the path it runs from.
//
//   /Applications/Docker.app/Contents/Resources/bin/docker
//   └──────────┬──────────┘
//              the bundle whose icon the program wears
//
// Pure string math: no filesystem, no AppKit.

import Foundation

public enum AppBundle {
    private static let suffix = ".app"

    /// The outermost `.app` directory on `exe`'s path, or nil when it is not
    /// inside one. Outermost, so a helper app nested in another (Chrome's)
    /// shows the app you launched, not its icon-less helper.
    public static func root(of exe: String) -> String? {
        guard exe.hasPrefix("/") else {
            return nil
        }

        var path = ""
        for part in exe.split(separator: "/") {
            path += "/" + part
            if part.hasSuffix(suffix), part.count > suffix.count {
                return path
            }
        }
        return nil
    }
}
