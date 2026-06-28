#ifndef RETASKER_BROKER_H
#define RETASKER_BROKER_H

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// Best-effort write of a fully-formed broker message (route prefix + signal +
// payload + trailing newline) to the xovi-message-broker pipe. Returns 0 on
// success, -1 if the pipe could not be opened or the write failed; callers that
// emit as a pure side effect ignore the result. `tag` names the caller in the
// two diagnostic log lines only.
//
// Header-only like rotate.h: main.c and bridge.c each include it from one TU, so
// `static` is fine and no shared .c / Makefile entry is needed.
static int emit_broker_signal(const char *tag, const char *msg) {
    int fd = open("/run/xovi-mb", O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "[retasker] %s: cannot open broker pipe\n", tag);
        return -1;
    }
    int rc = 0;
    if (write(fd, msg, strlen(msg)) < 0) {
        fprintf(stderr, "[retasker] %s: pipe write failed\n", tag);
        rc = -1;
    }
    close(fd);
    return rc;
}

#endif // RETASKER_BROKER_H
