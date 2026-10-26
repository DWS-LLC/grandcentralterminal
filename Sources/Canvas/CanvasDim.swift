// Dim the panes you are not using, so the busy and the blocked stand out.
//
//   pane is dimmed when ALL hold
//     not focused, not selected, not zoomed
//     no notice (●) and not blocked / failed (OSC 7501)
//     silent for dim-delay seconds (output wakes it)
//
// A half-second tick re-evaluates every pane; focus changes re-evaluate
// at once. The veil itself is one layer per pane (PaneView.setDim).

import AppKit
import Common

final class DimTicker {
    private static let interval: TimeInterval = 0.5

    private var timer: Timer?

    func start(_ tick: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in tick() }
    }
}

extension CanvasView {
    func setupDim() {
        dimTicker.start { [weak self] in self?.refreshDim() }
    }

    func refreshDim() {
        let amount = Float(GCTConfig.current.dimInactive)
        let now = CFAbsoluteTimeGetCurrent()

        for (id, pane) in panes {
            let dim = amount > 0 && shouldDim(id, pane, now: now)
            pane.setDim(dim ? amount : 0)
        }
    }

    private func shouldDim(_ id: PaneID, _ pane: PaneView, now: CFAbsoluteTime) -> Bool {
        if id == focusedID || pane.isSelected || pane.isZoomed || pane.hasNotice { return false }

        switch pane.programStatus?.state {
        case .blocked, .error: return false
        default: break
        }

        return now - arrange.outputRank(id) >= GCTConfig.current.dimDelay
    }
}
