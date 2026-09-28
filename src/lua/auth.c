#define _GNU_SOURCE
#include "auth.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct pam_handle pam_handle_t;
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
enum {
    PAM_SUCCESS = 0,
    PAM_OPEN_ERR = 1,
    PAM_CONV_ERR = 19,
    PAM_PROMPT_ECHO_OFF = 1,
    PAM_PROMPT_ECHO_ON = 2,
    PAM_ERROR_MSG = 3,
    PAM_TEXT_INFO = 4
};
enum { MSG_START = 1, MSG_PROMPT, MSG_INFO, MSG_ERROR, MSG_REPLY, MSG_RESULT };
struct message {
    uint32_t type, value, length;
    char data[513];
};

struct ouro_auth {
    pthread_t thread;
    pthread_mutex_t lock;
    int pipefd[2], control[2], canceled, done, launched, reason;
    pid_t child;
    uint64_t next_id, pending_id;
    unsigned char *entry;
    size_t entry_len, cursor;
    int selected;
    char *service, *user;
    struct ouro_auth_event queue[8];
    unsigned head, count;
};

static void wipe(void *p, size_t n) {
    volatile unsigned char *v = p;
    while (n--)
        *v++ = 0;
}
static int write_all(int fd, const void *p, size_t n) {
    ssize_t r;
    do {
        r = send(fd, p, n, MSG_NOSIGNAL);
    } while (r < 0 && errno == EINTR);
    return r == (ssize_t)n;
}
static int read_all(int fd, void *p, size_t n) {
    ssize_t r;
    do {
        r = recv(fd, p, n, MSG_TRUNC);
    } while (r < 0 && errno == EINTR);
    return r == (ssize_t)n;
}
static void notify(struct ouro_auth *a) {
    unsigned char b = 1;
    (void)write(a->pipefd[1], &b, 1);
}
static void clear_locked(struct ouro_auth *a) {
    wipe(a->entry, 513);
    a->entry_len = a->cursor = 0;
    a->selected = 0;
}
static void publish(struct ouro_auth *a, int kind, uint64_t id, int echo, int success,
                    const char *text) {
    pthread_mutex_lock(&a->lock);
    if (a->count == 8) { /* Overflow fails the conversation, never loses a prompt silently. */
        a->head = a->count = 0;
        a->canceled = 1;
        a->reason = OURO_AUTH_WORKER_FAILED;
    }
    struct ouro_auth_event *e = &a->queue[(a->head + a->count) % 8];
    memset(e, 0, sizeof *e);
    e->kind = kind;
    e->prompt_id = id;
    e->echo = echo;
    e->success = kind == OURO_AUTH_RESULT && !a->canceled ? success : 0;
    if (text) {
        size_t n = strnlen(text, 512);
        memcpy(e->text, text, n);
    }
    a->count++;
    if (kind == OURO_AUTH_RESULT) {
        a->done = 1;
        a->pending_id = 0;
        clear_locked(a);
    }
    pthread_mutex_unlock(&a->lock);
    notify(a);
}
static int64_t milliseconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
/* A kernel-uninterruptible child cannot be synchronously reaped with a deadline.
 * Transfer only its pid to this bounded process-owned reaper, never a Job pointer.
 * Reserve a slot before fork so repeated pathological workers cannot grow it. */
