#include "include/procinfo.h"

#ifdef __linux__
// Linux: readlink /proc/<pid>/cwd. No libproc here.
#include <stdio.h>
#include <unistd.h>

size_t proc_cwd(pid_t pid, char* buf, size_t len) {
    char path[64];
    // snprintf is safe: fixed format, bounded buffer.
    snprintf(path, sizeof(path), "/proc/%d/cwd", (int)pid);
    ssize_t n = readlink(path, buf, len - 1);
    if (n <= 0) return 0;
    buf[n] = '\0';
    return (size_t)n;
}
#else
// macOS: libproc PIDVNODEPATHINFO.
#include <libproc.h>

size_t proc_cwd(pid_t pid, char* buf, size_t len) {
    struct proc_vnodepathinfo vpi;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (n != sizeof(vpi)) return 0;
    if (vpi.pvi_cdir.vip_path[0] == '\0') return 0;
    size_t i = 0;
    while (i + 1 < len && vpi.pvi_cdir.vip_path[i] != '\0') {
        buf[i] = vpi.pvi_cdir.vip_path[i];
        i++;
    }
    buf[i] = '\0';
    return i;
}
#endif
