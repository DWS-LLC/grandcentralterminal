#ifndef PROCINFO_H
#define PROCINFO_H

#include <sys/types.h>
#include <stddef.h>

// Copies the current working directory of `pid` into `buf` (NUL-terminated).
// Returns the string length, or 0 on failure.
size_t proc_cwd(pid_t pid, char* buf, size_t len);

// Copies the command line of `pid` into `buf` (NUL-terminated), arguments
// joined by single spaces. Returns the string length, or 0 on failure.
size_t proc_cmdline(pid_t pid, char* buf, size_t len);

#endif
