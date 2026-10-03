#define _GNU_SOURCE
#include "audio.h"
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/props.h>
#include <spa/param/route.h>
#include <spa/param/audio/raw.h>
#include <spa/pod/builder.h>
#include <spa/pod/parser.h>
#include <spa/utils/json.h>
#pragma GCC diagnostic pop
#include <pthread.h>
#include <stdatomic.h>
#include <sys/eventfd.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>

enum { BACKEND_ERROR = 1, PERMISSION_DENIED, STALE_OUTPUT, CAPACITY_EXCEEDED };
enum { MAX_OBJECTS = 256, MAX_ROUTES = 64, MAX_COMMANDS = 32 };
struct levels {
    bool valid, muted;
    uint32_t channels;
    float values[SPA_AUDIO_MAX_CHANNELS];
};
struct route { int index, device; struct levels levels; };
struct object {
    struct spa_list link;
    struct ouro_audio *owner;
    uint32_t id, device_id, permissions;
    uint64_t identity;
    bool device, ready;
    int profile_device, sync_seq, param_seq;
    char name[512], description[512];
    struct pw_proxy *proxy;
    struct spa_hook listener;
    struct levels levels;
    struct route routes[MAX_ROUTES];
    struct route enumerated_routes[MAX_ROUTES];
    uint32_t n_routes, n_enumerated_routes;
};
struct command { uint64_t identity; int mute; double value; };
struct ouro_audio {
    pthread_t thread;
    pthread_mutex_t mutex;
    atomic_bool stop, done;
    bool launched, notified;
    int pipe[2], wake;
    struct ouro_audio_snapshot snapshot;
    struct command commands[MAX_COMMANDS];
    unsigned count;
    /* Everything below is worker-thread-only. */
    struct pw_main_loop *main;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct pw_metadata *metadata;
    struct spa_hook core_listener, registry_listener, metadata_listener;
    struct spa_list objects;
    uint32_t metadata_id, n_objects;
    uint64_t next_identity;
    char default_name[512];
    bool broken;
    int error;
    uint64_t pending_identity;
    double pending_volume;
    int pending_sync, pending_route;
    bool pending_barrier;
};

