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

static void insert(ouro_auth *a, uint64_t id, const uint32_t *s, size_t n) {
    for (size_t i = 0; i < n; i++)
        assert(ouro_auth_edit(a, id, OURO_AUTH_INSERT, s[i]) == 1);
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
    assert(ouro_auth_edit(a, 0, OURO_AUTH_INSERT, 'x') == 0);
    assert(ouro_auth_clear_input(a, 0) == 0);
    assert(ouro_auth_submit(a, 0) == 0);
    ouro_auth_launch(a);
    return a;
}

static void ordinary(const char *service, int correct, int success) {
    ouro_auth *a = start(service);
    uint64_t first = prompt(a, 1);
    assert(ouro_auth_edit(a, 0, OURO_AUTH_INSERT, 'x') == 0);
    assert(ouro_auth_edit(a, first + 1, OURO_AUTH_INSERT, 'x') == 0);
    assert(ouro_auth_edit(a, first, OURO_AUTH_INSERT, 0) == 0);
    assert(ouro_auth_edit(a, first, OURO_AUTH_INSERT, 0xd800) == 0);
    assert(ouro_auth_edit(a, first, OURO_AUTH_INSERT, 0x110000) == 0);
    const uint32_t alice[] = {'a', 'l', 'i', 'c', 'e'};
    assert(ouro_auth_edit(a, first, OURO_AUTH_INSERT, 'x') == 1);
    assert(ouro_auth_clear_input(a, first) == 1);
    assert(!ouro_auth_has_input(a, first));
    insert(a, first, alice, sizeof alice / sizeof *alice);
    assert(ouro_auth_submit(a, first) == 1);
    assert(ouro_auth_submit(a, first) == 0);
    uint64_t second = prompt(a, 0);
    assert(ouro_auth_clear_input(a, first) == 0);
    const uint32_t good[] = {'t', 'e', 's', 't', '-', 'o', 'n', 'l', 'y',
                             '-', 'r', 'e', 's', 'p', 'o', 'n', 's', 'e'};
    const uint32_t bad[] = {'w', 'r', 'o', 'n', 'g'};
    insert(a, second, correct ? good : bad, correct ? sizeof good / 4 : sizeof bad / 4);
    assert(ouro_auth_submit(a, second) == 1);
    finish(a, success, success ? OURO_AUTH_SUCCESS : OURO_AUTH_DENIED);
}

static void edited(void) {
    ouro_auth *a = start("edited");
    uint64_t id = prompt(a, 1);
    const uint32_t initial[] = {0xe9, 0x1f642, 'Q'};
    insert(a, id, initial, 3);
    assert(ouro_auth_edit(a, id, OURO_AUTH_HOME, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_INSERT, 'X') == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_DELETE, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_BACKSPACE, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_HOME, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_INSERT, 'A') == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_END, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_BACKSPACE, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_INSERT, 'Z') == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_HOME, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_RIGHT, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_INSERT, 0xe9) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_END, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_LEFT, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_DELETE, 0) == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_INSERT, 'Z') == 1);
    assert(ouro_auth_submit(a, id) == 1);
    id = prompt(a, 0);
    const uint32_t wrong[] = {'n', 'o'}, pass[] = {'p', 0xe4, 's', 's', 0x1f512};
    insert(a, id, wrong, 2);
    assert(ouro_auth_edit(a, id, OURO_AUTH_SELECT_ALL, 0) == 1);
    assert(ouro_auth_has_input(a, id)); // selection must not prematurely erase
    insert(a, id, pass, 5);
    assert(ouro_auth_submit(a, id) == 1);
    finish(a, 1, OURO_AUTH_SUCCESS);
}

static void limit(void) {
    ouro_auth *a = start("limit");
    uint64_t id = prompt(a, 1);
    for (int i = 0; i < 512; i++)
        assert(ouro_auth_edit(a, id, OURO_AUTH_INSERT, 'x') == 1);
    assert(ouro_auth_edit(a, id, OURO_AUTH_INSERT, 'x') == -1);
    assert(ouro_auth_submit(a, id) == 1);
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
    edited();
    limit();
    ouro_auth *crash = start("crash");
    finish(crash, 0, OURO_AUTH_WORKER_FAILED);
    cancel_blocked();
    for (int i = 0; i < 4; i++)
        ordinary("fixture", 1, 1);
    puts("PASS native auth editing, PAM outcomes, crashes, cancellation and child reaping");
    return 0;
}
