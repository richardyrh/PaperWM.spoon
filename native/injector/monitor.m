#import <AppKit/AppKit.h>

#include "client.h"

#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const char *loader_path =
    "/Library/ScriptingAdditions/PaperWM.osax/Contents/MacOS/loader";
static volatile sig_atomic_t monitor_running = 1;

static void stop_monitor(int signal_number)
{
    (void)signal_number;
    monitor_running = 0;
}

static pid_t dock_pid(void)
{
    NSArray<NSRunningApplication *> *applications =
        [NSRunningApplication
            runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    for (NSRunningApplication *application in applications) {
        if (!application.terminated && application.finishedLaunching) {
            return application.processIdentifier;
        }
    }
    return 0;
}

static bool executable_path(char path[PATH_MAX])
{
    uint32_t size = PATH_MAX;
    if (_NSGetExecutablePath(path, &size) != 0) return false;

    char resolved[PATH_MAX] = {0};
    if (!realpath(path, resolved)) return false;
    strlcpy(path, resolved, PATH_MAX);
    return true;
}

static bool wait_for_process(pid_t pid, int *exit_status)
{
    int status = 0;
    pid_t result;
    do {
        result = waitpid(pid, &status, 0);
    } while (result < 0 && errno == EINTR);
    if (result < 0) return false;

    if (WIFEXITED(status)) {
        if (exit_status) *exit_status = WEXITSTATUS(status);
        return true;
    }
    if (exit_status) *exit_status = 128;
    return true;
}

static int run_program(const char *path, char *const arguments[])
{
    pid_t pid = 0;
    int spawn_error = posix_spawn(&pid, path, NULL, NULL, arguments, environ);
    if (spawn_error != 0) {
        fprintf(stderr, "could not launch %s: %s\n", path, strerror(spawn_error));
        return 1;
    }

    int exit_status = 1;
    if (!wait_for_process(pid, &exit_status)) {
        fprintf(stderr, "could not wait for %s: %s\n", path, strerror(errno));
        return 1;
    }
    return exit_status;
}

static bool parse_uid(const char *value, uid_t *uid)
{
    if (!value || !*value) return false;

    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed > UINT_MAX) return false;
    *uid = (uid_t)parsed;
    return true;
}

static bool payload_ready(uid_t uid,
                          paperwm_injector_response_t *response,
                          char *error,
                          size_t error_size)
{
    paperwm_injector_response_t local = {0};
    if (!paperwm_injector_handshake(
            uid, &local, error, error_size)) {
        return false;
    }
    uint32_t required = PAPERWM_INJECTOR_CAP_MOVE |
                        PAPERWM_INJECTOR_CAP_TRANSFORM |
                        PAPERWM_INJECTOR_CAP_COMMIT |
                        PAPERWM_INJECTOR_CAP_ANIMATE |
                        PAPERWM_INJECTOR_CAP_INTERACTIVE;
    if ((local.capabilities & required) != required) {
        snprintf(error,
                 error_size,
                 "payload is missing capabilities: received=0x%x required=0x%x",
                 local.capabilities,
                 required);
        return false;
    }
    if (response) *response = local;
    return true;
}

static int inject_payload(void)
{
    if (geteuid() != 0) {
        fprintf(stderr, "--inject must run as root through the installed sudoers rule\n");
        return 1;
    }

    uid_t target_uid = 0;
    if (!parse_uid(getenv("SUDO_UID"), &target_uid) || target_uid == 0) {
        fprintf(stderr, "--inject requires SUDO_UID for the target GUI session\n");
        return 1;
    }

    char *arguments[] = { (char *)loader_path, NULL };
    int loader_status = run_program(loader_path, arguments);
    if (loader_status != 0) {
        fprintf(stderr, "Dock loader exited with status %d\n", loader_status);
        return loader_status;
    }

    char error[256] = {0};
    paperwm_injector_response_t response = {0};
    for (int attempt = 0; attempt < 40; ++attempt) {
        if (payload_ready(target_uid, &response, error, sizeof(error))) {
            printf("PaperWM payload %s active for uid %u (capabilities=0x%x)\n",
                   response.payload_version,
                   target_uid,
                   response.capabilities);
            return 0;
        }
        usleep(50000);
    }

    fprintf(stderr, "payload did not become ready: %s\n", error);
    return 1;
}

static int request_privileged_injection(const char *self_path)
{
    char *arguments[] = {
        "/usr/bin/sudo",
        "-n",
        (char *)self_path,
        "--inject",
        NULL,
    };
    return run_program(arguments[0], arguments);
}

static int monitor_payload(void)
{
    if (geteuid() == 0) {
        fprintf(stderr, "--monitor must run in the logged-in user's launchd session\n");
        return 1;
    }

    char self_path[PATH_MAX] = {0};
    if (!executable_path(self_path)) {
        fprintf(stderr, "could not resolve injector executable path\n");
        return 1;
    }

    signal(SIGTERM, stop_monitor);
    signal(SIGINT, stop_monitor);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);

    uid_t uid = getuid();
    pid_t active_dock_pid = 0;
    unsigned int ticks = 0;
    while (monitor_running) {
        @autoreleasepool {
            pid_t current_dock_pid = dock_pid();
            bool should_check = current_dock_pid != 0 &&
                (current_dock_pid != active_dock_pid || ticks % 8 == 0);
            if (should_check) {
                char error[256] = {0};
                paperwm_injector_response_t response = {0};
                if (payload_ready(uid, &response, error, sizeof(error))) {
                    if (active_dock_pid != current_dock_pid) {
                        printf("payload %s active in Dock pid %d\n",
                               response.payload_version,
                               current_dock_pid);
                    }
                    active_dock_pid = current_dock_pid;
                } else {
                    fprintf(stderr,
                            "payload unavailable for Dock pid %d: %s; reinjecting\n",
                            current_dock_pid,
                            error);
                    int status = request_privileged_injection(self_path);
                    if (status == 0) {
                        active_dock_pid = current_dock_pid;
                    } else {
                        active_dock_pid = 0;
                        fprintf(stderr,
                                "automatic injection failed with status %d; retrying\n",
                                status);
                    }
                }
            } else if (current_dock_pid == 0) {
                active_dock_pid = 0;
            }
        }

        ++ticks;
        for (int slice = 0; slice < 4 && monitor_running; ++slice) {
            usleep(250000);
        }
    }
    return 0;
}

static int print_status(void)
{
    char error[256] = {0};
    paperwm_injector_response_t response = {0};
    if (!payload_ready(getuid(), &response, error, sizeof(error))) {
        fprintf(stderr, "PaperWM payload unavailable: %s\n", error);
        return 1;
    }

    printf("payload_version=%s protocol=%u capabilities=0x%x dock_pid=%d\n",
           response.payload_version,
           response.protocol_version,
           response.capabilities,
           dock_pid());
    return 0;
}

static void usage(const char *program)
{
    fprintf(stderr, "usage: %s --monitor | --inject | --status\n", program);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) {
            usage(argv[0]);
            return 2;
        }
        if (strcmp(argv[1], "--monitor") == 0) return monitor_payload();
        if (strcmp(argv[1], "--inject") == 0) return inject_payload();
        if (strcmp(argv[1], "--status") == 0) return print_status();
        usage(argv[0]);
        return 2;
    }
}
