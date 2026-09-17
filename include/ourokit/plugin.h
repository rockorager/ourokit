#ifndef OUROKIT_PLUGIN_H
#define OUROKIT_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Experimental ABI 1. No Lua or Zig struct layouts cross this boundary. */
#define OURO_ABI_VERSION 1u
#define OURO_OK 0
#define OURO_ERROR 1
#define OURO_FUNCTION_READ_ONLY 1u

#define OURO_NIL 0u
#define OURO_BOOLEAN 1u
#define OURO_INTEGER 2u
#define OURO_NUMBER 3u
#define OURO_STRING 4u

typedef struct ouro_context ouro_context;
typedef struct ouro_call ouro_call;
typedef struct ouro_api_v1 ouro_api_v1;
typedef uint64_t ouro_signal;

/* Logical-pixel coordinates, straight-alpha RGBA8 desktop colors (gamma 2.2).
   Rectangles paint in array order using source-over blending. */
typedef struct ouro_rectangle {
    float x, y, width, height;
    uint8_t r, g, b, a;
    float corner_radius;
} ouro_rectangle;

/* Only the field selected by type is used. Strings are length-delimited. */
typedef struct ouro_value {
    uint32_t type;
    int64_t integer;
    double number;
    const char *bytes;
    size_t length;
} ouro_value;

typedef int32_t (*ouro_function)(void *user, const ouro_api_v1 *api,
                               ouro_context *context, ouro_call *call);
typedef void (*ouro_destroy)(void *user);

struct ouro_api_v1 {
    uint32_t abi_version;
    uint32_t struct_size;

    /* Initialization only. Names are copied. Register destroy before resources. */
    int32_t (*register_function)(ouro_context *, const char *name, size_t length,
                                 uint32_t flags, ouro_function, void *user);
    int32_t (*set_destroy)(ouro_context *, ouro_destroy, void *user);

    /* Calls are synchronous and event-thread-only. Arguments are zero-based,
       borrowed until callback return. Result/error bytes are copied immediately.
       Returning OURO_ERROR raises a Lua error only AFTER the callback returns. */
    size_t (*argument_count)(ouro_call *);
    int32_t (*argument)(ouro_call *, size_t index, ouro_value *out);
    int32_t (*set_result)(ouro_call *, const ouro_value *);
    int32_t (*set_error)(ouro_call *, const char *bytes, size_t length);

    /* Generation-owned dependencies, automatically released at teardown.
       A read-only function may read but never publish. Mutating functions are
       rejected before invocation during a UI build transaction. */
    int32_t (*signal_create)(ouro_context *, ouro_signal *out);
    int32_t (*signal_read)(ouro_context *, ouro_signal);
    int32_t (*signal_publish)(ouro_context *, ouro_signal);

    /* Copies at most 4096 rectangles into an immutable host-owned Lua drawing.
       Replaces the call result; use ouro.canvas { key=..., drawing=result }.
       Width/height are the preferred logical size. Layout may constrain it;
       painting is clipped to the canvas, never stretched. All coordinates must
       be finite; dimensions/radii must be nonnegative. No plugin pointers are
       retained. On error the previous result is unchanged. */
    int32_t (*set_drawing_result)(ouro_call *, float width, float height,
                                  const ouro_rectangle *, size_t count);
};

typedef struct ouro_plugin_descriptor {
    uint32_t abi_version;
    uint32_t struct_size;
    /* Called once per Lua source generation, including reload candidates.
       Use context-owned state, not mutable process globals. No async work may
       outlive callbacks in this ABI. Destroy runs even after failed init. */
    int32_t (*initialize)(const ouro_api_v1 *, ouro_context *);
} ouro_plugin_descriptor;

/* A shared library exports this DATA symbol. The host validates its prefix
   before calling initialize. Keep the library loaded through all generations. */
extern const ouro_plugin_descriptor ouro_plugin;

#ifdef __cplusplus
}
#endif
#endif
