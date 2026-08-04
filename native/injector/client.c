#include "client.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

enum {
    PAPERWM_INJECTOR_HEADER_SIZE = sizeof(uint16_t) + sizeof(uint8_t),
    PAPERWM_INJECTOR_TIMEOUT_MS = 25,
};

static void set_error(char *error, size_t error_size, const char *format, ...)
{
    if (!error || error_size == 0) return;

    va_list args;
    va_start(args, format);
    vsnprintf(error, error_size, format, args);
    va_end(args);
}

static bool write_all(int fd, const void *buffer, size_t length)
{
    const uint8_t *bytes = buffer;
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(fd, bytes + written, length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        written += (size_t)count;
    }
    return true;
}

static bool read_all(int fd, void *buffer, size_t length)
{
    uint8_t *bytes = buffer;
    size_t received = 0;
    while (received < length) {
        ssize_t count = read(fd, bytes + received, length - received);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        received += (size_t)count;
    }
    return true;
}

static bool request(uid_t uid,
                    uint8_t opcode,
                    const void *payload,
                    size_t payload_size,
                    paperwm_injector_response_t *response,
                    char *error,
                    size_t error_size)
{
    size_t message_size = PAPERWM_INJECTOR_HEADER_SIZE + payload_size;
    if (message_size - sizeof(uint16_t) > PAPERWM_INJECTOR_MAX_MESSAGE) {
        set_error(error, error_size, "injector request is too large");
        return false;
    }

    uint8_t *message = calloc(1, message_size);
    if (!message) {
        set_error(error, error_size, "could not allocate injector request");
        return false;
    }

    uint16_t framed_size = (uint16_t)(message_size - sizeof(uint16_t));
    memcpy(message, &framed_size, sizeof(framed_size));
    message[sizeof(framed_size)] = opcode;
    if (payload_size > 0) {
        memcpy(message + PAPERWM_INJECTOR_HEADER_SIZE, payload, payload_size);
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        set_error(error, error_size, "socket: %s", strerror(errno));
        free(message);
        return false;
    }

    int no_sigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    struct timeval timeout = {
        .tv_sec = 0,
        .tv_usec = PAPERWM_INJECTOR_TIMEOUT_MS * 1000,
    };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_un address = { .sun_family = AF_UNIX };
    int path_length = snprintf(address.sun_path,
                               sizeof(address.sun_path),
                               PAPERWM_INJECTOR_SOCKET_FMT,
                               uid);
    if (path_length < 0 || path_length >= (int)sizeof(address.sun_path)) {
        set_error(error, error_size, "injector socket path is too long");
        close(fd);
        free(message);
        return false;
    }

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        set_error(error,
                  error_size,
                  "connect %s: %s",
                  address.sun_path,
                  strerror(errno));
        close(fd);
        free(message);
        return false;
    }

    bool sent = write_all(fd, message, message_size);
    free(message);
    if (!sent) {
        set_error(error, error_size, "write injector request: %s", strerror(errno));
        close(fd);
        return false;
    }

    paperwm_injector_response_t local_response = {0};
    if (!read_all(fd, &local_response, sizeof(local_response))) {
        set_error(error, error_size, "read injector response: %s", strerror(errno));
        close(fd);
        return false;
    }
    close(fd);

    if (local_response.magic != PAPERWM_INJECTOR_RESPONSE_MAGIC) {
        set_error(error, error_size, "injector returned an invalid response");
        return false;
    }
    if (local_response.protocol_version != PAPERWM_INJECTOR_PROTOCOL_VERSION) {
        set_error(error,
                  error_size,
                  "injector protocol mismatch: payload=%u client=%u",
                  local_response.protocol_version,
                  PAPERWM_INJECTOR_PROTOCOL_VERSION);
        return false;
    }
    if (local_response.status != PAPERWM_INJECTOR_STATUS_OK) {
        set_error(error,
                  error_size,
                  "injector operation failed: status=%u error=%d",
                  local_response.status,
                  local_response.error);
        if (response) *response = local_response;
        return false;
    }

    if (response) *response = local_response;
    if (error && error_size > 0) error[0] = '\0';
    return true;
}

bool paperwm_injector_handshake(uid_t uid,
                                paperwm_injector_response_t *response,
                                char *error,
                                size_t error_size)
{
    return request(uid,
                   PAPERWM_INJECTOR_OP_HANDSHAKE,
                   NULL,
                   0,
                   response,
                   error,
                   error_size);
}

