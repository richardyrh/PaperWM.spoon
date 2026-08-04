#ifndef PAPERWM_INJECTOR_CLIENT_H
#define PAPERWM_INJECTOR_CLIENT_H

#include "protocol.h"

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

bool paperwm_injector_handshake(uid_t uid,
                                paperwm_injector_response_t *response,
                                char *error,
                                size_t error_size);
bool paperwm_injector_move(uid_t uid,
                          const paperwm_injector_move_t *moves,
                          uint32_t count,
                          paperwm_injector_response_t *response,
                          char *error,
                          size_t error_size);
bool paperwm_injector_transform(uid_t uid,
                               const paperwm_injector_transform_t *transforms,
                               uint32_t count,
                               paperwm_injector_response_t *response,
                               char *error,
                               size_t error_size);
bool paperwm_injector_commit(uid_t uid,
                            const paperwm_injector_commit_t *commits,
                            uint32_t count,
                            paperwm_injector_response_t *response,
                            char *error,
                            size_t error_size);
bool paperwm_injector_animate(uid_t uid,
                             const paperwm_injector_animation_t *animations,
                             uint32_t count,
                             paperwm_injector_response_t *response,
                             char *error,
                             size_t error_size);
bool paperwm_injector_interactive_begin(
    uid_t uid,
    const paperwm_injector_move_t *moves,
    uint32_t count,
    paperwm_injector_response_t *response,
    char *error,
    size_t error_size);
bool paperwm_injector_interactive_update(
    uid_t uid,
    const paperwm_injector_move_t *moves,
    uint32_t count,
    paperwm_injector_response_t *response,
    char *error,
    size_t error_size);
bool paperwm_injector_interactive_end(
    uid_t uid,
    const paperwm_injector_move_t *moves,
    uint32_t count,
    paperwm_injector_response_t *response,
    char *error,
    size_t error_size);

#endif