static pthread_mutex_t children_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t children_changed = PTHREAD_COND_INITIALIZER;
static pthread_once_t reaper_once = PTHREAD_ONCE_INIT;
static struct {
    pid_t pid;
    int retired;
} children[32];
static int reaper_ready;
static void *reaper(void *unused) {
    (void)unused;
    for (;;) {
        pthread_mutex_lock(&children_lock);
        int pending = 0;
        for (unsigned i = 0; i < 32; i++)
            if (children[i].retired) {
                pid_t r = waitpid(children[i].pid, NULL, WNOHANG);
                if (r == children[i].pid || (r < 0 && errno == ECHILD))
                    children[i].pid = children[i].retired = 0;
                else
                    pending = 1;
            }
        if (!pending)
            pthread_cond_wait(&children_changed, &children_lock);
        pthread_mutex_unlock(&children_lock);
        if (pending) {
            struct timespec t = {0, 100000000};
            nanosleep(&t, NULL);
        }
    }
    return NULL;
}
static void start_reaper(void) {
    pthread_t thread;
    if (!pthread_create(&thread, NULL, reaper, NULL)) {
        pthread_detach(thread);
        reaper_ready = 1;
    }
}
static int reserve_child(void) {
    pthread_once(&reaper_once, start_reaper);
    if (!reaper_ready)
        return -1;
    pthread_mutex_lock(&children_lock);
    int slot = -1;
    for (int i = 0; i < 32; i++)
        if (!children[i].pid) {
            children[i].pid = -1;
            slot = i;
            break;
        }
    pthread_mutex_unlock(&children_lock);
    return slot;
}
static void release_child(int slot, pid_t retired) {
    pthread_mutex_lock(&children_lock);
    children[slot].pid = retired;
    children[slot].retired = retired > 0;
    pthread_cond_signal(&children_changed);
    pthread_mutex_unlock(&children_lock);
}
static void finish(struct ouro_auth *a, int reason) {
    pthread_mutex_lock(&a->lock);
    if (a->canceled && a->reason != OURO_AUTH_WORKER_FAILED)
        reason = OURO_AUTH_CANCELED;
    if (a->reason == OURO_AUTH_WORKER_FAILED)
        reason = OURO_AUTH_WORKER_FAILED;
    a->reason = reason;
    pthread_mutex_unlock(&a->lock);
    publish(a, OURO_AUTH_RESULT, 0, 0, reason == OURO_AUTH_SUCCESS, NULL);
}
static pid_t reap_child(pid_t pid, int *status) {
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0)
        return -1;
    if (!info.si_pid)
        return 0;
    // Retire module-spawned descendants before reaping permits PID/PGID reuse.
    kill(-pid, SIGKILL);
    return waitpid(pid, status, WNOHANG);
}
static void terminate_child(pid_t pid, int slot) {
    if (pid <= 0)
        return;
    kill(-pid, SIGTERM);
    int64_t end = milliseconds() + 200;
    while (milliseconds() < end) {
        pid_t r = reap_child(pid, NULL);
        if (r == pid || (r < 0 && errno == ECHILD)) {
            release_child(slot, 0);
            return;
        }
        struct timespec t = {0, 10000000};
        nanosleep(&t, NULL);
    }
    kill(-pid, SIGKILL);
    end = milliseconds() + 500;
    while (milliseconds() < end) {
        pid_t r = reap_child(pid, NULL);
        if (r == pid || (r < 0 && errno == ECHILD)) {
            release_child(slot, 0);
            return;
        }
        struct timespec t = {0, 10000000};
        nanosleep(&t, NULL);
    }
    release_child(slot, pid);
}
static pid_t spawn_worker(int fd) {
    int nullfd = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (nullfd < 0)
        return -1;
    char envbuf[4096];
    char *ev[2] = {NULL, NULL};
    char *ld = getenv("LD_LIBRARY_PATH");
    if (ld && strlen(ld) < sizeof envbuf - 17) {
        strcpy(envbuf, "LD_LIBRARY_PATH=");
        strcat(envbuf, ld);
        ev[0] = envbuf;
    }
    pid_t parent = getpid();
    pid_t p = fork();
    if (p == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent || setpgid(0, 0) ||
            dup2(nullfd, 0) < 0 || dup2(nullfd, 1) < 0 || dup2(nullfd, 2) < 0 || dup2(fd, 3) < 0 ||
            fcntl(3, F_SETFD, 0) < 0 || syscall(SYS_close_range, 4U, ~0U, 0U) < 0)
            _exit(127);
        char *const av[] = {(char *)"ouroctl", (char *)"--ourokit-auth-worker", NULL};
        execve("/proc/self/exe", av, ev);
        _exit(127);
    }
    close(nullfd);
    if (p > 0)
        setpgid(p, p);
    return p;
}
static void *supervisor(void *arg) {
    struct ouro_auth *a = arg;
    struct message m = {0};
    int slot = reserve_child();
    if (slot < 0) {
        finish(a, OURO_AUTH_WORKER_FAILED);
        return NULL;
    }
    pid_t p = spawn_worker(a->control[1]);
    close(a->control[1]);
    a->control[1] = -1;
    pthread_mutex_lock(&a->lock);
    a->child = p;
    int was_canceled = a->canceled;
    pthread_mutex_unlock(&a->lock);
    if (p < 0) {
        release_child(slot, 0);
        finish(a, OURO_AUTH_WORKER_FAILED);
        return NULL;
    }
    m.type = MSG_START;
    m.length = (uint32_t)(strlen(a->service) + 1 + strlen(a->user) + 1);
    if (m.length > 513)
        goto failed;
    strcpy(m.data, a->service);
    strcpy(m.data + strlen(a->service) + 1, a->user);
    if (!write_all(a->control[0], &m, sizeof m))
        goto failed;
    int64_t deadline = milliseconds() + 120000;
    while (!was_canceled) {
        pthread_mutex_lock(&a->lock);
        was_canceled = a->canceled;
        pthread_mutex_unlock(&a->lock);
        if (was_canceled)
            break;
        int left = (int)(deadline - milliseconds());
        if (left <= 0) {
            break;
        }
        struct pollfd f = {a->control[0], POLLIN, 0};
        int r = poll(&f, 1, left > 50 ? 50 : left);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            continue;
        if (!read_all(a->control[0], &m, sizeof m) || m.length > 512)
            goto failed;
        if (m.type == MSG_PROMPT) {
            pthread_mutex_lock(&a->lock);
            clear_locked(a);
            uint64_t id = ++a->next_id;
            a->pending_id = id;
            pthread_mutex_unlock(&a->lock);
            publish(a, OURO_AUTH_PROMPT, id, (int)m.value, 0, m.data);
        } else if (m.type == MSG_INFO || m.type == MSG_ERROR)
            publish(a, m.type == MSG_INFO ? OURO_AUTH_INFO : OURO_AUTH_ERROR, 0, 0, 0, m.data);
        else if (m.type == MSG_RESULT) {
            // A PAM atexit handler must not stall the shell after a result.
            int64_t end = milliseconds() + 100;
            while (milliseconds() < end) {
                int status;
                if (reap_child(p, &status) == p) {
                    release_child(slot, 0);
                    finish(a, (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
                                  ? OURO_AUTH_WORKER_FAILED
                              : m.value ? OURO_AUTH_SUCCESS
                                        : (m.length ? OURO_AUTH_UNAVAILABLE : OURO_AUTH_DENIED));
                    return NULL;
                }
                struct timespec pause = {0, 1000000};
                nanosleep(&pause, NULL);
            }
            goto failed;
        }
    }
    terminate_child(p, slot);
    finish(a, was_canceled ? OURO_AUTH_CANCELED : OURO_AUTH_TIMEOUT);
    return NULL;
failed:
    terminate_child(p, slot);
    finish(a, was_canceled ? OURO_AUTH_CANCELED : OURO_AUTH_WORKER_FAILED);
    return NULL;
}

ouro_auth *ouro_auth_start(const char *service, const char *user) {
    ouro_auth *a = calloc(1, sizeof *a);
    if (!a)
        return NULL;
    a->pipefd[0] = a->pipefd[1] = a->control[0] = a->control[1] = -1;
    a->service = strdup(service);
    a->user = strdup(user);
    a->entry = mmap(NULL, 513, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (!a->service || !a->user || a->entry == MAP_FAILED || mlock(a->entry, 513) ||
        madvise(a->entry, 513, MADV_DONTDUMP))
        goto fail;
    // Starting authentication permanently disables process dumps/ptrace by
    // unprivileged peers; the mapping is also excluded and locked against swap.
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) || pthread_mutex_init(&a->lock, NULL))
        goto fail;
    if (pipe2(a->pipefd, O_CLOEXEC | O_NONBLOCK) || fcntl(a->pipefd[0], F_SETFL, 0) < 0 ||
        socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, a->control) ||
        fcntl(a->control[0], F_SETFL, O_NONBLOCK) < 0)
        goto syncfail;
    return a;
