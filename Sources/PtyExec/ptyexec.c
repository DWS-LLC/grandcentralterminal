// ptyexec — session + controlling-terminal setup, then exec.
//
// posix_spawn(POSIX_SPAWN_SETSID) + opening the slave via file actions does
// NOT reliably grant the controlling terminal on macOS (the file action
// runs before the session change sticks). Without a ctty, the pty never
// delivers SIGWINCH/SIGINT to the child's process group — htop et al. never
// reflow. This helper runs as the direct child (single-threaded, freshly
// exec'd): setsid, open the slave, TIOCSCTTY, chdir, exec.
//
// argv: ptyexec <slave-path> <cwd> -- <command> [args...]

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char** argv) {
    if (argc < 5 || strcmp(argv[3], "--") != 0) {
        write(2, "usage: ptyexec <slave> <cwd> -- cmd [args...]\n", 46);
        return 2;
    }
    const char* slave = argv[1];
    const char* cwd = argv[2];
    char** cmd = &argv[4];

    // Fresh session; ignore EPERM (already a leader if spawn set one).
    setsid();

    int fd = open(slave, O_RDWR);
    if (fd < 0) return 3;

    // Explicit ctty grant; open() above usually suffices for a leader
    // without a ctty, but be sure.
    ioctl(fd, TIOCSCTTY, 0);

    dup2(fd, 0);
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2) close(fd);

    chdir(cwd);
    execvp(cmd[0], cmd);
    return errno == ENOENT ? 127 : 126;
}