static void notify_locked(struct ouro_audio *a) {
    if (!a->notified) {
        char byte = 1;
        if (write(a->pipe[1], &byte, 1) == 1) a->notified = true;
    }
}
static struct object *selected(struct ouro_audio *a) {
    struct object *o;
    spa_list_for_each(o, &a->objects, link)
        if (!o->device && a->default_name[0] && !strcmp(o->name, a->default_name)) return o;
    return NULL;
}
/* Match the system mixer's active hardware Route before falling back to Props. */
static struct levels *levels(struct ouro_audio *a, struct object *node,
                             struct object **device, struct route **route) {
    *device = NULL; *route = NULL;
    struct object *o;
    spa_list_for_each(o, &a->objects, link) {
        if (!o->device || o->id != node->device_id) continue;
        if (!o->ready) return NULL;
        for (uint32_t i = 0; i < o->n_routes; i++) {
            struct route *r = &o->routes[i];
            if (r->device == node->profile_device && r->levels.valid) {
                *device = o; *route = r;
                return &r->levels;
            }
        }
    }
    return node->levels.valid ? &node->levels : NULL;
}
static void publish(struct ouro_audio *a) {
    struct ouro_audio_snapshot s = { .connected = a->core && !a->broken, .error = a->error };
    struct object *node = selected(a), *device;
    struct route *route;
    struct levels *v = node ? levels(a, node, &device, &route) : NULL;
    if (s.connected && node) {
        s.id = node->id; s.identity = node->identity;
        snprintf(s.name, sizeof(s.name), "%s", node->name);
        snprintf(s.description, sizeof(s.description), "%s", node->description);
        if (v) {
            s.available = true; s.muted = v->muted;
            /* Channel 0 matches wpctl's scalar-volume convention. */
            s.volume = cbrt(v->values[0]);
        }
    }
    pthread_mutex_lock(&a->mutex);
    if (memcmp(&s, &a->snapshot, sizeof(s))) {
        a->snapshot = s;
        notify_locked(a);
    }
    pthread_mutex_unlock(&a->mutex);
}
static bool parse_levels(const struct spa_pod *pod, struct levels *v) {
    struct spa_pod *array = NULL;
    bool muted;
    if (!pod || spa_pod_parse_object(pod, SPA_TYPE_OBJECT_Props, NULL,
            SPA_PROP_mute, SPA_POD_Bool(&muted),
            SPA_PROP_channelVolumes, SPA_POD_Pod(&array)) < 0) return false;
    struct levels result = { .muted = muted };
    result.channels = spa_pod_copy_array(array, SPA_TYPE_Float, result.values, SPA_AUDIO_MAX_CHANNELS);
    if (!result.channels) return false;
    for (uint32_t i = 0; i < result.channels; i++)
        if (!isfinite(result.values[i]) || result.values[i] < 0) return false;
    result.valid = true;
    *v = result;
    return true;
}
static void node_param(void *data, int seq, uint32_t id, uint32_t index, uint32_t next, const struct spa_pod *param) {
    (void)index; (void)next;
    struct object *o = data;
    if (seq != o->param_seq || id != SPA_PARAM_Props) return;
    if (parse_levels(param, &o->levels)) publish(o->owner);
}
static void node_info(void *data, const struct pw_node_info *info) {
    struct object *o = data;
    if (info->change_mask & PW_NODE_CHANGE_MASK_PROPS) {
        const char *s;
        if ((s = spa_dict_lookup(info->props, PW_KEY_NODE_NAME))) snprintf(o->name, sizeof(o->name), "%s", s);
        if ((s = spa_dict_lookup(info->props, PW_KEY_NODE_DESCRIPTION))) snprintf(o->description, sizeof(o->description), "%s", s);
        o->device_id = (s = spa_dict_lookup(info->props, PW_KEY_DEVICE_ID)) ? (uint32_t)strtoul(s, NULL, 10) : SPA_ID_INVALID;
        o->profile_device = (s = spa_dict_lookup(info->props, "card.profile.device")) ? atoi(s) : -1;
    }
    if (info->change_mask & PW_NODE_CHANGE_MASK_PARAMS) {
        bool readable = false;
        for (uint32_t i = 0; i < info->n_params; i++)
            if (info->params[i].id == SPA_PARAM_Props && (info->params[i].flags & SPA_PARAM_INFO_READ)) {
                readable = true;
                o->param_seq = pw_node_enum_params((struct pw_node *)o->proxy, ++o->param_seq, SPA_PARAM_Props, 0, UINT32_MAX, NULL);
            }
        if (!readable) o->levels.valid = false;
    }
    publish(o->owner);
}
static const struct pw_node_events node_events = { PW_VERSION_NODE_EVENTS, .info = node_info, .param = node_param };
static void device_param(void *data, int seq, uint32_t id, uint32_t index, uint32_t next, const struct spa_pod *param) {
    (void)index; (void)next;
    struct object *o = data;
    if (seq != o->param_seq || id != SPA_PARAM_Route || !param) return;
    struct route r = {0};
    struct spa_pod *props = NULL;
    if (spa_pod_parse_object(param, SPA_TYPE_OBJECT_ParamRoute, NULL,
            SPA_PARAM_ROUTE_index, SPA_POD_Int(&r.index),
            SPA_PARAM_ROUTE_device, SPA_POD_Int(&r.device),
            SPA_PARAM_ROUTE_props, SPA_POD_Pod(&props)) < 0 || !parse_levels(props, &r.levels)) return;
    if (o->n_enumerated_routes < MAX_ROUTES) o->enumerated_routes[o->n_enumerated_routes++] = r;
    else o->owner->error = CAPACITY_EXCEEDED;
}
static void device_info(void *data, const struct pw_device_info *info) {
    struct object *o = data;
    if (!(info->change_mask & PW_DEVICE_CHANGE_MASK_PARAMS)) return;
    o->n_enumerated_routes = 0;
    for (uint32_t i = 0; i < info->n_params; i++)
        if (info->params[i].id == SPA_PARAM_Route && (info->params[i].flags & SPA_PARAM_INFO_READ))
            o->param_seq = pw_device_enum_params((struct pw_device *)o->proxy, ++o->param_seq, SPA_PARAM_Route, 0, UINT32_MAX, NULL);
    o->sync_seq = pw_core_sync(o->owner->core, PW_ID_CORE, 0);
}
static const struct pw_device_events device_events = { PW_VERSION_DEVICE_EVENTS, .info = device_info, .param = device_param };
static int metadata_property(void *data, uint32_t subject, const char *key, const char *type, const char *value) {
    (void)type;
    struct ouro_audio *a = data;
    if (subject != PW_ID_CORE || (key && strcmp(key, "default.audio.sink"))) return 0;
    a->default_name[0] = 0;
    if (key && value) {
        struct spa_json json, object;
        char field[128];
        spa_json_init(&json, value, strlen(value));
        if (spa_json_enter_object(&json, &object) > 0) {
            while (spa_json_get_string(&object, field, sizeof(field)) > 0) {
                const char *v;
                int len = spa_json_next(&object, &v);
                if (len <= 0) break;
                if (!strcmp(field, "name") && spa_json_is_string(v, len)) {
                    if (spa_json_parse_stringn(v, len, a->default_name, sizeof(a->default_name)) < 0) a->default_name[0] = 0;
                    break;
                }
            }
        }
    }
    publish(a);
    return 0;
}
static const struct pw_metadata_events metadata_events = { PW_VERSION_METADATA_EVENTS, .property = metadata_property };
static void global(void *data, uint32_t id, uint32_t permissions, const char *type, uint32_t version, const struct spa_dict *props) {
    struct ouro_audio *a = data;
    const char *s;
    if (!strcmp(type, PW_TYPE_INTERFACE_Metadata)) {
        if (a->metadata || !props || !(s = spa_dict_lookup(props, PW_KEY_METADATA_NAME)) || strcmp(s, "default")) return;
        a->metadata = pw_registry_bind(a->registry, id, type, SPA_MIN(version, (uint32_t)PW_VERSION_METADATA), 0);
        if (a->metadata) {
            a->metadata_id = id;
            pw_metadata_add_listener(a->metadata, &a->metadata_listener, &metadata_events, a);
        }
        return;
    }
    bool device = !strcmp(type, PW_TYPE_INTERFACE_Device);
    if (!device && (strcmp(type, PW_TYPE_INTERFACE_Node) || !props ||
        !(s = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS)) || strcmp(s, "Audio/Sink"))) return;
    if (a->n_objects == MAX_OBJECTS) { a->error = CAPACITY_EXCEEDED; publish(a); return; }
    struct object *o = calloc(1, sizeof(*o));
    if (!o) { a->error = BACKEND_ERROR; publish(a); return; }
    o->owner = a; o->id = id; o->device = device; o->permissions = permissions;
    o->identity = ++a->next_identity;
    o->device_id = SPA_ID_INVALID; o->profile_device = -1;
    o->proxy = pw_registry_bind(a->registry, id, type, SPA_MIN(version, (uint32_t)(device ? PW_VERSION_DEVICE : PW_VERSION_NODE)), 0);
    if (!o->proxy) { free(o); return; }
    spa_list_append(&a->objects, &o->link); a->n_objects++;
    if (device) pw_device_add_listener((struct pw_device *)o->proxy, &o->listener, &device_events, o);
    else pw_node_add_listener((struct pw_node *)o->proxy, &o->listener, &node_events, o);
}
static void remove_object(struct object *o) {
    o->owner->n_objects--;
    spa_list_remove(&o->link);
    spa_hook_remove(&o->listener);
    pw_proxy_destroy(o->proxy);
    free(o);
}
static void global_remove(void *data, uint32_t id) {
    struct ouro_audio *a = data;
    if (a->metadata && a->metadata_id == id) {
        spa_hook_remove(&a->metadata_listener);
        pw_proxy_destroy((struct pw_proxy *)a->metadata); a->metadata = NULL;
        a->default_name[0] = 0;
    }
    struct object *o, *tmp;
    spa_list_for_each_safe(o, tmp, &a->objects, link) if (o->id == id) remove_object(o);
    publish(a);
}
static const struct pw_registry_events registry_events = { PW_VERSION_REGISTRY_EVENTS, .global = global, .global_remove = global_remove };
static void core_error(void *data, uint32_t id, int seq, int res, const char *message) {
    (void)seq; (void)message;
    struct ouro_audio *a = data;
    a->error = res == -EACCES || res == -EPERM ? PERMISSION_DENIED : BACKEND_ERROR;
    if (id == PW_ID_CORE && (res == -EPIPE || res == -ECONNRESET)) a->broken = true;
    publish(a);
}
static void core_done(void *data, uint32_t id, int seq) {
    (void)id;
    struct ouro_audio *a = data;
    if (a->pending_identity && a->pending_sync == seq) {
        /* The first fence follows set_param. Info callbacks before it issue
         * enum_params; the second fence waits for those confirmed values. */
        if (a->pending_barrier) a->pending_identity = 0;
        else { a->pending_barrier = true; a->pending_sync = pw_core_sync(a->core, PW_ID_CORE, 0); }
    }
    struct object *o;
    spa_list_for_each(o, &a->objects, link) if (o->device && o->sync_seq == seq) {
        o->ready = true;
        o->n_routes = o->n_enumerated_routes;
        memcpy(o->routes, o->enumerated_routes, o->n_routes * sizeof(*o->routes));
    }
    publish(a);
}
static const struct pw_core_events core_events = { PW_VERSION_CORE_EVENTS, .done = core_done, .error = core_error };
static void disconnect(struct ouro_audio *a) {
    struct object *o, *tmp;
    spa_list_for_each_safe(o, tmp, &a->objects, link) remove_object(o);
    if (a->metadata) { spa_hook_remove(&a->metadata_listener); pw_proxy_destroy((struct pw_proxy *)a->metadata); a->metadata = NULL; }
    if (a->registry) { spa_hook_remove(&a->registry_listener); pw_proxy_destroy((struct pw_proxy *)a->registry); a->registry = NULL; }
    if (a->core) { spa_hook_remove(&a->core_listener); pw_core_disconnect(a->core); a->core = NULL; }
    a->default_name[0] = 0;
    a->pending_identity = 0;
    publish(a);
}
static void commands(struct ouro_audio *a) {
    struct command pending[MAX_COMMANDS];
    pthread_mutex_lock(&a->mutex);
    unsigned count = a->count;
    memcpy(pending, a->commands, count * sizeof(*pending)); a->count = 0;
    pthread_mutex_unlock(&a->mutex);
    for (unsigned i = 0; i < count; i++) {
        struct command *c = &pending[i];
        struct object *node = selected(a), *device;
        struct route *route;
        struct levels *v = node ? levels(a, node, &device, &route) : NULL;
        if (!a->core || a->broken || !node || node->identity != c->identity || !v) { a->error = STALE_OUTPUT; continue; }
        struct object *target = device ? device : node;
        if (!(target->permissions & PW_PERM_W)) { a->error = PERMISSION_DENIED; continue; }
        uint8_t buffer[2048];
        struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
        struct spa_pod_frame frame;
        spa_pod_builder_push_object(&b, &frame, SPA_TYPE_OBJECT_Props, SPA_PARAM_Props);
        double volume = c->value;
        int route_index = route ? route->index : -1;
        if (c->mute == 2) {
            double base = a->pending_identity == node->identity && a->pending_route == route_index ? a->pending_volume : cbrt(v->values[0]);
            volume = fmax(0, fmin(1, base + volume));
        }
        if (c->mute == 1) spa_pod_builder_add(&b, SPA_PROP_mute, SPA_POD_Bool(c->value != 0), 0);
        else {
            float values[SPA_AUDIO_MAX_CHANNELS];
            for (uint32_t k = 0; k < v->channels; k++) values[k] = volume * volume * volume;
            spa_pod_builder_add(&b, SPA_PROP_channelVolumes, SPA_POD_Array(sizeof(float), SPA_TYPE_Float, v->channels, values), 0);
        }
        struct spa_pod *props = spa_pod_builder_pop(&b, &frame);
        int result;
        if (device) {
            uint8_t route_buffer[4096];
            struct spa_pod_builder rb = SPA_POD_BUILDER_INIT(route_buffer, sizeof(route_buffer));
            struct spa_pod *param = spa_pod_builder_add_object(&rb, SPA_TYPE_OBJECT_ParamRoute, SPA_PARAM_Route,
                SPA_PARAM_ROUTE_index, SPA_POD_Int(route->index), SPA_PARAM_ROUTE_device, SPA_POD_Int(route->device),
                SPA_PARAM_ROUTE_props, SPA_POD_Pod(props), SPA_PARAM_ROUTE_save, SPA_POD_Bool(true));
            result = pw_device_set_param((struct pw_device *)device->proxy, SPA_PARAM_Route, 0, param);
        } else result = pw_node_set_param((struct pw_node *)node->proxy, SPA_PARAM_Props, 0, props);
        a->error = result < 0 ? BACKEND_ERROR : 0;
        if (result >= 0 && c->mute != 1) {
            a->pending_identity = node->identity;
            a->pending_route = route_index;
            a->pending_volume = volume;
            a->pending_barrier = false;
            a->pending_sync = pw_core_sync(a->core, PW_ID_CORE, 0);
        }
    }
    publish(a);
}
static void wakeup(void *data, int fd, uint32_t mask) {
    (void)data; (void)mask;
    uint64_t value;
    while (read(fd, &value, sizeof(value)) < 0 && errno == EINTR) {}
}
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) { pw_init(NULL, NULL); }
static void *worker(void *data) {
    struct ouro_audio *a = data;
    pthread_once(&initialized, initialize);
    a->main = pw_main_loop_new(NULL);
    struct spa_source *wake = NULL;
    if (!a->main) goto finished;
    struct pw_loop *loop = pw_main_loop_get_loop(a->main);
    pw_loop_enter(loop);
    a->context = pw_context_new(loop, NULL, 0);
    wake = pw_loop_add_io(loop, a->wake, SPA_IO_IN, false, wakeup, a);
    if (!a->context || !wake) goto cleanup;
    time_t retry = 0;
    while (!atomic_load(&a->stop)) {
        if (a->broken) { disconnect(a); a->broken = false; retry = time(NULL) + 1; }
        if (!a->core && time(NULL) >= retry) {
            a->core = pw_context_connect(a->context, NULL, 0);
            if (a->core) {
                a->error = 0;
                pw_core_add_listener(a->core, &a->core_listener, &core_events, a);
                a->registry = pw_core_get_registry(a->core, PW_VERSION_REGISTRY, 0);
                if (a->registry) pw_registry_add_listener(a->registry, &a->registry_listener, &registry_events, a);
                else a->broken = true;
                publish(a);
            }
            retry = time(NULL) + 1;
        }
        commands(a);
        if (pw_loop_iterate(loop, 250) < 0 && errno != EINTR) a->broken = true;
    }
cleanup:
    disconnect(a);
    if (wake) pw_loop_destroy_source(loop, wake);
    if (a->context) pw_context_destroy(a->context);
    pw_loop_leave(loop);
    pw_main_loop_destroy(a->main);
finished:
    atomic_store(&a->done, true);
    pthread_mutex_lock(&a->mutex);
    notify_locked(a);
    pthread_mutex_unlock(&a->mutex);
    return NULL;
}