syncfail:
    pthread_mutex_destroy(&a->lock);
fail:
    for (int i = 0; i < 2; i++) {
        if (a->pipefd[i] >= 0)
            close(a->pipefd[i]);
        if (a->control[i] >= 0)
            close(a->control[i]);
    }
    if (a->entry != MAP_FAILED && a->entry) {
        wipe(a->entry, 513);
        munlock(a->entry, 513);
        munmap(a->entry, 513);
    }
    free(a->service);
    if (a->user) {
        wipe(a->user, strlen(a->user));
        free(a->user);
    }
    free(a);
    return NULL;
}
void ouro_auth_launch(ouro_auth *a) {
    if (pthread_create(&a->thread, NULL, supervisor, a) == 0)
        a->launched = 1;
    else {
        finish(a, OURO_AUTH_WORKER_FAILED);
    }
}
int ouro_auth_fd(ouro_auth *a) { return a->pipefd[0]; }
int ouro_auth_pop(ouro_auth *a, struct ouro_auth_event *e) {
    pthread_mutex_lock(&a->lock);
    if (!a->count) {
        pthread_mutex_unlock(&a->lock);
        return 0;
    }
    *e = a->queue[a->head];
    if (a->canceled && e->kind == OURO_AUTH_RESULT)
        e->success = 0;
    a->head = (a->head + 1) % 8;
    a->count--;
    pthread_mutex_unlock(&a->lock);
    return 1;
}
static size_t previous(const unsigned char *s, size_t p) {
    if (!p)
        return 0;
    do
        p--;
    while (p && (s[p] & 0xc0) == 0x80);
    return p;
}
static size_t following(const unsigned char *s, size_t n, size_t p) {
    if (p >= n)
        return n;
    p++;
    while (p < n && (s[p] & 0xc0) == 0x80)
        p++;
    return p;
}
int ouro_auth_edit(ouro_auth *a, uint64_t id, int command, uint32_t unicode) {
    unsigned char bytes[4];
    size_t bn = 0;
    if (command == OURO_AUTH_INSERT) {
        if (!unicode)
            return 0;
        if (unicode <= 0x7f)
            bytes[bn++] = (unsigned char)unicode;
        else if (unicode <= 0x7ff) {
            bytes[bn++] = 0xc0 | unicode >> 6;
            bytes[bn++] = 0x80 | (unicode & 63);
        } else if (unicode >= 0xd800 && unicode <= 0xdfff)
            return 0;
        else if (unicode <= 0xffff) {
            bytes[bn++] = 0xe0 | unicode >> 12;
            bytes[bn++] = 0x80 | (unicode >> 6 & 63);
            bytes[bn++] = 0x80 | (unicode & 63);
        } else if (unicode <= 0x10ffff) {
            bytes[bn++] = 0xf0 | unicode >> 18;
            bytes[bn++] = 0x80 | (unicode >> 12 & 63);
            bytes[bn++] = 0x80 | (unicode >> 6 & 63);
            bytes[bn++] = 0x80 | (unicode & 63);
        } else
            return 0;
    }
    pthread_mutex_lock(&a->lock);
    int valid = id && !a->done && !a->canceled && a->pending_id == id;
    if (!valid) {
        wipe(bytes, sizeof bytes);
        pthread_mutex_unlock(&a->lock);
        return 0;
    }
    if (a->selected && (command == OURO_AUTH_INSERT || command == OURO_AUTH_BACKSPACE ||
                        command == OURO_AUTH_DELETE))
        clear_locked(a);
    if (command == OURO_AUTH_INSERT) {
        if (a->entry_len + bn > 512) {
            wipe(bytes, sizeof bytes);
            pthread_mutex_unlock(&a->lock);
            return -1;
        }
        memmove(a->entry + a->cursor + bn, a->entry + a->cursor, a->entry_len - a->cursor);
        memcpy(a->entry + a->cursor, bytes, bn);
        a->cursor += bn;
        a->entry_len += bn;
    } else if (command == OURO_AUTH_BACKSPACE) {
        size_t p = previous(a->entry, a->cursor);
        memmove(a->entry + p, a->entry + a->cursor, a->entry_len - a->cursor);
        a->entry_len -= a->cursor - p;
        a->cursor = p;
    } else if (command == OURO_AUTH_DELETE) {
        size_t p = following(a->entry, a->entry_len, a->cursor);
        memmove(a->entry + a->cursor, a->entry + p, a->entry_len - p);
        a->entry_len -= p - a->cursor;
    } else if (command == OURO_AUTH_LEFT)
        a->cursor = previous(a->entry, a->cursor);
    else if (command == OURO_AUTH_RIGHT)
        a->cursor = following(a->entry, a->entry_len, a->cursor);
    else if (command == OURO_AUTH_HOME)
        a->cursor = 0;
    else if (command == OURO_AUTH_END)
        a->cursor = a->entry_len;
    else if (command == OURO_AUTH_CLEAR)
        clear_locked(a);
    else if (command == OURO_AUTH_SELECT_ALL)
        a->selected = 1;
    else {
        wipe(bytes, sizeof bytes);
        pthread_mutex_unlock(&a->lock);
        return 0;
    }
    if (command != OURO_AUTH_SELECT_ALL)
        a->selected = 0;
    wipe(a->entry + a->entry_len, 513 - a->entry_len);
    wipe(bytes, sizeof bytes);
    pthread_mutex_unlock(&a->lock);
    return 1;
}
int ouro_auth_has_input(ouro_auth *a, uint64_t id) {
    pthread_mutex_lock(&a->lock);
    int r = id && a->pending_id == id && a->entry_len != 0;
    pthread_mutex_unlock(&a->lock);
    return r;
}
int ouro_auth_clear_input(ouro_auth *a, uint64_t id) {
    pthread_mutex_lock(&a->lock);
    int r = id && a->pending_id == id && !a->done && !a->canceled;
    if (r)
        clear_locked(a);
    pthread_mutex_unlock(&a->lock);
    return r;
}
int ouro_auth_submit(ouro_auth *a, uint64_t id) {
    struct message m = {.type = MSG_REPLY};
    pthread_mutex_lock(&a->lock);
    int ok = id && a->pending_id == id && !a->done && !a->canceled;
    if (ok) {
        m.length = (uint32_t)a->entry_len;
        memcpy(m.data, a->entry, a->entry_len);
        a->pending_id = 0;
        clear_locked(a);
    }
    pthread_mutex_unlock(&a->lock);
    if (ok && !write_all(a->control[0], &m, sizeof m)) {
        ok = 0;
        ouro_auth_cancel(a);
    }
    wipe(&m, sizeof m);
    return ok;
}
void ouro_auth_cancel(ouro_auth *a) {
    pthread_mutex_lock(&a->lock);
    int changed = !a->canceled;
    a->canceled = 1;
    a->pending_id = 0;
    clear_locked(a);
    pthread_mutex_unlock(&a->lock);
    if (changed)
        notify(a);
}
int ouro_auth_done(ouro_auth *a) {
    pthread_mutex_lock(&a->lock);
    int r = a->done;
    pthread_mutex_unlock(&a->lock);
    return r;
}
int ouro_auth_reason(ouro_auth *a) {
    pthread_mutex_lock(&a->lock);
    int r = a->reason;
    pthread_mutex_unlock(&a->lock);
    return r;
}
void ouro_auth_join_destroy(ouro_auth *a) {
    ouro_auth_cancel(a);
    if (a->launched)
        pthread_join(a->thread, NULL);
    if (a->control[0] >= 0)
        close(a->control[0]);
    if (a->control[1] >= 0)
        close(a->control[1]);
    close(a->pipefd[0]);
    close(a->pipefd[1]);
    clear_locked(a);
    munlock(a->entry, 513);
    munmap(a->entry, 513);
    wipe(a->user, strlen(a->user));
    free(a->user);
    free(a->service);
    pthread_mutex_destroy(&a->lock);
    free(a);
}

