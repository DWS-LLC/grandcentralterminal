// Desktop notifications from panes you are not looking at.
//
//   OSC 9 / 777 (libghostty) ──┐
//   bell                      ─┤
//   OSC 7501 blocked/done/err ─┼─► postNotice ─► Notifier ─► banner
//   gctd notify (hooks)       ─┘                              │
//                       click: focus the pane, glide there ◄──┘
//
// A pane that notified wears "●" in its titlebar and never dims until you
// look at it (focus) or type into it.

import AppKit
import UserNotifications
import Common

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let paneKey = "pane"

    var onOpen: ((PaneID) -> Void)?

    // Notifications need an app bundle; a bare `swift run` binary has none.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        return c
    }

    // One notification per pane: a newer one replaces the older.
    func post(pane: PaneID, title: String, subtitle: String?, body: String) {
        guard let center else { return }

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle ?? ""
            content.body = body
            content.sound = .default
            content.threadIdentifier = pane.description
            content.userInfo = [Self.paneKey: pane.description]

            center.add(UNNotificationRequest(identifier: pane.description,
                                             content: content, trigger: nil))
        }
    }

    func clear(pane: PaneID) {
        center?.removeDeliveredNotifications(withIdentifiers: [pane.description])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        defer { done() }
        guard let raw = response.notification.request.content.userInfo[Self.paneKey] as? String,
              let id = PaneID(string: raw) else { return }

        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.onOpen?(id)
        }
    }
}

// Per-pane bookkeeping that keeps notifications honest.
final class NoticeState {
    // Output replayed from the daemon's ring is history: a bell or OSC 9
    // in it already happened and must not fire again on every relaunch.
    private static let replayQuiet: CFAbsoluteTime = 1.5
    // A program repeating itself (bell in a loop) is one notification.
    private static let repeatQuiet: CFAbsoluteTime = 2

    private var replayAt = [PaneID: CFAbsoluteTime]()
    private var last = [PaneID: (body: String, at: CFAbsoluteTime)]()

    func noteReplay(_ id: PaneID) {
        replayAt[id] = CFAbsoluteTimeGetCurrent()
    }

    func isReplaying(_ id: PaneID) -> Bool {
        guard let at = replayAt[id] else { return false }
        return CFAbsoluteTimeGetCurrent() - at < Self.replayQuiet
    }

    func isRepeat(_ id: PaneID, _ body: String) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        defer { last[id] = (body, now) }

        guard let prev = last[id] else { return false }
        return prev.body == body && now - prev.at < Self.repeatQuiet
    }

    func forget(_ id: PaneID) {
        replayAt.removeValue(forKey: id)
        last.removeValue(forKey: id)
    }
}

extension CanvasView {
    func setupNotices() {
        notifier.onOpen = { [weak self] id in
            guard let self, self.panes[id] != nil else { return }
            self.focusPane(id)
            self.followFocus(id)
        }

        // Coming back to the app means you see the focused pane.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil,
            queue: .main) { [weak self] _ in
            guard let id = self?.focusedID else { return }
            self?.clearNotice(id)
        }
    }

    // `title` nil = the pane's own name leads.
    func postNotice(_ id: PaneID, title: String?, body: String) {
        guard GCTConfig.current.notifications, let pane = panes[id] else { return }
        guard !notices.isReplaying(id) else { return }

        let watching = NSApp.isActive && window?.isKeyWindow == true && focusedID == id
        guard !watching, !notices.isRepeat(id, body) else { return }

        pane.hasNotice = true
        notifier.post(pane: id, title: title ?? pane.displayName,
                      subtitle: title == nil ? nil : pane.displayName, body: body)
    }

    func clearNotice(_ id: PaneID) {
        guard let pane = panes[id], pane.hasNotice else { return }
        pane.hasNotice = false
        notifier.clear(pane: id)
    }

    // A program reporting it needs you, finished, or broke (OSC 7501).
    func noticeStatus(_ id: PaneID, from old: ProgramState?) {
        guard let new = panes[id]?.programStatus?.state, new != old else { return }

        switch new {
        case .blocked: postNotice(id, title: nil, body: "Needs your input")
        case .done: postNotice(id, title: nil, body: "Finished")
        case .error: postNotice(id, title: nil, body: "Failed")
        case .idle, .working: break
        }
    }
}
