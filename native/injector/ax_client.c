#include "ax_client.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static bool transfer_all(int fd, void *bytes, size_t size, bool sending)
{
    size_t offset = 0;
    while (offset < size) {
        ssize_t count = sending ?
            send(fd, (char *)bytes + offset, size - offset, 0) :
            recv(fd, (char *)bytes + offset, size - offset, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count == 0) errno = ECONNRESET;
        if (count <= 0) return false;
        offset += (size_t)count;
    }
    return true;
}

bool paperwm_ax_prepare(uid_t uid,
                        const paperwm_ax_request_t *request,
                        paperwm_ax_response_t *response,
                        char *error,
                        size_t error_size)
{
    if (!request || !response) return false;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        snprintf(error, error_size, "AX socket: %s", strerror(errno));
        return false;
    }
    int no_sigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    struct timeval timeout = { .tv_sec = 1, .tv_usec = 500000 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_un address = { .sun_family = AF_UNIX };
    int length = snprintf(address.sun_path, sizeof(address.sun_path),
                          PAPERWM_AX_SOCKET_FMT, uid);
    if (length < 0 || length >= (int)sizeof(address.sun_path)) {
        snprintf(error, error_size, "AX socket path is too long");
        close(fd);
        return false;
    }
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        snprintf(error, error_size, "connect %s: %s", address.sun_path,
                 strerror(errno));
        close(fd);
        return false;
    }
    bool transferred = transfer_all(fd, (void *)request, sizeof(*request), true) &&
        transfer_all(fd, response, sizeof(*response), false);
    int saved_errno = errno;
    close(fd);
    if (!transferred) {
        snprintf(error, error_size, "AX service request: %s", strerror(saved_errno));
        return false;
    }
    if (response->magic != PAPERWM_AX_MAGIC ||
        response->version != PAPERWM_AX_VERSION) {
        snprintf(error, error_size, "AX service protocol mismatch");
        return false;
    }
    if (response->status != 0) {
        snprintf(error, error_size, "%s", response->error);
        return false;
    }
    if (error_size > 0) error[0] = '\0';
    return true;
}
