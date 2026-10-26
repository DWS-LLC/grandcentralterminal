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

size_t proc_cmdline(pid_t pid, char* buf, size_t len) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
    FILE* f = fopen(path, "r");
    if (!f) return 0;
    size_t n = fread(buf, 1, len - 1, f);
    fclose(f);
    // argv is NUL-separated; the trailing NUL ends the last argument.
    if (n > 0 && buf[n - 1] == '\0') n--;
    for (size_t i = 0; i < n; i++) {
        if (buf[i] == '\0') buf[i] = ' ';
    }
    buf[n] = '\0';
    return n;
}
#else
// macOS: libproc PIDVNODEPATHINFO.
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

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

// KERN_PROCARGS2 layout: int argc, exec path, NUL padding, then argc
// NUL-terminated argv strings (the environment follows; ignored).
size_t proc_cmdline(pid_t pid, char* buf, size_t len) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, (int)pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return 0;

    char* raw = malloc(size);
    if (!raw) return 0;
    if (sysctl(mib, 3, raw, &size, NULL, 0) != 0 || size < sizeof(int)) {
        free(raw);
        return 0;
    }

    int argc;
    memcpy(&argc, raw, sizeof(argc));
    char* p = raw + sizeof(argc);
    char* end = raw + size;

    while (p < end && *p != '\0') p++;   // exec path
    while (p < end && *p == '\0') p++;   // padding

    size_t out = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t n = strnlen(p, (size_t)(end - p));
        if (i > 0 && out + 1 < len) buf[out++] = ' ';
        for (size_t k = 0; k < n && out + 1 < len; k++) buf[out++] = p[k];
        p += n + 1;
    }
    buf[out] = '\0';
    free(raw);
    return out;
}
#endif
