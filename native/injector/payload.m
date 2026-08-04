#include "protocol.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

typedef int SLSConnectionID;
typedef uint32_t SLSWindowID;

typedef SLSConnectionID (*SLSMainConnectionIDFn)(void);
typedef CGError (*SLSGetWindowBoundsFn)(SLSConnectionID, SLSWindowID, CGRect *);
typedef CGError (*SLSGetWindowTransformFn)(SLSConnectionID,
                                           SLSWindowID,
                                           CGAffineTransform *);
typedef CGError (*SLSSetWindowTransformFn)(SLSConnectionID,
                                           SLSWindowID,
                                           CGAffineTransform);
typedef CGError (*SLSMoveWindowWithGroupFn)(SLSConnectionID,
                                            SLSWindowID,
                                            const CGPoint *);
typedef CGError (*SLSDisableUpdateFn)(SLSConnectionID);
typedef CGError (*SLSReenableUpdateFn)(SLSConnectionID);

static void *skylight_handle;
static SLSMainConnectionIDFn sls_main_connection_id;
static SLSGetWindowBoundsFn sls_get_window_bounds;
static SLSGetWindowTransformFn sls_get_window_transform;
static SLSSetWindowTransformFn sls_set_window_transform;
static SLSMoveWindowWithGroupFn sls_move_window_with_group;
static SLSDisableUpdateFn sls_disable_update;
static SLSReenableUpdateFn sls_reenable_update;
static int server_fd = -1;
static char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];

typedef struct paperwm_animation_runtime_item {
    paperwm_injector_animation_t value;
    bool finished;
} paperwm_animation_runtime_item_t;

typedef struct paperwm_animation_context {
    CVDisplayLinkRef display_link;
    paperwm_animation_runtime_item_t *items;
    uint32_t count;
    uint64_t generation;
    uint64_t animation_clock;
    uint64_t first_frame_clock;
    uint64_t last_frame_clock;
    uint64_t total_interval_clock;
    uint64_t max_interval_clock;
    uint32_t frame_count;
    CGError error;
} paperwm_animation_context_t;

typedef struct paperwm_interactive_context {
    CVDisplayLinkRef display_link;
    paperwm_injector_move_t *targets;
    uint32_t count;
    uint64_t generation;
    uint64_t update_sequence;
    uint64_t applied_sequence;
    uint64_t first_frame_clock;
    uint64_t last_frame_clock;
    uint64_t total_interval_clock;
    uint64_t max_interval_clock;
    uint32_t callback_count;
    uint32_t applied_frames;
    CGError error;
    bool ended;
} paperwm_interactive_context_t;

static pthread_mutex_t animation_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t next_animation_generation;
static uint64_t active_animation_generation;
static pthread_mutex_t interactive_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t next_interactive_generation;
static uint64_t active_interactive_generation;
static paperwm_interactive_context_t *active_interactive_context;
static double cv_host_clock_frequency;

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

static bool load_skylight(void)
{
    if (skylight_handle) return true;

    skylight_handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY | RTLD_LOCAL);
    if (!skylight_handle) return false;

    sls_main_connection_id =
        (SLSMainConnectionIDFn)dlsym(skylight_handle, "SLSMainConnectionID");
    if (!sls_main_connection_id) {
        sls_main_connection_id =
            (SLSMainConnectionIDFn)dlsym(skylight_handle, "CGSMainConnectionID");
    }
    sls_get_window_bounds =
        (SLSGetWindowBoundsFn)dlsym(skylight_handle, "SLSGetWindowBounds");
    if (!sls_get_window_bounds) {
        sls_get_window_bounds =
            (SLSGetWindowBoundsFn)dlsym(skylight_handle, "CGSGetWindowBounds");
    }
    sls_get_window_transform =
        (SLSGetWindowTransformFn)dlsym(skylight_handle, "SLSGetWindowTransform");
    if (!sls_get_window_transform) {
        sls_get_window_transform =
            (SLSGetWindowTransformFn)dlsym(skylight_handle, "CGSGetWindowTransform");
    }
    sls_set_window_transform =
        (SLSSetWindowTransformFn)dlsym(skylight_handle, "SLSSetWindowTransform");
    if (!sls_set_window_transform) {
        sls_set_window_transform =
            (SLSSetWindowTransformFn)dlsym(skylight_handle, "CGSSetWindowTransform");
    }
    sls_move_window_with_group =
        (SLSMoveWindowWithGroupFn)dlsym(skylight_handle, "SLSMoveWindowWithGroup");
    sls_disable_update =
        (SLSDisableUpdateFn)dlsym(skylight_handle, "SLSDisableUpdate");
    if (!sls_disable_update) {
        sls_disable_update =
            (SLSDisableUpdateFn)dlsym(skylight_handle, "CGSDisableUpdate");
    }
    sls_reenable_update =
        (SLSReenableUpdateFn)dlsym(skylight_handle, "SLSReenableUpdate");
    if (!sls_reenable_update) {
        sls_reenable_update =
            (SLSReenableUpdateFn)dlsym(skylight_handle, "CGSReenableUpdate");
    }

    if (!sls_main_connection_id || !sls_get_window_bounds ||
        !sls_get_window_transform || !sls_set_window_transform ||
        !sls_move_window_with_group) {
        dlclose(skylight_handle);
        skylight_handle = NULL;
        return false;
    }
    return true;
}

