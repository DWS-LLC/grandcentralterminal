// GCTDaemon: the executable of "GCT Daemon.app". It does nothing but run
// gctd as its child and live exactly as long as gctd does.
//
// Why a launcher and not gctd itself: macOS Local Network privacy needs the
// app asking for LAN access to have an identity of its own. gctd's binary is
// also shipped bare (the CLI), and macOS keys the permission by the binary's
// UUID, so the daemon-as-app got filed under a bare "gctd" with no team and
// nothing to prompt for. This binary exists only here, so the app is
// unambiguously "GCT Daemon"; gctd's LAN connections are attributed to it as
// its child.
//
//   LaunchServices -> GCT Daemon.app/Contents/MacOS/GCTDaemon
//                        └─ posix_spawn ─► GCT Daemon.app/Contents/MacOS/gctd
//
// Signals sent to us (quit, logout) go on to gctd; our exit code is its.

#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

static volatile pid_t child_pid = 0;

static void forward(int sig) {
    if (child_pid > 0) {
        kill(child_pid, sig);
    }
}

int main(int argc, char** argv) {
    char self[PATH_MAX];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) {
        return 127;
    }

    char gctd[PATH_MAX];
    snprintf(gctd, sizeof(gctd), "%s/gctd", dirname(self));
    argv[0] = gctd;

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = forward;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, gctd, NULL, NULL, argv, environ);
    if (rc != 0) {
        fprintf(stderr, "GCTDaemon: cannot start %s: %s\n", gctd, strerror(rc));
        return 127;
    }
    child_pid = pid;

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            return 1;
        }
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 128 + WTERMSIG(status);
}