static bool array_request(uid_t uid,
                          uint8_t opcode,
                          const void *items,
                          size_t item_size,
                          uint32_t count,
                          paperwm_injector_response_t *response,
                          char *error,
                          size_t error_size)
{
    if (count > 0 && !items) {
        set_error(error, error_size, "injector request has no items");
        return false;
    }

    size_t items_size = item_size * (size_t)count;
    if (count != 0 && items_size / count != item_size) {
        set_error(error, error_size, "injector request size overflow");
        return false;
    }
    size_t payload_size = sizeof(count) + items_size;
    uint8_t *payload = malloc(payload_size);
    if (!payload) {
        set_error(error, error_size, "could not allocate injector payload");
        return false;
    }

    memcpy(payload, &count, sizeof(count));
    if (items_size > 0) memcpy(payload + sizeof(count), items, items_size);
    bool result = request(uid,
                          opcode,
                          payload,
                          payload_size,
                          response,
                          error,
                          error_size);
    free(payload);
    return result;
}

bool paperwm_injector_move(uid_t uid,
                          const paperwm_injector_move_t *moves,
                          uint32_t count,
                          paperwm_injector_response_t *response,
                          char *error,
                          size_t error_size)
{
    return array_request(uid,
                         PAPERWM_INJECTOR_OP_MOVE,
                         moves,
                         sizeof(*moves),
                         count,
                         response,
                         error,
                         error_size);
}

bool paperwm_injector_transform(uid_t uid,
                               const paperwm_injector_transform_t *transforms,
                               uint32_t count,
                               paperwm_injector_response_t *response,
                               char *error,
                               size_t error_size)
{
    return array_request(uid,
                         PAPERWM_INJECTOR_OP_TRANSFORM,
                         transforms,
                         sizeof(*transforms),
                         count,
                         response,
                         error,
                         error_size);
}

bool paperwm_injector_commit(uid_t uid,
                            const paperwm_injector_commit_t *commits,
                            uint32_t count,
                            paperwm_injector_response_t *response,
                            char *error,
                            size_t error_size)
{
    return array_request(uid,
                         PAPERWM_INJECTOR_OP_COMMIT,
                         commits,
                         sizeof(*commits),
                         count,
                         response,
                         error,
                         error_size);
}

bool paperwm_injector_animate(uid_t uid,
                             const paperwm_injector_animation_t *animations,
                             uint32_t count,
                             paperwm_injector_response_t *response,
                             char *error,
                             size_t error_size)
{
    return array_request(uid,
                         PAPERWM_INJECTOR_OP_ANIMATE,
                         animations,
                         sizeof(*animations),
                         count,
                         response,
                         error,
                         error_size);
}

static bool interactive_request(
    uid_t uid,
    uint8_t opcode,
    const paperwm_injector_move_t *moves,
    uint32_t count,
    paperwm_injector_response_t *response,
    char *error,
    size_t error_size)
{
    return array_request(uid,
                         opcode,
                         moves,
                         sizeof(*moves),
                         count,
                         response,
                         error,
                         error_size);
}

bool paperwm_injector_interactive_begin(
    uid_t uid,
    const paperwm_injector_move_t *moves,
    uint32_t count,
    paperwm_injector_response_t *response,
    char *error,
    size_t error_size)
{
    return interactive_request(uid,
                               PAPERWM_INJECTOR_OP_INTERACTIVE_BEGIN,
                               moves,
                               count,
                               response,
                               error,
                               error_size);
}

bool paperwm_injector_interactive_update(
    uid_t uid,
    const paperwm_injector_move_t *moves,
    uint32_t count,
    paperwm_injector_response_t *response,
    char *error,
    size_t error_size)
{
    return interactive_request(uid,
                               PAPERWM_INJECTOR_OP_INTERACTIVE_UPDATE,
                               moves,
                               count,
                               response,
                               error,
                               error_size);
}

bool paperwm_injector_interactive_end(
    uid_t uid,
    const paperwm_injector_move_t *moves,
    uint32_t count,
    paperwm_injector_response_t *response,
    char *error,
    size_t error_size)
{
    return interactive_request(uid,
                               PAPERWM_INJECTOR_OP_INTERACTIVE_END,
                               moves,
                               count,
                               response,
                               error,
                               error_size);
}