static paperwm_injector_response_t response(uint16_t status, int32_t error)
{
    uint32_t capabilities = PAPERWM_INJECTOR_CAP_MOVE |
                            PAPERWM_INJECTOR_CAP_TRANSFORM |
                            PAPERWM_INJECTOR_CAP_ANIMATE |
                            PAPERWM_INJECTOR_CAP_INTERACTIVE;
    if (sls_disable_update && sls_reenable_update) {
        capabilities |= PAPERWM_INJECTOR_CAP_COMMIT;
    }
    paperwm_injector_response_t value = {
        .magic = PAPERWM_INJECTOR_RESPONSE_MAGIC,
        .protocol_version = PAPERWM_INJECTOR_PROTOCOL_VERSION,
        .status = status,
        .capabilities = capabilities,
        .error = error,
        .payload_version = PAPERWM_INJECTOR_PAYLOAD_VERSION,
    };
    return value;
}

static bool parse_array(const uint8_t *payload,
                        size_t payload_size,
                        size_t item_size,
                        uint32_t *count,
                        const uint8_t **items)
{
    if (payload_size < sizeof(*count)) return false;
    memcpy(count, payload, sizeof(*count));

    size_t array_size = item_size * (size_t)*count;
    if (*count != 0 && array_size / *count != item_size) return false;
    if (array_size != payload_size - sizeof(*count)) return false;

    *items = payload + sizeof(*count);
    return true;
}

static CGError perform_moves(const uint8_t *payload, size_t payload_size)
{
    uint32_t count = 0;
    const uint8_t *item_bytes = NULL;
    if (!parse_array(payload,
                     payload_size,
                     sizeof(paperwm_injector_move_t),
                     &count,
                     &item_bytes)) {
        return kCGErrorIllegalArgument;
    }
    if (count == 0) return kCGErrorSuccess;

    paperwm_injector_move_t *moves = calloc(count, sizeof(*moves));
    if (!moves) {
        return kCGErrorFailure;
    }
    memcpy(moves, item_bytes, count * sizeof(*moves));

    SLSConnectionID connection = sls_main_connection_id();
    CGError error = kCGErrorSuccess;
    for (uint32_t index = 0; index < count; ++index) {
        if (!moves[index].window_id || !isfinite(moves[index].x) ||
            !isfinite(moves[index].y)) {
            error = kCGErrorIllegalArgument;
            break;
        }
        CGPoint point = CGPointMake(moves[index].x, moves[index].y);
        error = sls_move_window_with_group(
            connection, moves[index].window_id, &point);
        if (error != kCGErrorSuccess) break;
    }

    free(moves);
    return error;
}

static bool transforms_equal(CGAffineTransform left, CGAffineTransform right)
{
    const CGFloat tolerance = 0.01;
    return fabs(left.a - right.a) <= tolerance &&
           fabs(left.b - right.b) <= tolerance &&
           fabs(left.c - right.c) <= tolerance &&
           fabs(left.d - right.d) <= tolerance &&
           fabs(left.tx - right.tx) <= tolerance &&
           fabs(left.ty - right.ty) <= tolerance;
}

static double sample_curve(double a, double b, double c, double t)
{
    return ((a * t + b) * t + c) * t;
}

static double sample_curve_derivative(double a, double b, double c, double t)
{
    return (3.0 * a * t * t) + (2.0 * b * t) + c;
}

static double ease_progress(const paperwm_injector_animation_t *item,
                            double progress)
{
    if (progress <= 0.0) return 0.0;
    if (progress >= 1.0) return 1.0;

    double cx = 3.0 * item->curve_x1;
    double bx = (3.0 * item->curve_x2) - (2.0 * cx);
    double ax = 1.0 - cx - bx;
    double cy = 3.0 * item->curve_y1;
    double by = (3.0 * item->curve_y2) - (2.0 * cy);
    double ay = 1.0 - cy - by;
    double t = progress;

    for (int iteration = 0; iteration < 5; ++iteration) {
        double error = sample_curve(ax, bx, cx, t) - progress;
        if (fabs(error) < 0.00001) break;
        double slope = sample_curve_derivative(ax, bx, cx, t);
        if (fabs(slope) < 0.000001) break;
        double next_t = t - (error / slope);
        if (next_t < 0.0 || next_t > 1.0) break;
        t = next_t;
    }

    if (fabs(sample_curve(ax, bx, cx, t) - progress) >= 0.00001) {
        double low = 0.0;
        double high = 1.0;
        for (int iteration = 0; iteration < 12; ++iteration) {
            t = (low + high) / 2.0;
            if (sample_curve(ax, bx, cx, t) < progress) {
                low = t;
            } else {
                high = t;
            }
        }
    }

    return sample_curve(ay, by, cy, t);
}

static double interpolate(double start, double end, double progress)
{
    return start + ((end - start) * progress);
}

