#include "ax_service.h"
#include "ax_protocol.h"
#include "client.h"

#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);

typedef int SLSConnectionID;
typedef SLSConnectionID (*SLSMainConnectionIDFn)(void);
typedef CGError (*SLSUpdateFn)(SLSConnectionID);

static int server_fd = -1;
static char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static pthread_t server_thread;

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

static AXUIElementRef find_window(pid_t pid, CGWindowID window_id,
                                  float timeout, AXError *error)
{
    AXUIElementRef application = AXUIElementCreateApplication(pid);
    if (!application) {
        *error = kAXErrorFailure;
        return NULL;
    }
    AXUIElementSetMessagingTimeout(application, timeout);
    CFTypeRef value = NULL;
    *error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute,
                                           &value);
    AXUIElementRef found = NULL;
    if (*error == kAXErrorSuccess && value &&
        CFGetTypeID(value) == CFArrayGetTypeID()) {
        CFArrayRef windows = (CFArrayRef)value;
        for (CFIndex index = 0; index < CFArrayGetCount(windows); ++index) {
            AXUIElementRef candidate = (AXUIElementRef)CFArrayGetValueAtIndex(
                windows, index);
            CGWindowID candidate_id = 0;
            if (_AXUIElementGetWindow(candidate, &candidate_id) ==
                    kAXErrorSuccess && candidate_id == window_id) {
                found = CFRetain(candidate);
                break;
            }
        }
    }
    if (value) CFRelease(value);
    CFRelease(application);
    return found;
}

static void respond_error(paperwm_ax_response_t *response, int status,
                          const char *message)
{
    response->status = status;
    snprintf(response->error, sizeof(response->error), "%s", message);
}

static paperwm_ax_response_t prepare_resize(const paperwm_ax_request_t *request)
{
    paperwm_ax_response_t response = {
        .magic = PAPERWM_AX_MAGIC,
        .version = PAPERWM_AX_VERSION,
    };
    if (request->magic != PAPERWM_AX_MAGIC ||
        request->version != PAPERWM_AX_VERSION ||
        request->window_id == 0 || request->pid <= 0 ||
        !isfinite(request->timeout) || request->timeout < 0.05 ||
        request->timeout > 1.0 ||
        !isfinite(request->start_x) || !isfinite(request->start_y) ||
        !isfinite(request->start_w) || !isfinite(request->start_h) ||
        !isfinite(request->end_x) || !isfinite(request->end_y) ||
        !isfinite(request->end_w) || !isfinite(request->end_h) ||
        request->start_w <= 0 || request->start_h <= 0 ||
        request->end_w <= 0 || request->end_h <= 0) {
        respond_error(&response, 1, "invalid AX resize request");
        return response;
    }
    if (!AXIsProcessTrusted()) {
        respond_error(&response, 2,
                      "paperwm-injector needs Accessibility permission");
        return response;
    }

    void *skylight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY | RTLD_LOCAL);
    SLSMainConnectionIDFn main_connection = skylight ?
        (SLSMainConnectionIDFn)dlsym(skylight, "CGSMainConnectionID") : NULL;
    SLSUpdateFn disable_update = skylight ?
        (SLSUpdateFn)dlsym(skylight, "CGSDisableUpdate") : NULL;
    SLSUpdateFn enable_update = skylight ?
        (SLSUpdateFn)dlsym(skylight, "CGSReenableUpdate") : NULL;
    if (!main_connection || !disable_update || !enable_update) {
        if (skylight) dlclose(skylight);
        respond_error(&response, 3, "WindowServer update lock unavailable");
        return response;
    }

    AXError lookup_error = kAXErrorSuccess;
    AXUIElementRef window = find_window(request->pid, request->window_id,
                                         (float)request->timeout,
                                         &lookup_error);
    if (!window) {
        dlclose(skylight);
        char message[120];
        snprintf(message, sizeof(message), "AX window %u not found: %d",
                 request->window_id, lookup_error);
        respond_error(&response, 4, message);
        return response;
    }
    AXUIElementSetMessagingTimeout(window, (float)request->timeout);

    AXUIElementRef application = AXUIElementCreateApplication(request->pid);
    AXUIElementSetMessagingTimeout(application, (float)request->timeout);
    CFTypeRef enhanced = NULL;
    bool restore_enhanced = AXUIElementCopyAttributeValue(
        application, CFSTR("AXEnhancedUserInterface"), &enhanced) ==
            kAXErrorSuccess && enhanced == kCFBooleanTrue;
    if (restore_enhanced) {
        restore_enhanced = AXUIElementSetAttributeValue(
            application, CFSTR("AXEnhancedUserInterface"), kCFBooleanFalse) ==
            kAXErrorSuccess;
    }
    if (enhanced) CFRelease(enhanced);

    SLSConnectionID connection = main_connection();
    CGError lock_error = disable_update(connection);
    if (lock_error != kCGErrorSuccess) {
        if (restore_enhanced) AXUIElementSetAttributeValue(
            application, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
        CFRelease(application);
        CFRelease(window);
        dlclose(skylight);
        respond_error(&response, 5, "could not suspend WindowServer updates");
        return response;
    }

    CGPoint position = CGPointMake(request->end_x, request->end_y);
    CGSize size = CGSizeMake(request->end_w, request->end_h);
    AXValueRef position_value = AXValueCreate(kAXValueCGPointType, &position);
    AXValueRef size_value = AXValueCreate(kAXValueCGSizeType, &size);
    AXError position_error = position_value ? AXUIElementSetAttributeValue(
        window, kAXPositionAttribute, position_value) : kAXErrorFailure;
    AXError size_error = position_error == kAXErrorSuccess && size_value ?
        AXUIElementSetAttributeValue(window, kAXSizeAttribute, size_value) :
        kAXErrorFailure;
    if (position_value) CFRelease(position_value);
    if (size_value) CFRelease(size_value);

    CFTypeRef readback = NULL;
    AXError read_error = size_error == kAXErrorSuccess ?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &readback) :
        kAXErrorFailure;
    CGSize accepted = CGSizeZero;
    bool valid_size = read_error == kAXErrorSuccess && readback &&
        CFGetTypeID(readback) == AXValueGetTypeID() &&
        AXValueGetType((AXValueRef)readback) == kAXValueCGSizeType &&
        AXValueGetValue((AXValueRef)readback, kAXValueCGSizeType, &accepted) &&
        accepted.width > 0 && accepted.height > 0;
    if (readback) CFRelease(readback);

    if (valid_size) {
        paperwm_injector_transform_t transform = {
            .window_id = request->window_id,
            .base_x = request->end_x,
            .base_y = request->end_y,
            .sx = request->start_w / accepted.width,
            .sy = request->start_h / accepted.height,
            .tx = request->start_x -
                request->end_x * request->start_w / accepted.width,
            .ty = request->start_y -
                request->end_y * request->start_h / accepted.height,
        };
        char transform_error[256] = {0};
        response.concealed = paperwm_injector_transform(
            getuid(), &transform, 1, NULL, transform_error,
            sizeof(transform_error));
        if (!response.concealed) {
            snprintf(response.error, sizeof(response.error),
                     "compositor concealment failed: %.125s", transform_error);
        }
        response.accepted_w = accepted.width;
        response.accepted_h = accepted.height;
    } else {
        // Restore the original frame before releasing the update lock when
        // the owning app rejects the requested size.
        CGPoint original_position = CGPointMake(request->start_x,
                                                 request->start_y);
        CGSize original_size = CGSizeMake(request->start_w, request->start_h);
        AXValueRef old_position = AXValueCreate(kAXValueCGPointType,
                                                &original_position);
        AXValueRef old_size = AXValueCreate(kAXValueCGSizeType, &original_size);
        if (old_size) AXUIElementSetAttributeValue(
            window, kAXSizeAttribute, old_size);
        if (old_position) AXUIElementSetAttributeValue(
            window, kAXPositionAttribute, old_position);
        if (old_size) CFRelease(old_size);
        if (old_position) CFRelease(old_position);
        char message[120];
        snprintf(message, sizeof(message),
                 "AX resize failed: position=%d size=%d read=%d",
                 position_error, size_error, read_error);
        respond_error(&response, 6, message);
    }

    enable_update(connection);
    if (restore_enhanced) AXUIElementSetAttributeValue(
        application, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
    CFRelease(application);
    CFRelease(window);
    dlclose(skylight);
    return response;
}

