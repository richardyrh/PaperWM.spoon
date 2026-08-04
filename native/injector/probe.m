#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#include "client.h"

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>

static bool window_bounds(CGWindowID window_id, CGRect *bounds)
{
    CFArrayRef descriptions = CGWindowListCopyWindowInfo(
        kCGWindowListOptionIncludingWindow, window_id);
    if (!descriptions || CFArrayGetCount(descriptions) == 0) {
        if (descriptions) CFRelease(descriptions);
        return false;
    }

    CFDictionaryRef description = CFArrayGetValueAtIndex(descriptions, 0);
    CFDictionaryRef dictionary = CFDictionaryGetValue(
        description, kCGWindowBounds);
    bool result = dictionary &&
        CGRectMakeWithDictionaryRepresentation(dictionary, bounds);
    CFRelease(descriptions);
    return result;
}

static void settle(void)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.12];
    while (until.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(160, 160, 64, 40)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.backgroundColor = [NSColor colorWithCalibratedWhite:0.2 alpha:1.0];
        window.alphaValue = 0.08;
        window.ignoresMouseEvents = YES;
        window.releasedWhenClosed = NO;
        [window orderFrontRegardless];
        settle();

        CGWindowID window_id = (CGWindowID)window.windowNumber;
        CGRect original = CGRectZero;
        if (!window_id || !window_bounds(window_id, &original)) {
            fprintf(stderr, "could not read disposable window bounds\n");
            [window close];
            return 1;
        }

        int original_x = (int)llround(CGRectGetMinX(original));
        int original_y = (int)llround(CGRectGetMinY(original));
        paperwm_injector_move_t move = {
            .window_id = window_id,
            .x = original_x + 17,
            .y = original_y + 11,
        };
        char error[256] = {0};
        bool move_sent = paperwm_injector_move(
            getuid(), &move, 1, NULL, error, sizeof(error));
        settle();

        CGRect moved = CGRectZero;
        bool move_verified = move_sent && window_bounds(window_id, &moved) &&
            (int)llround(CGRectGetMinX(moved)) == (int)move.x &&
            (int)llround(CGRectGetMinY(moved)) == (int)move.y;

        paperwm_injector_animation_t animation = {
            .window_id = window_id,
            .flags = PAPERWM_INJECTOR_ANIMATION_AUTO_COMMIT,
            .start_x = move.x,
            .start_y = move.y,
            .end_x = move.x + 23,
            .end_y = move.y + 7,
            .start_sx = 1.0,
            .start_sy = 1.0,
            .end_sx = 1.0,
            .end_sy = 1.0,
            .duration = 0.08,
            .curve_x1 = 0.2,
            .curve_y1 = 0.0,
            .curve_x2 = 0.0,
            .curve_y2 = 1.0,
        };
        bool animation_sent = paperwm_injector_animate(
            getuid(), &animation, 1, NULL, error, sizeof(error));
        settle();
        CGRect animated = CGRectZero;
        bool animation_verified = animation_sent &&
            window_bounds(window_id, &animated) &&
            (int)llround(CGRectGetMinX(animated)) == (int)animation.end_x &&
            (int)llround(CGRectGetMinY(animated)) == (int)animation.end_y;

        paperwm_injector_move_t interactive = {
            .window_id = window_id,
            .x = animation.end_x,
            .y = animation.end_y,
        };
        bool interactive_sent = paperwm_injector_interactive_begin(
            getuid(), &interactive, 1, NULL, error, sizeof(error));
        interactive.x += 13;
        interactive.y += 5;
        interactive_sent = interactive_sent &&
            paperwm_injector_interactive_update(
                getuid(), &interactive, 1, NULL, error, sizeof(error));
        settle();
        interactive_sent = interactive_sent &&
            paperwm_injector_interactive_end(
                getuid(), &interactive, 1, NULL, error, sizeof(error));
        settle();
        CGRect interacted = CGRectZero;
        bool interactive_verified = interactive_sent &&
            window_bounds(window_id, &interacted) &&
            (int)llround(CGRectGetMinX(interacted)) == (int)interactive.x &&
            (int)llround(CGRectGetMinY(interacted)) == (int)interactive.y;

        paperwm_injector_transform_t transform = {
            .window_id = window_id,
            .base_x = interactive.x,
            .base_y = interactive.y,
            .sx = 0.97,
            .sy = 0.96,
            .tx = interactive.x - (interactive.x * 0.97),
            .ty = interactive.y - (interactive.y * 0.96),
        };
        bool transform_verified = paperwm_injector_transform(
            getuid(), &transform, 1, NULL, error, sizeof(error));
        settle();

        paperwm_injector_commit_t restore = {
            .window_id = window_id,
            .x = original_x,
            .y = original_y,
            .sx = 1.0,
            .sy = 1.0,
            .tx = 0.0,
            .ty = 0.0,
        };
        bool restore_sent = paperwm_injector_commit(
            getuid(), &restore, 1, NULL, error, sizeof(error));
        settle();

        CGRect restored = CGRectZero;
        bool restore_verified = restore_sent &&
            window_bounds(window_id, &restored) &&
            (int)llround(CGRectGetMinX(restored)) == original_x &&
            (int)llround(CGRectGetMinY(restored)) == original_y;

        printf("window_id=%u move=%s display_animation=%s interactive=%s transform=%s atomic_restore=%s "
               "original=(%d,%d) moved=(%.0f,%.0f) "
               "restored=(%.0f,%.0f)\n",
               window_id,
               move_verified ? "ok" : "failed",
               animation_verified ? "ok" : "failed",
               interactive_verified ? "ok" : "failed",
               transform_verified ? "ok" : "failed",
               restore_verified ? "ok" : "failed",
               original_x,
               original_y,
               CGRectGetMinX(moved),
               CGRectGetMinY(moved),
               CGRectGetMinX(restored),
               CGRectGetMinY(restored));
        if ((!move_verified || !animation_verified || !interactive_verified ||
             !transform_verified || !restore_verified) &&
            error[0]) {
            fprintf(stderr, "payload probe error: %s\n", error);
        }

        [window close];
        return move_verified && animation_verified && interactive_verified &&
            transform_verified && restore_verified ?
            0 : 1;
    }
}