static void log_animation_result(const paperwm_animation_context_t *context,
                                 const char *status)
{
    char path[128] = {0};
    int length = snprintf(path,
                          sizeof(path),
                          "/tmp/paperwm-payload-%u.log",
                          getuid());
    if (length < 0 || length >= (int)sizeof(path)) return;

    int fd = open(path,
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                  0600);
    if (fd < 0) return;

    double elapsed_ms = 0.0;
    double average_interval_ms = 0.0;
    double max_interval_ms = 0.0;
    if (cv_host_clock_frequency > 0.0 && context->frame_count > 1) {
        elapsed_ms = (double)(context->last_frame_clock -
                              context->first_frame_clock) *
            1000.0 / cv_host_clock_frequency;
        average_interval_ms =
            (double)context->total_interval_clock * 1000.0 /
            (cv_host_clock_frequency * (context->frame_count - 1));
        max_interval_ms = (double)context->max_interval_clock * 1000.0 /
            cv_host_clock_frequency;
    }
    double measured_fps = elapsed_ms > 0.0 ?
        (context->frame_count - 1) * 1000.0 / elapsed_ms : 0.0;

    dprintf(fd,
            "generation=%llu status=%s windows=%u frames=%u elapsed_ms=%.3f "
            "fps=%.3f interval_avg_ms=%.3f interval_max_ms=%.3f error=%d\n",
            context->generation,
            status,
            context->count,
            context->frame_count,
            elapsed_ms,
            measured_fps,
            average_interval_ms,
            max_interval_ms,
            context->error);
    close(fd);
}

static CGError apply_animation_frame(paperwm_animation_context_t *context,
                                     uint64_t current_clock)
{
    SLSConnectionID connection = sls_main_connection_id();
    CGError error = kCGErrorSuccess;
    double elapsed = (double)(current_clock - context->animation_clock) /
        cv_host_clock_frequency;
    bool atomic_commit = false;

    for (uint32_t index = 0; index < context->count; ++index) {
        paperwm_animation_runtime_item_t *runtime = &context->items[index];
        const paperwm_injector_animation_t *item = &runtime->value;
        if (!runtime->finished &&
            !(item->flags & PAPERWM_INJECTOR_ANIMATION_MOVE) &&
            (item->flags & PAPERWM_INJECTOR_ANIMATION_AUTO_COMMIT) &&
            elapsed >= item->duration) {
            atomic_commit = true;
            break;
        }
    }
    if (atomic_commit) {
        if (!sls_disable_update || !sls_reenable_update) {
            return kCGErrorNotImplemented;
        }
        error = sls_disable_update(connection);
        if (error != kCGErrorSuccess) return error;
    }

    for (uint32_t index = 0; index < context->count; ++index) {
        paperwm_animation_runtime_item_t *runtime = &context->items[index];
        if (runtime->finished) continue;

        const paperwm_injector_animation_t *item = &runtime->value;
        double progress = elapsed / item->duration;
        if (progress <= 0.0) progress = 0.0;
        if (progress >= 1.0) progress = 1.0;
        double eased = ease_progress(item, progress);
        double x = interpolate(item->start_x, item->end_x, eased);
        double y = interpolate(item->start_y, item->end_y, eased);

        if (item->flags & PAPERWM_INJECTOR_ANIMATION_MOVE) {
            CGPoint point = CGPointMake(x, y);
            error = sls_move_window_with_group(
                connection, item->window_id, &point);
        } else if (progress >= 1.0 &&
                   (item->flags & PAPERWM_INJECTOR_ANIMATION_AUTO_COMMIT)) {
            CGPoint point = CGPointMake(item->end_x, item->end_y);
            error = sls_move_window_with_group(
                connection, item->window_id, &point);
            if (error == kCGErrorSuccess) {
                // The singular setter maps global screen coordinates back
                // into window-local pixels. Its neutral transform therefore
                // includes the negative real window origin; a literal affine
                // identity shifts the presentation by that origin.
                CGAffineTransform neutral = CGAffineTransformMake(
                    1.0,
                    0,
                    0,
                    1.0,
                    -item->end_x,
                    -item->end_y);
                error = sls_set_window_transform(
                    connection,
                    item->window_id,
                    neutral);
            }
        } else {
            double sx = interpolate(item->start_sx, item->end_sx, eased);
            double sy = interpolate(item->start_sy, item->end_sy, eased);
            if (fabs(sx) < 0.000001 || fabs(sy) < 0.000001) {
                return kCGErrorIllegalArgument;
            }
            CGAffineTransform singular = CGAffineTransformMake(
                1.0 / sx,
                0,
                0,
                1.0 / sy,
                -x / sx,
                -y / sy);
            error = sls_set_window_transform(
                connection, item->window_id, singular);
        }
        if (error != kCGErrorSuccess) break;
        if (progress >= 1.0) runtime->finished = true;
    }

    if (atomic_commit) {
        CGError enable_error = sls_reenable_update(connection);
        if (error == kCGErrorSuccess) error = enable_error;
    }

    return error;
}

