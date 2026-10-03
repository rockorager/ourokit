/* Worker-level Route fixture: no hardware and no production daemon. The native
 * integration test separately exercises real PipeWire transport with null sinks. */
#include "../src/lua/audio.c"
#include <assert.h>

static int writes, sync_sequence;
static float written[2];
static int set_route(void *data, uint32_t id, uint32_t flags, const struct spa_pod *pod) {
    (void)data; (void)flags;
    int index = -1, device = -1;
    bool save = false;
    struct spa_pod *props = NULL, *volumes = NULL;
    assert(id == SPA_PARAM_Route);
    assert(spa_pod_parse_object(pod, SPA_TYPE_OBJECT_ParamRoute, NULL,
        SPA_PARAM_ROUTE_index, SPA_POD_Int(&index), SPA_PARAM_ROUTE_device, SPA_POD_Int(&device),
        SPA_PARAM_ROUTE_save, SPA_POD_Bool(&save), SPA_PARAM_ROUTE_props, SPA_POD_Pod(&props)) >= 0);
    assert(index == 8 && device == 3 && save);
    assert(spa_pod_parse_object(props, SPA_TYPE_OBJECT_Props, NULL,
        SPA_PROP_channelVolumes, SPA_POD_Pod(&volumes)) >= 0);
    assert(spa_pod_copy_array(volumes, SPA_TYPE_Float, written, 2) == 2);
    writes++;
    return 0;
}
static int sync_core(void *data, uint32_t id, int seq) {
    (void)data; (void)id; (void)seq;
    return ++sync_sequence;
}
int main(void) {
    struct ouro_audio *a = ouro_audio_create();
    assert(a);
    const struct pw_device_methods dm = { .set_param = set_route };
    const struct pw_core_methods cm = { .sync = sync_core };
    struct spa_interface di = SPA_INTERFACE_INIT(PW_TYPE_INTERFACE_Device, PW_VERSION_DEVICE, &dm, NULL);
    struct spa_interface ci = SPA_INTERFACE_INIT(PW_TYPE_INTERFACE_Core, PW_VERSION_CORE, &cm, NULL);
    a->core = (struct pw_core *)&ci;
    snprintf(a->default_name, sizeof(a->default_name), "hardware");
    struct object node = { .owner=a, .id=12, .identity=1, .device_id=7, .profile_device=3,
        .name="hardware", .levels={.valid=true, .channels=2, .values={.729f,.729f}} };
    struct object device = { .owner=a, .id=7, .device=true, .ready=false, .permissions=PW_PERM_W,
        .proxy=(struct pw_proxy *)&di, .param_seq=41, .sync_seq=100 };
    spa_list_append(&a->objects, &node.link);
    spa_list_append(&a->objects, &device.link);
    publish(a);
    assert(!a->snapshot.available); /* Don't flash software gain before hardware enumeration. */
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    float values[] = { .064f, .343f };
    struct spa_pod *props = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
        SPA_PROP_mute, SPA_POD_Bool(true),
        SPA_PROP_channelVolumes, SPA_POD_Array(sizeof(float), SPA_TYPE_Float, 2, values));
    struct spa_pod *route = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamRoute, SPA_PARAM_Route,
        SPA_PARAM_ROUTE_index, SPA_POD_Int(8), SPA_PARAM_ROUTE_device, SPA_POD_Int(3),
        SPA_PARAM_ROUTE_props, SPA_POD_Pod(props));
    device_param(&device, 40, SPA_PARAM_Route, 0, 0, route);
    assert(device.n_enumerated_routes == 0); /* Obsolete enumeration is ignored. */
    device_param(&device, 41, SPA_PARAM_Route, 0, 0, route);
    assert(device.n_enumerated_routes == 1 && !a->snapshot.available);
    core_done(a, PW_ID_CORE, 100);
    assert(a->snapshot.available && a->snapshot.muted && fabs(a->snapshot.volume-.4) < .00001);
    assert(ouro_audio_set(a, 1, 0, .5) == 0);
    commands(a);
    assert(writes == 1 && written[0] == .125f && written[1] == .125f);
    assert(fabs(a->snapshot.volume-.4) < .00001); /* No optimistic publication. */
    assert(ouro_audio_set(a, 1, 2, .1) == 0);
    commands(a);
    assert(writes == 2 && fabs(written[0]-.216f) < .00001); /* Pending target, not stale .4. */
    device.permissions = PW_PERM_R;
    assert(ouro_audio_set(a, 1, 0, .7) == 0);
    commands(a);
    assert(writes == 2 && a->snapshot.error == PERMISSION_DENIED);
    node.profile_device = 4;
    publish(a);
    assert(fabs(a->snapshot.volume-.9) < .00001); /* Unrelated profile route cannot control node. */
    device.n_routes = 0;
    node.levels.valid = false;
    publish(a);
    assert(!a->snapshot.available);
    ouro_audio_destroy(a);
    puts("PASS Route pods: staged enumeration, profile matching, hardware precedence, saved cubic writes, pending adjustment, permission rejection");
}
