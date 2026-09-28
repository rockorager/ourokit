#ifndef OURO_LUA_AUTH_H
#define OURO_LUA_AUTH_H

#include <stddef.h>
#include <stdint.h>

typedef struct ouro_auth ouro_auth;
enum ouro_auth_kind { OURO_AUTH_PROMPT = 1, OURO_AUTH_INFO, OURO_AUTH_ERROR, OURO_AUTH_RESULT };
enum ouro_auth_reason {
    OURO_AUTH_SUCCESS = 0,
    OURO_AUTH_DENIED,
    OURO_AUTH_UNAVAILABLE,
    OURO_AUTH_CANCELED,
    OURO_AUTH_TIMEOUT,
    OURO_AUTH_WORKER_FAILED
};
struct ouro_auth_event {
    int kind;
    uint64_t prompt_id;
    int echo;
    int success;
    char text[513];
};

/* Allocate before arming I/O; launch only once the event reader is installed.
 * service and user are copied. The object remains valid until join_destroy. */
ouro_auth *ouro_auth_start(const char *service, const char *user);
void ouro_auth_launch(ouro_auth *auth);
int ouro_auth_fd(ouro_auth *auth);
/* 1 = event, 0 = none. */
int ouro_auth_pop(ouro_auth *auth, struct ouro_auth_event *event);
/* Sends one prompt response to the worker. Credentials arrive from a native
 * masked text field, never from Lua strings; the caller wipes its copy. At
 * most 512 bytes. 1 = sent, 0 = stale prompt or failure. */
int ouro_auth_respond(ouro_auth *auth, uint64_t prompt_id, const unsigned char *bytes, size_t length);
void ouro_auth_cancel(ouro_auth *auth);
int ouro_auth_done(ouro_auth *auth);
int ouro_auth_reason(ouro_auth *auth);
void ouro_auth_join_destroy(ouro_auth *auth);
/* Internal hidden-service entry point; called only by the executable dispatcher. */
int ouro_auth_worker_main(void);

#endif
