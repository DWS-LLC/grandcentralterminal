// Single-instance guard: an exclusive flock on the pid file.
//
// The kernel releases the lock when the holder dies (crash, SIGKILL,
// reboot), so a leftover file never blocks startup. The pid inside is
// informational only (scripts/dev.sh kills by it).

import Foundation

final class PidLock {
    private let fd: Int32

    // nil when another live process holds the lock.
    // O_CLOEXEC: pane shells must not inherit (and outlive us holding) it.
    init?(path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)

        // Unopenable file: serve unguarded rather than refuse to start.
        guard fd >= 0 else {
            return
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
    }

    // Rewrite in place: replacing the file would swap the locked inode.
    // No deinit close: the lock lives as long as the process.
    func write(_ pid: Int32) {
        guard fd >= 0 else {
            return
        }

        let line = Array("\(pid)\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pwrite(fd, line, line.count, 0)
    }
}
