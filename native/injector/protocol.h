#ifndef PAPERWM_INJECTOR_PROTOCOL_H
#define PAPERWM_INJECTOR_PROTOCOL_H

#include <stdint.h>

#define PAPERWM_INJECTOR_PROTOCOL_VERSION 1
#define PAPERWM_INJECTOR_PAYLOAD_VERSION "0.3.0"
#define PAPERWM_INJECTOR_SOCKET_FMT "/tmp/paperwm-sa-%u.socket"
#define PAPERWM_INJECTOR_MAX_MESSAGE UINT16_MAX
#define PAPERWM_INJECTOR_RESPONSE_MAGIC 0x31574d50u /* PWM1 */

enum paperwm_injector_opcode {
    PAPERWM_INJECTOR_OP_HANDSHAKE = 0x01,
    PAPERWM_INJECTOR_OP_MOVE = 0x02,
    PAPERWM_INJECTOR_OP_TRANSFORM = 0x03,
    PAPERWM_INJECTOR_OP_COMMIT = 0x04,
    PAPERWM_INJECTOR_OP_ANIMATE = 0x05,
    PAPERWM_INJECTOR_OP_INTERACTIVE_BEGIN = 0x06,
    PAPERWM_INJECTOR_OP_INTERACTIVE_UPDATE = 0x07,
    PAPERWM_INJECTOR_OP_INTERACTIVE_END = 0x08,
};

enum paperwm_injector_capability {
    PAPERWM_INJECTOR_CAP_MOVE = 1u << 0,
    PAPERWM_INJECTOR_CAP_TRANSFORM = 1u << 1,
    PAPERWM_INJECTOR_CAP_COMMIT = 1u << 2,
    PAPERWM_INJECTOR_CAP_ANIMATE = 1u << 3,
    PAPERWM_INJECTOR_CAP_INTERACTIVE = 1u << 4,
};

enum paperwm_injector_status {
    PAPERWM_INJECTOR_STATUS_OK = 0,
    PAPERWM_INJECTOR_STATUS_BAD_MESSAGE = 1,
    PAPERWM_INJECTOR_STATUS_UNSUPPORTED = 2,
    PAPERWM_INJECTOR_STATUS_SKYLIGHT_ERROR = 3,
};

typedef struct __attribute__((packed)) paperwm_injector_response {
    uint32_t magic;
    uint16_t protocol_version;
    uint16_t status;
    uint32_t capabilities;
    int32_t error;
    char payload_version[16];
} paperwm_injector_response_t;

typedef struct paperwm_injector_move {
    uint32_t window_id;
    double x;
    double y;
} paperwm_injector_move_t;

typedef struct paperwm_injector_transform {
    uint32_t window_id;
    double base_x;
    double base_y;
    double sx;
    double sy;
    double tx;
    double ty;
} paperwm_injector_transform_t;

typedef struct paperwm_injector_commit {
    uint32_t window_id;
    double x;
    double y;
    double sx;
    double sy;
    double tx;
    double ty;
} paperwm_injector_commit_t;

enum paperwm_injector_animation_flags {
    PAPERWM_INJECTOR_ANIMATION_MOVE = 1u << 0,
    PAPERWM_INJECTOR_ANIMATION_AUTO_COMMIT = 1u << 1,
};

typedef struct paperwm_injector_animation {
    uint32_t window_id;
    uint32_t flags;
    double start_x;
    double start_y;
    double end_x;
    double end_y;
    double start_sx;
    double start_sy;
    double end_sx;
    double end_sy;
    double duration;
    double curve_x1;
    double curve_y1;
    double curve_x2;
    double curve_y2;
} paperwm_injector_animation_t;

#endif