static bool animation_finished(const paperwm_animation_context_t *context)
{
    for (uint32_t index = 0; index < context->count; ++index) {
        if (!context->items[index].finished) return false;
    }
    return true;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CVReturn animation_display_link_callback(
    CVDisplayLinkRef display_link,
    const CVTimeStamp *now,
    const CVTimeStamp *output_time,
    CVOptionFlags flags_in,
    CVOptionFlags *flags_out,
    void *context_pointer)
{
    (void)now;
    (void)flags_in;
    (void)flags_out;
    paperwm_animation_context_t *context = context_pointer;
    bool cancelled = false;
    bool finished = false;

    pthread_mutex_lock(&animation_lock);
    if (active_animation_generation != context->generation) {
        cancelled = true;
    } else {
        uint64_t current_clock = output_time->hostTime;
        if (!context->animation_clock) {
            context->animation_clock = now->hostTime;
            context->first_frame_clock = current_clock;
        }
        if (context->last_frame_clock) {
            uint64_t interval = current_clock - context->last_frame_clock;
            context->total_interval_clock += interval;
            if (interval > context->max_interval_clock) {
                context->max_interval_clock = interval;
            }
        }
        context->last_frame_clock = current_clock;
        context->frame_count += 1;
        context->error = apply_animation_frame(context, current_clock);
        finished = context->error != kCGErrorSuccess ||
            animation_finished(context);
        if (finished && active_animation_generation == context->generation) {
            active_animation_generation = 0;
        }
    }
    pthread_mutex_unlock(&animation_lock);

    if (cancelled || finished) {
        log_animation_result(context, cancelled ? "cancelled" :
            (context->error == kCGErrorSuccess ? "complete" : "error"));
        CVDisplayLinkStop(display_link);
        CVDisplayLinkRelease(display_link);
        free(context->items);
        free(context);
    }
    return kCVReturnSuccess;
}
#pragma clang diagnostic pop

static bool valid_animation_item(const paperwm_injector_animation_t *item)
{
    return item->window_id &&
        (item->flags & ~(PAPERWM_INJECTOR_ANIMATION_MOVE |
                         PAPERWM_INJECTOR_ANIMATION_AUTO_COMMIT)) == 0 &&
        isfinite(item->start_x) && isfinite(item->start_y) &&
        isfinite(item->end_x) && isfinite(item->end_y) &&
        isfinite(item->start_sx) && isfinite(item->start_sy) &&
        isfinite(item->end_sx) && isfinite(item->end_sy) &&
        fabs(item->start_sx) >= 0.000001 &&
        fabs(item->start_sy) >= 0.000001 &&
        fabs(item->end_sx) >= 0.000001 &&
        fabs(item->end_sy) >= 0.000001 &&
        isfinite(item->duration) && item->duration > 0.0 &&
        isfinite(item->curve_x1) && isfinite(item->curve_y1) &&
        isfinite(item->curve_x2) && isfinite(item->curve_y2) &&
        item->curve_x1 >= 0.0 && item->curve_x1 <= 1.0 &&
        item->curve_x2 >= 0.0 && item->curve_x2 <= 1.0;
}

static CGError perform_animations(const uint8_t *payload, size_t payload_size)
{
    uint32_t count = 0;
    const uint8_t *item_bytes = NULL;
    if (!parse_array(payload,
                     payload_size,
                     sizeof(paperwm_injector_animation_t),
                     &count,
                     &item_bytes)) {
        return kCGErrorIllegalArgument;
    }

    if (count == 0) {
        pthread_mutex_lock(&animation_lock);
        active_animation_generation = 0;
        pthread_mutex_unlock(&animation_lock);
        return kCGErrorSuccess;
    }

    paperwm_animation_context_t *context = calloc(1, sizeof(*context));
    paperwm_animation_runtime_item_t *items = calloc(count, sizeof(*items));
    if (!context || !items) {
        free(context);
        free(items);
        return kCGErrorFailure;
    }
    for (uint32_t index = 0; index < count; ++index) {
        memcpy(&items[index].value,
               item_bytes + (index * sizeof(items[index].value)),
               sizeof(items[index].value));
        if (!valid_animation_item(&items[index].value)) {
            free(items);
            free(context);
            return kCGErrorIllegalArgument;
        }
    }

    context->items = items;
    context->count = count;
    context->error = kCGErrorSuccess;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVReturn cv_error = CVDisplayLinkCreateWithActiveCGDisplays(
        &context->display_link);
    if (cv_error == kCVReturnSuccess) {
        cv_error = CVDisplayLinkSetOutputCallback(
            context->display_link,
            animation_display_link_callback,
            context);
    }
    if (cv_error != kCVReturnSuccess) {
        if (context->display_link) {
            CVDisplayLinkRelease(context->display_link);
        }
        free(items);
        free(context);
        return kCGErrorFailure;
    }

    pthread_mutex_lock(&animation_lock);
    context->generation = ++next_animation_generation;
    active_animation_generation = context->generation;
    pthread_mutex_unlock(&animation_lock);

    cv_error = CVDisplayLinkStart(context->display_link);
    if (cv_error != kCVReturnSuccess) {
        pthread_mutex_lock(&animation_lock);
        if (active_animation_generation == context->generation) {
            active_animation_generation = 0;
        }
        pthread_mutex_unlock(&animation_lock);
        CVDisplayLinkRelease(context->display_link);
        free(items);
        free(context);
        return kCGErrorFailure;
    }
#pragma clang diagnostic pop
    return kCGErrorSuccess;
}

static void log_interactive_result(
    const paperwm_interactive_context_t *context,
    const char *status)
{
    char path[128] = {0};
    int length = snprintf(path,
                          sizeof(path),
                          "/tmp/paperwm-payload-%u.log",
                          getuid());
    if (length < 0 || length >= (int)sizeof(path)) return;

    int fd = open(path,
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                  0600);
    if (fd < 0) return;

    double elapsed_ms = 0.0;
    double average_interval_ms = 0.0;
    double max_interval_ms = 0.0;
    if (cv_host_clock_frequency > 0.0 && context->callback_count > 1) {
        elapsed_ms = (double)(context->last_frame_clock -
                              context->first_frame_clock) *
            1000.0 / cv_host_clock_frequency;
        average_interval_ms =
            (double)context->total_interval_clock * 1000.0 /
            (cv_host_clock_frequency * (context->callback_count - 1));
        max_interval_ms = (double)context->max_interval_clock * 1000.0 /
            cv_host_clock_frequency;
    }
    double measured_fps = elapsed_ms > 0.0 ?
        (context->callback_count - 1) * 1000.0 / elapsed_ms : 0.0;

    dprintf(fd,
            "interactive_generation=%llu status=%s windows=%u callbacks=%u "
            "applied_frames=%u updates=%llu elapsed_ms=%.3f fps=%.3f "
            "interval_avg_ms=%.3f interval_max_ms=%.3f error=%d\n",
            context->generation,
            status,
            context->count,
            context->callback_count,
            context->applied_frames,
            context->update_sequence,
            elapsed_ms,
            measured_fps,
            average_interval_ms,
            max_interval_ms,
            context->error);
    close(fd);
}

static bool valid_move(const paperwm_injector_move_t *move)
{
    return move->window_id && isfinite(move->x) && isfinite(move->y);
}

static CGError update_interactive_targets_locked(
    paperwm_interactive_context_t *context,
    const uint8_t *item_bytes,
    uint32_t count)
{
    if (count != context->count) return kCGErrorIllegalArgument;

    for (uint32_t index = 0; index < count; ++index) {
        paperwm_injector_move_t move = {0};
        memcpy(&move,
               item_bytes + (index * sizeof(move)),
               sizeof(move));
        if (!valid_move(&move) ||
            move.window_id != context->targets[index].window_id) {
            return kCGErrorIllegalArgument;
        }
    }
    for (uint32_t index = 0; index < count; ++index) {
        paperwm_injector_move_t move = {0};
        memcpy(&move,
               item_bytes + (index * sizeof(move)),
               sizeof(move));
        context->targets[index].x = move.x;
        context->targets[index].y = move.y;
    }
    context->update_sequence += 1;
    return kCGErrorSuccess;
}

static CGError apply_interactive_frame(
    paperwm_interactive_context_t *context)
{
    SLSConnectionID connection = sls_main_connection_id();
    for (uint32_t index = 0; index < context->count; ++index) {
        const paperwm_injector_move_t *move = &context->targets[index];
        CGPoint point = CGPointMake(move->x, move->y);
        CGError error = sls_move_window_with_group(
            connection, move->window_id, &point);
        if (error != kCGErrorSuccess) return error;
    }
    context->applied_sequence = context->update_sequence;
    context->applied_frames += 1;
    return kCGErrorSuccess;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CVReturn interactive_display_link_callback(
    CVDisplayLinkRef display_link,
    const CVTimeStamp *now,
    const CVTimeStamp *output_time,
    CVOptionFlags flags_in,
    CVOptionFlags *flags_out,
    void *context_pointer)
{
    (void)now;
    (void)flags_in;
    (void)flags_out;
    paperwm_interactive_context_t *context = context_pointer;
    bool inactive = false;
    bool failed = false;

    pthread_mutex_lock(&interactive_lock);
    if (active_interactive_generation != context->generation) {
        inactive = true;
    } else {
        uint64_t current_clock = output_time->hostTime;
        if (!context->first_frame_clock) {
            context->first_frame_clock = current_clock;
        }
        if (context->last_frame_clock) {
            uint64_t interval = current_clock - context->last_frame_clock;
            context->total_interval_clock += interval;
            if (interval > context->max_interval_clock) {
                context->max_interval_clock = interval;
            }
        }
        context->last_frame_clock = current_clock;
        context->callback_count += 1;

        if (context->applied_sequence != context->update_sequence) {
            context->error = apply_interactive_frame(context);
            failed = context->error != kCGErrorSuccess;
            if (failed) {
                active_interactive_generation = 0;
                if (active_interactive_context == context) {
                    active_interactive_context = NULL;
                }
            }
        }
    }
    pthread_mutex_unlock(&interactive_lock);

    if (inactive || failed) {
        const char *status = failed ? "error" :
            (context->ended ?
                (context->error == kCGErrorSuccess ? "complete" : "error") :
                "cancelled");
        log_interactive_result(context, status);
        CVDisplayLinkStop(display_link);
        CVDisplayLinkRelease(display_link);
        free(context->targets);
        free(context);
    }
    return kCVReturnSuccess;
}
#pragma clang diagnostic pop

static CGError perform_interactive_begin(const uint8_t *payload,
                                         size_t payload_size)
{
    uint32_t count = 0;
    const uint8_t *item_bytes = NULL;
    if (!parse_array(payload,
                     payload_size,
                     sizeof(paperwm_injector_move_t),
                     &count,
                     &item_bytes) || count == 0) {
        return kCGErrorIllegalArgument;
    }

    paperwm_interactive_context_t *context = calloc(1, sizeof(*context));
    paperwm_injector_move_t *targets = calloc(count, sizeof(*targets));
    if (!context || !targets) {
        free(context);
        free(targets);
        return kCGErrorFailure;
    }
    for (uint32_t index = 0; index < count; ++index) {
        memcpy(&targets[index],
               item_bytes + (index * sizeof(targets[index])),
               sizeof(targets[index]));
        if (!valid_move(&targets[index])) {
            free(targets);
            free(context);
            return kCGErrorIllegalArgument;
        }
    }
    context->targets = targets;
    context->count = count;
    context->update_sequence = 1;
    context->error = kCGErrorSuccess;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CVReturn cv_error = CVDisplayLinkCreateWithActiveCGDisplays(
        &context->display_link);
    if (cv_error == kCVReturnSuccess) {
        cv_error = CVDisplayLinkSetOutputCallback(
            context->display_link,
            interactive_display_link_callback,
            context);
    }
    if (cv_error != kCVReturnSuccess) {
        if (context->display_link) {
            CVDisplayLinkRelease(context->display_link);
        }
        free(targets);
        free(context);
        return kCGErrorFailure;
    }

    pthread_mutex_lock(&interactive_lock);
    context->generation = ++next_interactive_generation;
    active_interactive_generation = context->generation;
    active_interactive_context = context;
    pthread_mutex_unlock(&interactive_lock);

    cv_error = CVDisplayLinkStart(context->display_link);
    if (cv_error != kCVReturnSuccess) {
        pthread_mutex_lock(&interactive_lock);
        if (active_interactive_generation == context->generation) {
            active_interactive_generation = 0;
            active_interactive_context = NULL;
        }
        pthread_mutex_unlock(&interactive_lock);
        CVDisplayLinkRelease(context->display_link);
        free(targets);
        free(context);
        return kCGErrorFailure;
    }
#pragma clang diagnostic pop
    return kCGErrorSuccess;
}

static CGError perform_interactive_update(const uint8_t *payload,
                                          size_t payload_size)
{
    uint32_t count = 0;
    const uint8_t *item_bytes = NULL;
    if (!parse_array(payload,
                     payload_size,
                     sizeof(paperwm_injector_move_t),
                     &count,
                     &item_bytes)) {
        return kCGErrorIllegalArgument;
    }

    pthread_mutex_lock(&interactive_lock);
    paperwm_interactive_context_t *context = active_interactive_context;
    CGError error = context ?
        update_interactive_targets_locked(context, item_bytes, count) :
        kCGErrorFailure;
    pthread_mutex_unlock(&interactive_lock);
    return error;
}

static CGError perform_interactive_end(const uint8_t *payload,
                                       size_t payload_size)
{
    uint32_t count = 0;
    const uint8_t *item_bytes = NULL;
    if (!parse_array(payload,
                     payload_size,
                     sizeof(paperwm_injector_move_t),
                     &count,
                     &item_bytes)) {
        return kCGErrorIllegalArgument;
    }

    pthread_mutex_lock(&interactive_lock);
    paperwm_interactive_context_t *context = active_interactive_context;
    if (!context) {
        pthread_mutex_unlock(&interactive_lock);
        return kCGErrorSuccess;
    }

    CGError error = count > 0 ?
        update_interactive_targets_locked(context, item_bytes, count) :
        kCGErrorSuccess;
    if (error == kCGErrorSuccess &&
        context->applied_sequence != context->update_sequence) {
        error = apply_interactive_frame(context);
    }
    context->error = error;
    context->ended = true;
    active_interactive_generation = 0;
    active_interactive_context = NULL;
    pthread_mutex_unlock(&interactive_lock);
    return error;
}

static CGError perform_transforms(const uint8_t *payload, size_t payload_size)
{
    uint32_t count = 0;
    const uint8_t *item_bytes = NULL;
    if (!parse_array(payload,
                     payload_size,
                     sizeof(paperwm_injector_transform_t),
                     &count,
                     &item_bytes)) {
        return kCGErrorIllegalArgument;
    }
    if (count == 0) return kCGErrorSuccess;

    paperwm_injector_transform_t *transforms =
        calloc(count, sizeof(*transforms));
    if (!transforms) {
        free(transforms);
        return kCGErrorFailure;
    }
    memcpy(transforms, item_bytes, count * sizeof(*transforms));

    SLSConnectionID connection = sls_main_connection_id();
    CGError error = kCGErrorSuccess;
    for (uint32_t index = 0; index < count; ++index) {
        paperwm_injector_transform_t item = transforms[index];
        if (!item.window_id || !isfinite(item.base_x) ||
            !isfinite(item.base_y) || !isfinite(item.sx) ||
            !isfinite(item.sy) ||
            !isfinite(item.tx) || !isfinite(item.ty) ||
            fabs(item.sx) < 0.000001 || fabs(item.sy) < 0.000001) {
            error = kCGErrorIllegalArgument;
            break;
        }

        CGFloat presented_x = (item.base_x * item.sx) + item.tx;
        CGFloat presented_y = (item.base_y * item.sy) + item.ty;
        CGAffineTransform singular = CGAffineTransformMake(
            1.0 / item.sx,
            0,
            0,
            1.0 / item.sy,
            -presented_x / item.sx,
            -presented_y / item.sy);

        error = sls_set_window_transform(
            connection, item.window_id, singular);
        if (error != kCGErrorSuccess) break;
    }

    free(transforms);
    return error;
}

static CGError perform_commit(const uint8_t *payload, size_t payload_size)
{
    uint32_t count = 0;
    const uint8_t *item_bytes = NULL;
    if (!parse_array(payload,
                     payload_size,
                     sizeof(paperwm_injector_commit_t),
                     &count,
                     &item_bytes)) {
        return kCGErrorIllegalArgument;
    }
    if (count == 0) return kCGErrorSuccess;
    if (!sls_disable_update || !sls_reenable_update) return kCGErrorNotImplemented;

    paperwm_injector_commit_t *items = calloc(count, sizeof(*items));
    CGRect *previous_bounds = calloc(count, sizeof(*previous_bounds));
    CGAffineTransform *previous_transforms =
        calloc(count, sizeof(*previous_transforms));
    if (!items || !previous_bounds || !previous_transforms) {
        free(items);
        free(previous_bounds);
        free(previous_transforms);
        return kCGErrorFailure;
    }
    memcpy(items, item_bytes, count * sizeof(*items));

    SLSConnectionID connection = sls_main_connection_id();
    CGError error = kCGErrorSuccess;
    for (uint32_t index = 0; index < count; ++index) {
        paperwm_injector_commit_t item = items[index];
        if (!item.window_id || !isfinite(item.x) || !isfinite(item.y) ||
            !isfinite(item.sx) || !isfinite(item.sy) ||
            !isfinite(item.tx) || !isfinite(item.ty) ||
            fabs(item.sx) < 0.000001 || fabs(item.sy) < 0.000001) {
            error = kCGErrorIllegalArgument;
            break;
        }
        error = sls_get_window_bounds(
            connection, item.window_id, &previous_bounds[index]);
        if (error != kCGErrorSuccess) break;
        error = sls_get_window_transform(
            connection, item.window_id, &previous_transforms[index]);
        if (error != kCGErrorSuccess) break;
    }

    bool updates_disabled = false;
    if (error == kCGErrorSuccess) {
        error = sls_disable_update(connection);
        updates_disabled = error == kCGErrorSuccess;
    }

    if (error == kCGErrorSuccess) {
        for (uint32_t index = 0; index < count; ++index) {
            CGPoint point = CGPointMake(items[index].x, items[index].y);
            error = sls_move_window_with_group(
                connection, items[index].window_id, &point);
            if (error != kCGErrorSuccess) break;
        }
    }

    if (error == kCGErrorSuccess) {
        for (uint32_t index = 0; index < count; ++index) {
            paperwm_injector_commit_t item = items[index];
            CGFloat presented_x = (item.x * item.sx) + item.tx;
            CGFloat presented_y = (item.y * item.sy) + item.ty;
            CGAffineTransform singular = CGAffineTransformMake(
                1.0 / item.sx,
                0,
                0,
                1.0 / item.sy,
                -presented_x / item.sx,
                -presented_y / item.sy);
            error = sls_set_window_transform(
                connection, item.window_id, singular);
            if (error != kCGErrorSuccess) break;

            CGAffineTransform readback = CGAffineTransformIdentity;
            error = sls_get_window_transform(
                connection, item.window_id, &readback);
            if (error != kCGErrorSuccess ||
                !transforms_equal(readback, singular)) {
                error = kCGErrorFailure;
                break;
            }
        }
    }

    if (error != kCGErrorSuccess && updates_disabled) {
        for (uint32_t index = 0; index < count; ++index) {
            CGPoint point = previous_bounds[index].origin;
            sls_move_window_with_group(
                connection, items[index].window_id, &point);
            sls_set_window_transform(
                connection, items[index].window_id, previous_transforms[index]);
        }
    }

    if (updates_disabled) {
        CGError enable_error = sls_reenable_update(connection);
        if (error == kCGErrorSuccess) error = enable_error;
    }

    free(previous_transforms);
    free(previous_bounds);
    free(items);
    return error;
}

static paperwm_injector_response_t handle_message(const uint8_t *message,
                                                   size_t message_size)
{
    if (message_size < sizeof(uint8_t)) {
        return response(PAPERWM_INJECTOR_STATUS_BAD_MESSAGE, EINVAL);
    }
    if (!load_skylight()) {
        return response(PAPERWM_INJECTOR_STATUS_UNSUPPORTED, ENOSYS);
    }

    uint8_t opcode = message[0];
    const uint8_t *payload = message + sizeof(opcode);
    size_t payload_size = message_size - sizeof(opcode);
    if (opcode == PAPERWM_INJECTOR_OP_HANDSHAKE) {
        return payload_size == 0 ?
            response(PAPERWM_INJECTOR_STATUS_OK, 0) :
            response(PAPERWM_INJECTOR_STATUS_BAD_MESSAGE, EINVAL);
    }

    CGError error = kCGErrorSuccess;
    switch (opcode) {
    case PAPERWM_INJECTOR_OP_MOVE:
        error = perform_moves(payload, payload_size);
        break;
    case PAPERWM_INJECTOR_OP_TRANSFORM:
        error = perform_transforms(payload, payload_size);
        break;
    case PAPERWM_INJECTOR_OP_COMMIT:
        error = perform_commit(payload, payload_size);
        break;
    case PAPERWM_INJECTOR_OP_ANIMATE:
        error = perform_animations(payload, payload_size);
        break;
    case PAPERWM_INJECTOR_OP_INTERACTIVE_BEGIN:
        error = perform_interactive_begin(payload, payload_size);
        break;
    case PAPERWM_INJECTOR_OP_INTERACTIVE_UPDATE:
        error = perform_interactive_update(payload, payload_size);
        break;
    case PAPERWM_INJECTOR_OP_INTERACTIVE_END:
        error = perform_interactive_end(payload, payload_size);
        break;
    default:
        return response(PAPERWM_INJECTOR_STATUS_UNSUPPORTED, ENOTSUP);
    }

    return error == kCGErrorSuccess ?
        response(PAPERWM_INJECTOR_STATUS_OK, 0) :
        response(PAPERWM_INJECTOR_STATUS_SKYLIGHT_ERROR, error);
}

static void handle_connection(int client_fd)
{
    uid_t peer_uid = (uid_t)-1;
    gid_t peer_gid = (gid_t)-1;
    if (getpeereid(client_fd, &peer_uid, &peer_gid) != 0 ||
        (peer_uid != getuid() && peer_uid != 0)) {
        return;
    }
    (void)peer_gid;

    uint16_t message_size = 0;
    if (!read_all(client_fd, &message_size, sizeof(message_size)) ||
        message_size == 0) {
        return;
    }

    uint8_t *message = malloc(message_size);
    if (!message) return;
    if (!read_all(client_fd, message, message_size)) {
        free(message);
        return;
    }

    paperwm_injector_response_t result =
        handle_message(message, message_size);
    free(message);
    write_all(client_fd, &result, sizeof(result));
}

static void *server_loop(void *context)
{
    (void)context;
    for (;;) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            break;
        }
        int no_sigpipe = 1;
        setsockopt(client_fd,
                   SOL_SOCKET,
                   SO_NOSIGPIPE,
                   &no_sigpipe,
                   sizeof(no_sigpipe));
        handle_connection(client_fd);
        shutdown(client_fd, SHUT_RDWR);
        close(client_fd);
    }
    return NULL;
}

