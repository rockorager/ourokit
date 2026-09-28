#define _GNU_SOURCE
#include "auth.h"

#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int64_t milliseconds(void) {
    struct timespec t;
    assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static struct ouro_auth_event event(ouro_auth *a) {
    struct ouro_auth_event e;
    for (;;) {
        if (ouro_auth_pop(a, &e))
            return e;
        struct pollfd p = {ouro_auth_fd(a), POLLIN, 0};
        assert(poll(&p, 1, 3000) > 0);
        char byte;
        assert(read(ouro_auth_fd(a), &byte, 1) == 1);
    }
}

static uint64_t prompt(ouro_auth *a, int echo) {
    struct ouro_auth_event e;
    do
        e = event(a);
    while (e.kind == OURO_AUTH_INFO || e.kind == OURO_AUTH_ERROR);
    assert(e.kind == OURO_AUTH_PROMPT && e.echo == echo && e.prompt_id != 0);
    return e.prompt_id;
}

static int respond(ouro_auth *a, uint64_t id, const char *text) {
    return ouro_auth_respond(a, id, (const unsigned char *)text, strlen(text));
}

static void finish(ouro_auth *a, int success, int reason) {
    struct ouro_auth_event e = event(a);
    assert(e.kind == OURO_AUTH_RESULT && e.success == success);
    assert(ouro_auth_done(a) && ouro_auth_reason(a) == reason);
    ouro_auth_join_destroy(a);
    errno = 0;
    assert(waitpid(-1, NULL, WNOHANG) == -1 && errno == ECHILD);
}

static ouro_auth *start(const char *service) {
    ouro_auth *a = ouro_auth_start(service, "fixture-user");
    assert(a);
    assert(respond(a, 0, "x") == 0);
    ouro_auth_launch(a);
    return a;
}

static void ordinary(const char *service, int correct, int success) {
    ouro_auth *a = start(service);
    uint64_t first = prompt(a, 1);
    assert(respond(a, 0, "alice") == 0);
    assert(respond(a, first + 1, "alice") == 0);
    assert(ouro_auth_respond(a, first, NULL, 5) == 0);
    assert(respond(a, first, "alice") == 1);
    assert(respond(a, first, "alice") == 0);
    uint64_t second = prompt(a, 0);
    assert(respond(a, first, "alice") == 0);
    assert(respond(a, second, correct ? "test-only-response" : "wrong") == 1);
    finish(a, success, success ? OURO_AUTH_SUCCESS : OURO_AUTH_DENIED);
}

static void utf8(void) {
    ouro_auth *a = start("edited");
    uint64_t id = prompt(a, 1);
    assert(respond(a, id, "A\xc3\xa9\xf0\x9f\x99\x82Z") == 1);
    id = prompt(a, 0);
    assert(respond(a, id, "p\xc3\xa4ss\xf0\x9f\x94\x92") == 1);
    finish(a, 1, OURO_AUTH_SUCCESS);
}

static void limit(void) {
    ouro_auth *a = start("limit");
    uint64_t id = prompt(a, 1);
    char text[514];
    memset(text, 'x', sizeof text - 1);
    text[513] = 0;
    assert(respond(a, id, text) == 0); // 513 bytes exceed the PAM response limit
    text[512] = 0;
    assert(respond(a, id, text) == 1);
    finish(a, 1, OURO_AUTH_SUCCESS);
}

static void cancel_blocked(void) {
    ouro_auth *a = start("blocked");
    usleep(100000);
    int64_t then = milliseconds();
    ouro_auth_cancel(a);
    struct ouro_auth_event e = event(a);
    assert(e.kind == OURO_AUTH_RESULT && !e.success);
    assert(ouro_auth_reason(a) == OURO_AUTH_CANCELED);
    ouro_auth_join_destroy(a);
    assert(milliseconds() - then < 2000);
    errno = 0;
    assert(waitpid(-1, NULL, WNOHANG) == -1 && errno == ECHILD);
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--ourokit-auth-worker"))
        return ouro_auth_worker_main();
    ordinary("fixture", 1, 1);
    ordinary("fixture", 0, 0);
    ordinary("deny-account", 1, 0);
    ordinary("end-failed", 1, 0);
    utf8();
    limit();
    ouro_auth *crash = start("crash");
    finish(crash, 0, OURO_AUTH_WORKER_FAILED);
    cancel_blocked();
    for (int i = 0; i < 4; i++)
        ordinary("fixture", 1, 1);
    puts("PASS native auth responses, PAM outcomes, crashes, cancellation and child reaping");
    return 0;
}
