// Redial schedule for remote daemons that dropped or never answered.
//
//   drop / unreachable ──► arm ──► every 60s: tick ──► redial the missing
//                                  └─ stops by itself once `tick` says none are left
//
// Dialing blocks (5s connect timeout), so it runs off-main; `begin`/`end`
// keep one dial per host in flight.

import Foundation

final class RemoteRetry {
    static let interval: TimeInterval = 60

    private var timer: Timer?
    private var dialing = Set<String>()

    // `tick` returns false once nothing is left to retry.
    func arm(_ tick: @escaping () -> Bool) {
        guard timer == nil else { return }

        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            if !tick() { self?.cancel() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    func begin(_ name: String) -> Bool { dialing.insert(name).inserted }

    func end(_ name: String) { dialing.remove(name) }
}