__attribute__((constructor)) static void paperwm_payload_load(void)
{
    if (!load_skylight()) return;
    cv_host_clock_frequency = CVGetHostClockFrequency();
    if (cv_host_clock_frequency <= 0.0) return;

    int path_length = snprintf(socket_path,
                               sizeof(socket_path),
                               PAPERWM_INJECTOR_SOCKET_FMT,
                               getuid());
    if (path_length < 0 || path_length >= (int)sizeof(socket_path)) return;

    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) return;

    int no_sigpipe = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    unlink(socket_path);

    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, socket_path, sizeof(address.sun_path));
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        chmod(socket_path, 0600) != 0 || listen(server_fd, SOMAXCONN) != 0) {
        close(server_fd);
        server_fd = -1;
        unlink(socket_path);
        return;
    }

    pthread_t thread;
    if (pthread_create(&thread, NULL, server_loop, NULL) != 0) {
        close(server_fd);
        server_fd = -1;
        unlink(socket_path);
        return;
    }
    pthread_detach(thread);
}

__attribute__((destructor)) static void paperwm_payload_unload(void)
{
    pthread_mutex_lock(&animation_lock);
    active_animation_generation = 0;
    pthread_mutex_unlock(&animation_lock);
    if (server_fd >= 0) {
        shutdown(server_fd, SHUT_RDWR);
        close(server_fd);
        server_fd = -1;
    }
    if (socket_path[0]) unlink(socket_path);
    if (skylight_handle) {
        dlclose(skylight_handle);
        skylight_handle = NULL;
    }
}