struct worker_context {
    int fd;
};
static int worker_conv(int n, const struct pam_message **msgs, struct pam_response **out,
                       void *ctx) {
    struct worker_context *w = ctx;
    if (n <= 0 || n > 32 || !msgs || !out)
        return PAM_CONV_ERR;
    struct pam_response *r = calloc((size_t)n, sizeof *r);
    if (!r)
        return PAM_CONV_ERR;
    struct message m = {0};
    for (int i = 0; i < n; i++) {
        memset(&m, 0, sizeof m);
        if (!msgs[i] || !msgs[i]->msg)
            goto fail;
        int st = msgs[i]->msg_style;
        m.type = st == PAM_TEXT_INFO ? MSG_INFO : st == PAM_ERROR_MSG ? MSG_ERROR : MSG_PROMPT;
        m.value = st == PAM_PROMPT_ECHO_ON;
        if (st < 1 || st > 4)
            goto fail;
        size_t z = strnlen(msgs[i]->msg, 512);
        memcpy(m.data, msgs[i]->msg, z);
        m.length = (uint32_t)z;
        if (!write_all(w->fd, &m, sizeof m))
            goto fail;
        if (m.type == MSG_PROMPT) {
            if (!read_all(w->fd, &m, sizeof m) || m.type != MSG_REPLY || m.length > 512)
                goto fail;
            r[i].resp = malloc(m.length + 1);
            if (!r[i].resp)
                goto fail;
            memcpy(r[i].resp, m.data, m.length);
            r[i].resp[m.length] = 0;
            wipe(&m, sizeof m);
        }
    }
    *out = r;
    return PAM_SUCCESS;
fail:
    wipe(&m, sizeof m);
    for (int i = 0; i < n; i++)
        if (r[i].resp) {
            wipe(r[i].resp, strlen(r[i].resp));
            free(r[i].resp);
        }
    free(r);
    return PAM_CONV_ERR;
}
int ouro_auth_worker_main(void) {
    struct rlimit zero = {0, 0};
    if (setrlimit(RLIMIT_CORE, &zero) || prctl(PR_SET_DUMPABLE, 0, 0, 0, 0))
        return 2;
    struct message m;
    if (!read_all(3, &m, sizeof m) || m.type != MSG_START || m.length < 3 || m.length > 513)
        return 2;
    char *service = m.data, *user = memchr(m.data, 0, m.length);
    if (!user || user + 1 >= m.data + m.length || m.data[m.length - 1])
        return 2;
    user++;
    void *lib = dlopen("libpam.so.0", RTLD_NOW | RTLD_LOCAL);
    int status = PAM_OPEN_ERR, ok = 0, unavailable = 1;
    if (lib) {
        int (*start)(const char *, const char *, const struct pam_conv *, pam_handle_t **) =
            dlsym(lib, "pam_start");
        int (*auth)(pam_handle_t *, int) = dlsym(lib, "pam_authenticate");
        int (*acct)(pam_handle_t *, int) = dlsym(lib, "pam_acct_mgmt");
        int (*end)(pam_handle_t *, int) = dlsym(lib, "pam_end");
        pam_handle_t *p = NULL;
        struct worker_context wc = {3};
        struct pam_conv cv = {worker_conv, &wc};
        if (start && auth && acct && end) {
            unavailable = 0;
            status = start(service, user, &cv, &p);
            if (status == 0)
                status = auth(p, 0);
            if (status == 0)
                status = acct(p, 0);
            if (p) {
                int end_status = end(p, status);
                if (status == 0)
                    status = end_status;
            }
            ok = status == 0;
        }
        dlclose(lib);
    }
    wipe(&m, sizeof m);
    memset(&m, 0, sizeof m);
    m.type = MSG_RESULT;
    m.value = (uint32_t)ok;
    m.length = (uint32_t)unavailable;
    return write_all(3, &m, sizeof m) ? 0 : 3;
}