struct ouro_audio *ouro_audio_create(void) {
    struct ouro_audio *a = calloc(1, sizeof(*a));
    if (!a) return NULL;
    spa_list_init(&a->objects);
    if (pthread_mutex_init(&a->mutex, NULL)) { free(a); return NULL; }
    if (pipe2(a->pipe, O_CLOEXEC)) goto fail;
    fcntl(a->pipe[1], F_SETFL, O_NONBLOCK);
    a->wake = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (a->wake < 0) { close(a->pipe[0]); close(a->pipe[1]); goto fail; }
    return a;
fail:
    pthread_mutex_destroy(&a->mutex); free(a); return NULL;
}
int ouro_audio_launch(struct ouro_audio *a) {
    int result = pthread_create(&a->thread, NULL, worker, a);
    a->launched = !result;
    if (result) {
        pthread_mutex_lock(&a->mutex);
        notify_locked(a);
        pthread_mutex_unlock(&a->mutex);
    }
    return result;
}
int ouro_audio_fd(struct ouro_audio *a) { return a->pipe[0]; }
void ouro_audio_snapshot(struct ouro_audio *a, struct ouro_audio_snapshot *s) {
    pthread_mutex_lock(&a->mutex);
    *s = a->snapshot; a->notified = false;
    pthread_mutex_unlock(&a->mutex);
}
int ouro_audio_set(struct ouro_audio *a, uint64_t identity, int mute, double value) {
    int result = 0;
    pthread_mutex_lock(&a->mutex);
    if (atomic_load(&a->stop) || !a->snapshot.available) result = 1;
    else if (a->snapshot.identity != identity) result = 3;
    else if (a->count == MAX_COMMANDS) result = 2;
    else a->commands[a->count++] = (struct command){ identity, mute, value };
    pthread_mutex_unlock(&a->mutex);
    uint64_t one = 1;
    if (!result) (void)write(a->wake, &one, sizeof(one));
    return result;
}
void ouro_audio_stop(struct ouro_audio *a) {
    atomic_store(&a->stop, true);
    uint64_t one = 1;
    (void)write(a->wake, &one, sizeof(one));
}
int ouro_audio_done(struct ouro_audio *a) { return !a->launched || atomic_load(&a->done); }
void ouro_audio_destroy(struct ouro_audio *a) {
    if (a->launched) pthread_join(a->thread, NULL);
    close(a->wake); close(a->pipe[0]); close(a->pipe[1]);
    pthread_mutex_destroy(&a->mutex); free(a);
}
