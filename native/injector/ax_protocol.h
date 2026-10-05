#ifndef PAPERWM_AX_PROTOCOL_H
#define PAPERWM_AX_PROTOCOL_H

#include <stdint.h>

#define PAPERWM_AX_MAGIC 0x58415750u /* PWAX */
#define PAPERWM_AX_VERSION 1u
#define PAPERWM_AX_SOCKET_FMT "/tmp/paperwm-ax-%u.socket"

typedef struct paperwm_ax_request {
    uint32_t magic;
    uint32_t version;
    uint32_t window_id;
    int32_t pid;
    double timeout;
    double start_x;
    double start_y;
    double start_w;
    double start_h;
    double end_x;
    double end_y;
    double end_w;
    double end_h;
} paperwm_ax_request_t;

typedef struct paperwm_ax_response {
    uint32_t magic;
    uint32_t version;
    int32_t status;
    uint32_t concealed;
    double accepted_w;
    double accepted_h;
    char error[160];
} paperwm_ax_response_t;

#endif
