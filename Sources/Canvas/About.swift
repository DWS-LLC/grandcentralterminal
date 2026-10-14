// The About panel: product blurb in the credits area, version + commit
// sha in the stock version line. The sha is stamped into Info.plist at
// bundle time (Makefile / scripts/build.sh); a bare `swift build` run
// has none and shows "dev".

import AppKit

enum GCTAbout {
    private static let shaKey = "GCTGitSHA"
    private static let shaFallback = "dev"

    private static let credits = """
        A different terminal.

        Engineered by DWS Engineering LLC. in the United States.
        “It’s your internet. Take it Back”
        2026
        """

    static func show() {
        let info = Bundle.main.infoDictionary
        let sha = info?[shaKey] as? String ?? shaFallback
        let version = info?["CFBundleShortVersionString"] as? String ?? "--"

        let text = NSMutableAttributedString(
            string: credits,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.labelColor])
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        text.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: text.length))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "GCT - Grand Central Terminal",
            .applicationVersion: "\(version) (\(sha))",
            .version: "",
            .credits: text,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
