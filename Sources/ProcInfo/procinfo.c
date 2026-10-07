#include "include/procinfo.h"

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
