#ifndef PAPERWM_AX_CLIENT_H
#define PAPERWM_AX_CLIENT_H

#include "ax_protocol.h"

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

bool paperwm_ax_prepare(uid_t uid,
                        const paperwm_ax_request_t *request,
                        paperwm_ax_response_t *response,
                        char *error,
                        size_t error_size);

#endif
