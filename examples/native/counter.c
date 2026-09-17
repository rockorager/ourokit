#include <ourokit/plugin.h>
#include <stdlib.h>

typedef struct counter {
    int64_t value;
    ouro_signal changed;
} counter;

static int32_t get(void *user, const ouro_api_v1 *api,
                   ouro_context *context, ouro_call *call) {
    counter *self = user;
    if (api->signal_read(context, self->changed) != OURO_OK) return OURO_ERROR;
    ouro_value result = { .type = OURO_INTEGER, .integer = self->value };
    return api->set_result(call, &result);
}

static int32_t set(void *user, const ouro_api_v1 *api,
                   ouro_context *context, ouro_call *call) {
    counter *self = user;
    ouro_value value;
    if (api->argument_count(call) != 1 ||
        api->argument(call, 0, &value) != OURO_OK ||
        value.type != OURO_INTEGER || value.integer < 0 || value.integer > 100) {
        const char message[] = "counter.set expects an integer from 0 to 100";
        api->set_error(call, message, sizeof(message) - 1);
        return OURO_ERROR;
    }
    if (self->value != value.integer) {
        if (api->signal_publish(context, self->changed) != OURO_OK) return OURO_ERROR;
        self->value = value.integer;
    }
    return api->set_result(call, &value);
}

static int32_t initialize(const ouro_api_v1 *api, ouro_context *context) {
    if (api->abi_version != OURO_ABI_VERSION || api->struct_size < sizeof(*api))
        return OURO_ERROR;
    counter *self = calloc(1, sizeof(*self));
    if (!self) return OURO_ERROR;
    if (api->set_destroy(context, free, self) != OURO_OK) {
        free(self);
        return OURO_ERROR;
    }
    if (api->signal_create(context, &self->changed) != OURO_OK) return OURO_ERROR;
    if (api->register_function(context, "get", 3, OURO_FUNCTION_READ_ONLY, get, self) != OURO_OK)
        return OURO_ERROR;
    return api->register_function(context, "set", 3, 0, set, self);
}

const ouro_plugin_descriptor ouro_plugin = {
    .abi_version = OURO_ABI_VERSION,
    .struct_size = sizeof(ouro_plugin_descriptor),
    .initialize = initialize,
};
