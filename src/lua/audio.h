#ifndef OURO_AUDIO_H
#define OURO_AUDIO_H
#include <stdint.h>

/* Private C/Zig boundary. No PipeWire callbacks enter Lua. */
struct ouro_audio;
struct ouro_audio_snapshot {
    uint64_t identity;
    double volume;
    uint32_t id;
    int connected, available, muted, error;
    char name[512], description[512];
};
struct ouro_audio *ouro_audio_create(void);
int ouro_audio_launch(struct ouro_audio *);
int ouro_audio_fd(struct ouro_audio *);
void ouro_audio_snapshot(struct ouro_audio *, struct ouro_audio_snapshot *);
/* Returns 0 on acceptance, 1 unavailable, 2 queue full, 3 stale target. */
int ouro_audio_set(struct ouro_audio *, uint64_t identity, int mute, double value);
void ouro_audio_stop(struct ouro_audio *);
int ouro_audio_done(struct ouro_audio *);
void ouro_audio_destroy(struct ouro_audio *);
#endif
