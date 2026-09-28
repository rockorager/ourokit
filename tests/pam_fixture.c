/* Test-only libpam.so.0. Never install this library or use it on a real locker. */
#define _DEFAULT_SOURCE
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct pam_message {
    int msg_style;
    const char *msg;
};
struct pam_response {
    char *resp;
    int resp_retcode;
};
struct pam_conv {
    int (*conv)(int, const struct pam_message **, struct pam_response **, void *);
    void *appdata_ptr;
};
struct pam_handle {
    struct pam_conv conv;
    const char *service;
    int deny, blocked, crash;
};
int pam_start(const char *service, const char *user, const struct pam_conv *conv,
              struct pam_handle **out) {
    if (strcmp(user, "fixture-user"))
        return 7;
    *out = calloc(1, sizeof **out);
    if (!*out)
        return 4;
    (*out)->conv = *conv;
    (*out)->service = service;
    (*out)->deny = !strcmp(service, "deny-account");
    (*out)->blocked = !strcmp(service, "blocked");
    (*out)->crash = !strcmp(service, "crash");
    return 0;
}
int pam_authenticate(struct pam_handle *p, int flags) {
    if (flags)
        return 7;
    if (p->blocked) {
        signal(SIGTERM, SIG_IGN);
        for (;;)
            pause();
    }
    if (p->crash)
        raise(SIGSEGV);
    struct pam_message info = {4, "Fixture information"}, name = {2, "Identity"},
                       password = {1, "Challenge"}, error = {3, "Fixture error"};
    if (!strcmp(p->service, "limit")) {
        const struct pam_message *message[] = {&name};
        struct pam_response *one = NULL;
        int result = p->conv.conv(1, message, &one, p->conv.appdata_ptr);
        if (result)
            return result;
        int success = one[0].resp && strlen(one[0].resp) == 512 && strspn(one[0].resp, "x") == 512;
        free(one[0].resp);
        free(one);
        return success ? 0 : 7;
    }
    const int edited = !strcmp(p->service, "edited");
    const struct pam_message *error_message[] = {&error};
    if (!strcmp(p->service, "error-first")) {
        struct pam_response *ignored = NULL;
        int result = p->conv.conv(1, error_message, &ignored, p->conv.appdata_ptr);
        free(ignored);
        if (result)
            return result;
    }
    const struct pam_message *messages[] = {&info, &name, &password};
    struct pam_response *r = NULL;
    int result = p->conv.conv(3, messages, &r, p->conv.appdata_ptr);
    if (result)
        return result;
    int success = !r[0].resp && r[1].resp && r[2].resp &&
                  !strcmp(r[1].resp, edited ? "Aé🙂Z" : "alice") &&
                  !strcmp(r[2].resp, edited ? "päss🔒" : "test-only-response");
    for (int i = 0; i < 3; i++)
        free(r[i].resp);
    free(r);
    return success ? 0 : 7;
}
int pam_acct_mgmt(struct pam_handle *p, int flags) { return flags || p->deny ? 7 : 0; }
int pam_end(struct pam_handle *p, int status) {
    (void)status;
    int failure = !strcmp(p->service, "end-failed");
    free(p);
    return failure ? 4 : 0;
}
