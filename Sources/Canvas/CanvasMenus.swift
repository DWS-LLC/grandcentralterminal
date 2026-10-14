// Menubar + context-menu items for Arrange and group ops.
//
// One item factory feeds both surfaces, so the menubar and the canvas
// right-click menu can't drift:
//
//   GCTMenus.arrangeItems(scope:)  ──►  menubar "Arrange" (scope .auto)
//                                  └─►  right-click "Arrange By / As"
//
// Menubar items have no target: they ride the responder chain to the
// canvas. State (checkmarks, enabled, scope label) is filled in by
// validateMenuItem each time a menu opens. No key equivalents on
// purpose: menu shortcuts would shadow terminal keybinds.

import AppKit
import Common

enum GCTMenus {
    static func arrangeItems(scope: ArrangeScope, target: AnyObject? = nil) -> [NSMenuItem] {
        var out = [NSMenuItem]()

        let by = NSMenuItem(title: "Arrange By", action: nil, keyEquivalent: "")
        by.submenu = submenu("Arrange By", ArrangeKey.allCases.map {
            actionItem($0.title, ArrangeAction(change: .key($0), scope: scope), target)
        })
        out.append(by)

        let shape = NSMenuItem(title: "Arrange As", action: nil, keyEquivalent: "")
        shape.submenu = submenu("Arrange As", ArrangeShape.allCases.map {
            actionItem($0.title, ArrangeAction(change: .shape($0), scope: scope), target)
        })
        out.append(shape)

        let undo = NSMenuItem(title: "Undo Arrange",
                              action: #selector(CanvasView.undoArrangeMenu(_:)),
                              keyEquivalent: "")
        undo.target = target
        out.append(undo)
        return out
    }

    // Top-level menubar menu: flat, with a header saying what it acts on.
    static func arrangeMenu() -> NSMenu {
        let menu = NSMenu(title: "Arrange")
        menu.addItem(NSMenuItem(title: "Arranges", action: #selector(CanvasView.arrangeScopeInfo(_:)),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        for key in ArrangeKey.allCases {
            menu.addItem(actionItem(key.title, ArrangeAction(change: .key(key), scope: .auto), nil))
        }
        menu.addItem(.separator())
        for shape in ArrangeShape.allCases {
            menu.addItem(actionItem(shape.title, ArrangeAction(change: .shape(shape), scope: .auto), nil))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Undo Arrange",
                                action: #selector(CanvasView.undoArrangeMenu(_:)),
                                keyEquivalent: ""))
        return menu
    }

    static func groupMenu() -> NSMenu {
        let menu = NSMenu(title: "Group")
        menu.addItem(NSMenuItem(title: "New Group from Selection…",
                                action: #selector(CanvasView.newGroupMenu(_:)),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Rename Group…",
                                action: #selector(CanvasView.renameCurrentGroupMenu(_:)),
                                keyEquivalent: ""))

        let color = NSMenuItem(title: "Group Color", action: nil, keyEquivalent: "")
        color.submenu = submenu("Group Color", GroupStyle.palette.map { hex in
            let item = NSMenuItem(title: hex,
                                  action: #selector(CanvasView.recolorCurrentGroupMenu(_:)),
                                  keyEquivalent: "")
            item.representedObject = hex
            item.attributedTitle = NSAttributedString(
                string: "  \(hex)",
                attributes: [.foregroundColor: NSColor(gctHex: hex) ?? .labelColor])
            return item
        })
        menu.addItem(color)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Select Group Members",
                                action: #selector(CanvasView.selectGroupMembersMenu(_:)),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ungroup",
                                action: #selector(CanvasView.ungroupCurrentMenu(_:)),
                                keyEquivalent: ""))
        return menu
    }

    private static func actionItem(_ title: String, _ action: ArrangeAction,
                                   _ target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(CanvasView.arrangeMenu(_:)),
                              keyEquivalent: "")
        item.target = target
        item.representedObject = action
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        return menu
    }
}

extension CanvasView: NSMenuItemValidation {
    // MARK: Arrange actions

    @objc func arrangeMenu(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ArrangeAction else { return }
        let prior = (key: arrange.key, shape: arrange.shape)
        switch action.change {
        case .key(let key): arrange.key = key
        case .shape(let shape): arrange.shape = shape
        }
        // A refused arrange must not silently change the remembered choice.
        if !arrangeCanvas(scope: action.scope) {
            (arrange.key, arrange.shape) = prior
        }
    }

    @objc func undoArrangeMenu(_ sender: NSMenuItem) {
        undoArrange()
    }

    // Header item: never fires, only carries the live scope label.
    @objc func arrangeScopeInfo(_ sender: NSMenuItem) {}

    // MARK: Group actions (act on the focused pane's group)

    private func currentGroup() -> GroupID? {
        focusedID.flatMap { groupOf($0) }
    }

    @objc func newGroupMenu(_ sender: NSMenuItem) {
        groupStagedSelection()
    }

    @objc func renameCurrentGroupMenu(_ sender: NSMenuItem) {
        guard let g = currentGroup() else { return }
        promptRenameGroup(g)
    }

    @objc func ungroupCurrentMenu(_ sender: NSMenuItem) {
        guard let g = currentGroup() else { return }
        ungroup(g)
    }

    @objc func selectGroupMembersMenu(_ sender: NSMenuItem) {
        guard let g = currentGroup(), let members = groupMetas[g]?.members else { return }
        setSelected(Set(members))
    }

    @objc func recolorCurrentGroupMenu(_ sender: NSMenuItem) {
        guard let g = currentGroup(),
              let hex = (sender.representedObject as? String).flatMap(GroupStyle.sanitizedColor)
        else { return }
        recolorGroup(g, hex: hex)
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(arrangeMenu(_:)):
            guard let action = item.representedObject as? ArrangeAction else { return false }
            switch action.change {
            case .key(let key): item.state = key == arrange.key ? .on : .off
            case .shape(let shape): item.state = shape == arrange.shape ? .on : .off
            }
            return panes.count >= 2
        case #selector(undoArrangeMenu(_:)):
            return !arrange.undo.isEmpty
        case #selector(arrangeScopeInfo(_:)):
            item.title = scopeLabel()
            return false
        case #selector(newGroupMenu(_:)):
            return !panes.isEmpty
        case #selector(renameCurrentGroupMenu(_:)), #selector(ungroupCurrentMenu(_:)),
             #selector(selectGroupMembersMenu(_:)), #selector(recolorCurrentGroupMenu(_:)):
            return currentGroup() != nil
        default:
            return true
        }
    }

    private func scopeLabel() -> String {
        switch resolveArrangeScope(.auto) {
        case .selection: return "Arranges: \(liveSelected().count) selected"
        case .group(let g): return "Arranges: group “\(groupMetas[g]?.name ?? "Group")”"
        default: return "Arranges: all panes"
        }
    }
}
