// Picture-in-picture awareness for camera fits.
//
// The system PiP window floats above every app, so a fit that targets the
// whole viewport lands panes underneath it. Instead the fit targets the
// biggest strip of the viewport the PiP leaves free:
//
//   ┌───────┬──────────────┐       ┌───────┬──────────────┐
//   │  PiP  │              │       │  PiP  │              │
//   ├───────┘   pane fit   │  ──►  ├───────┘  pane fits   │
//   │   to the whole view  │       │      right of it     │
//   └──────────────────────┘       └──────────────────────┘
//
// Of the four strips (left, right, above, below the PiP) the winner is the
// one the content fits in the largest. Lower-level window-list mechanics
// stay in here; the canvas only asks for a rect.

import AppKit

enum PictureInPicture {
    private static let pipName = "picture in picture"

    // The viewport (view coords, y-up) minus the strip the PiP window
    // covers; the viewport itself without a PiP or when `pip-aware` is
    // off. `content` is the screen-space size to be placed, which picks
    // the strip that fits it best.
    static func freeRect(in viewport: CGRect, for content: CGSize, view: NSView) -> CGRect {
        guard GCTConfig.current.pipAware,
              let pip = windowRect(in: view),
              let free = dodge(pip, in: viewport, for: content) else { return viewport }
        return free
    }

    // The PiP window in view coords (y-up); nil without one or when
    // `pip-aware` is off.
    static func rect(in view: NSView) -> CGRect? {
        guard GCTConfig.current.pipAware else { return nil }
        return windowRect(in: view)
    }

    // Best strip of `viewport` clear of `pip`; nil when the PiP doesn't
    // touch it or covers all of it.
    private static func dodge(_ pip: CGRect, in viewport: CGRect, for content: CGSize) -> CGRect? {
        let hit = viewport.intersection(pip)
        guard !hit.isNull, hit.width > 0, hit.height > 0 else { return nil }

        let strips = [
            CGRect(x: viewport.minX, y: viewport.minY,
                   width: hit.minX - viewport.minX, height: viewport.height),
            CGRect(x: hit.maxX, y: viewport.minY,
                   width: viewport.maxX - hit.maxX, height: viewport.height),
            CGRect(x: viewport.minX, y: viewport.minY,
                   width: viewport.width, height: hit.minY - viewport.minY),
            CGRect(x: viewport.minX, y: hit.maxY,
                   width: viewport.width, height: viewport.maxY - hit.maxY),
        ]
        return strips
            .filter { $0.width > 0 && $0.height > 0 }
            .max { fitScale($0, content) < fitScale($1, content) }
    }

    // Zoom at which `content` just fills `strip`.
    private static func fitScale(_ strip: CGRect, _ content: CGSize) -> CGFloat {
        min(strip.width / max(content.width, 1), strip.height / max(content.height, 1))
    }

    // First PiP window on screen, in `view` coords. The window list needs
    // no screen-recording permission for owner + bounds; the title only
    // shows with it, so the owner ("Picture in Picture" for Safari/system
    // video PiP) is the primary match and the title the fallback
    // (Chrome, Firefox).
    private static func windowRect(in view: NSView) -> CGRect? {
        guard let window = view.window, let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                  as? [[String: Any]] else { return nil }

        for info in list {
            guard isPiP(info),
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: dict),
                  !quartz.isEmpty else { continue }

            // Quartz is y-down from the primary's top; Cocoa is y-up from
            // its bottom.
            let screen = CGRect(x: quartz.minX,
                                y: primary.frame.height - quartz.maxY,
                                width: quartz.width, height: quartz.height)
            return view.convert(window.convertFromScreen(screen), from: nil)
        }
        return nil
    }

    private static func isPiP(_ info: [String: Any]) -> Bool {
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let title = info[kCGWindowName as String] as? String ?? ""
        return [owner, title].contains {
            $0.lowercased().replacingOccurrences(of: "-", with: " ") == pipName
        }
    }
}
