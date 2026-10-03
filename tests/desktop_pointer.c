/* Test-only virtual pointer, connected exclusively to the private compositor. */
#include <wayland-client.h>
#include "virtual-pointer.h"
#include <stdio.h>
#include <string.h>

static struct zwlr_virtual_pointer_manager_v1 *manager;
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1"))
        manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    const struct wl_registry_listener listener = {global, removed};
    wl_registry_add_listener(registry, &listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager) return 2;
    struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
    if (wl_display_roundtrip(display) < 0) return 3;
    puts("ready"); fflush(stdout);
    /* Existing tests drive the live seat through Sway IPC. Optional commands
       exercise actual device events, including the compositor's implicit grab. */
    char line[128];
    unsigned x, y, button, state, time = 1;
    while (fgets(line, sizeof(line), stdin)) {
        if (sscanf(line, "move %u %u", &x, &y) == 2)
            zwlr_virtual_pointer_v1_motion_absolute(pointer, time++, x, y, 1280, 720);
        else if (sscanf(line, "button %u %u", &button, &state) == 2)
            zwlr_virtual_pointer_v1_button(pointer, time++, button, state);
        else break;
        zwlr_virtual_pointer_v1_frame(pointer);
        if (wl_display_roundtrip(display) < 0) break;
        puts("done"); fflush(stdout);
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
