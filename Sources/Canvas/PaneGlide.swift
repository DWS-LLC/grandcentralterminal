// Eases panes from where they are to where an arrange run put them.
//
//   run ──► tween (every tick, local frames only) ──► land (final rects)
//
// The daemon and the terminal surfaces hear about the move once, on land:
// a mid-glide echo from the daemon would yank panes back to the end, and
// reflowing a terminal 120 times a second is just rude.

import AppKit
import Common

struct GlideStep {
    var id: PaneID
    var from: Rect
    var to: Rect
}

enum GlidePhase {
    case tween
    case land
}

final class PaneGlide {
    private static let tickRate = 1.0 / 120.0
    private static let minDuration = 0.01

    private var timer: Timer?
    private var steps = [GlideStep]()
    private var started = 0.0
    private var duration = 0.0
    private var apply: (([PaneRect], GlidePhase) -> Void)?

    // `apply` gets the rects for this tick, then the final ones on land.
    func run(_ steps: [GlideStep], duration: Double,
             apply: @escaping ([PaneRect], GlidePhase) -> Void) {
        finish()
        guard !steps.isEmpty else { return }

        self.steps = steps
        self.apply = apply
        self.duration = max(duration, Self.minDuration)
        started = CACurrentMediaTime()

        let t = Timer(timeInterval: Self.tickRate, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // Jump to the end now. No-op when nothing is gliding, so anything that
    // reads pane frames can call it first and trust what it sees.
    func finish() {
        guard timer != nil else { return }
        land()
    }

    private func tick() {
        let t = min((CACurrentMediaTime() - started) / duration, 1)
        if t >= 1 {
            land()
            return
        }

        let ease = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        apply?(steps.map { PaneRect(id: $0.id, rect: Self.lerp($0.from, $0.to, ease)) }, .tween)
    }

    private func land() {
        let final = steps.map { PaneRect(id: $0.id, rect: $0.to) }
        let done = apply

        timer?.invalidate()
        timer = nil
        steps = []
        apply = nil

        done?(final, .land)
    }

    private static func lerp(_ a: Rect, _ b: Rect, _ t: Double) -> Rect {
        Rect(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
             w: a.w + (b.w - a.w) * t, h: a.h + (b.h - a.h) * t)
    }
}