static void *serve_requests(void *unused)
{
    (void)unused;
    for (;;) {
        int client = accept(server_fd, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        int no_sigpipe = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe,
                   sizeof(no_sigpipe));
        struct timeval timeout = { .tv_sec = 1, .tv_usec = 500000 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   sizeof(timeout));
        uid_t peer_uid = (uid_t)-1;
        gid_t peer_gid = (gid_t)-1;
        if (getpeereid(client, &peer_uid, &peer_gid) == 0 &&
            peer_uid == getuid()) {
            (void)peer_gid;
            paperwm_ax_request_t request = {0};
            if (transfer_all(client, &request, sizeof(request), false)) {
                paperwm_ax_response_t response = prepare_resize(&request);
                transfer_all(client, &response, sizeof(response), true);
            }
        }
        close(client);
    }
    return NULL;
}

bool paperwm_ax_service_start(void)
{
    if (server_fd >= 0) return true;
    int length = snprintf(socket_path, sizeof(socket_path),
                          PAPERWM_AX_SOCKET_FMT, getuid());
    if (length < 0 || length >= (int)sizeof(socket_path)) return false;
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) return false;
    unlink(socket_path);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, socket_path, sizeof(address.sun_path));
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        chmod(socket_path, 0600) != 0 || listen(server_fd, 8) != 0 ||
        pthread_create(&server_thread, NULL, serve_requests, NULL) != 0) {
        close(server_fd);
        server_fd = -1;
        unlink(socket_path);
        return false;
    }
    return true;
}

void paperwm_ax_service_stop(void)
{
    if (server_fd < 0) return;
    shutdown(server_fd, SHUT_RDWR);
    close(server_fd);
    server_fd = -1;
    pthread_join(server_thread, NULL);
    unlink(socket_path);
}
