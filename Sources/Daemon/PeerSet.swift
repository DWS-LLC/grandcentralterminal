// The peer links this daemon keeps, one per [host.<name>] in config.toml.
// config.toml is the canvas's file too; the daemon just re-reads it when its
// mtime moves, so `⌘⇧R` in the app (or an edit over ssh) reaches both.

import Foundation
import Common

final class PeerSet: @unchecked Sendable {
    private let ownerID: String
    private weak var delegate: PeerLinkDelegate?
    private let lock = NSLock()
    private var links = [String: PeerLink]()
    private var configStamp: Date?
    private var ticks = 0

    // housekeep ticks every 0.5s; a stat every 5s is plenty.
    private static let ticksPerPoll = 10

    init(ownerID: String) {
        self.ownerID = ownerID
    }

    func start(delegate: PeerLinkDelegate) {
        self.delegate = delegate
        configStamp = Self.stamp()
        sync(PeerConfig.load())
    }

    func link(for name: String) -> PeerLink? {
        lock.lock(); defer { lock.unlock() }
        return links[name]
    }

    func infos() -> [PeerInfo] {
        lock.lock(); defer { lock.unlock() }
        return links.values.map { PeerInfo(name: $0.host.name, up: $0.isUp) }
            .sorted { $0.name < $1.name }
    }

    func pollConfig() {
        ticks += 1
        guard ticks % Self.ticksPerPoll == 0 else { return }

        let now = Self.stamp()
        guard now != configStamp else { return }

        configStamp = now
        sync(PeerConfig.load())
    }

    private static func stamp() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: PeerConfig.path())
        return attrs?[.modificationDate] as? Date
    }

    // Keep links whose host entry is unchanged; replace edited ones, drop
    // removed ones, dial new ones.
    private func sync(_ hosts: [PeerHost]) {
        var started = [PeerLink]()
        var stopped = [PeerLink]()

        lock.lock()
        let old = links
        var next = [String: PeerLink]()
        for h in hosts {
            if let kept = old[h.name], kept.host == h {
                next[h.name] = kept
                continue
            }

            let fresh = PeerLink(host: h, ownerID: ownerID)
            fresh.delegate = delegate
            next[h.name] = fresh
            started.append(fresh)
        }
        for (name, link) in old where next[name] == nil || next[name] !== link {
            stopped.append(link)
        }
        links = next
        lock.unlock()

        stopped.forEach { $0.stop() }
        started.forEach { $0.start() }
    }
}
