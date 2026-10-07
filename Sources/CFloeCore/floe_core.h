// C ABI of the Rust playback core (core/src/lib.rs). Keep the two in sync.
#ifndef FLOE_CORE_H
#define FLOE_CORE_H

#include <stdbool.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

/// Receives one JSON event on a background thread; `json` is valid only during the call.
typedef void (*FloeEventCallback)(void *_Nullable context, const char *json);

typedef struct FloeStats {
    uint64_t frames_rendered;
    uint64_t underruns;
    float peak;            // max |sample| since the previous call
    uint32_t buffered_ms;
} FloeStats;

/// Starts the core. Returns false if it was already started.
bool floe_init(FloeEventCallback callback, void *_Nullable context);

/// Spotify's own client ID, which librespot's session login requires. Process lifetime.
const char *floe_session_client_id(void);

/// Async logins. Emit `connecting`, then `credentials` + `connected`, or `login_failed`.
void floe_login_token(const char *access_token);
void floe_login_stored(const char *credentials_json);
void floe_logout(void);

/// Returns false for an invalid URI or when not logged in.
bool floe_load(const char *uri, bool play, uint32_t position_ms);
void floe_play(void);
void floe_pause(void);
void floe_seek(uint32_t position_ms);
void floe_stop(void);

/// Audio render thread only. Real-time safe. `left` and `right` must be distinct.
uint32_t floe_render(float *left, float *right, uint32_t frames);

void floe_take_stats(FloeStats *out);

#pragma clang assume_nonnull end

#endif
