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
    uint64_t underruns;    // times playback ran dry after having audio
    float peak;            // max |sample| since the previous call
    uint32_t buffered_ms;
} FloeStats;

/// Starts the core. Returns false if it was already started.
bool floe_init(FloeEventCallback callback, void *_Nullable context);

/// Keeps played audio files (encrypted, as downloaded) in `directory`, deleting the ones
/// played longest ago past `limit_bytes`. Call before the first login; 0 leaves it off.
void floe_set_audio_cache(const char *directory, uint64_t limit_bytes);

/// Spotify's own client ID, which librespot's session login requires. Process lifetime.
const char *floe_session_client_id(void);

/// Async logins that also start the "Tint" Connect device at `volume` (0…65535).
/// Emit `connecting`, then `credentials` + `connected`, or `login_failed`.
/// `disconnected` follows later if the session drops.
void floe_login_token(const char *access_token, uint16_t volume);
void floe_login_stored(const char *credentials_json, uint16_t volume);
void floe_logout(void);
/// Configuration for the next session (reconnect/relaunch to apply).
void floe_configure_playback(uint16_t bitrate, bool normalization, bool gapless);

/// Plays a context, e.g. {"context_uri": "spotify:playlist:…", "start_uri": "spotify:track:…",
/// "shuffle": false, "repeat": 0}, or {"tracks": ["spotify:track:…"]}.
/// Returns false for invalid JSON or when not logged in.
bool floe_load(const char *request_json);
void floe_play(void);
void floe_pause(void);
void floe_next(void);
void floe_previous(void);
void floe_seek(uint32_t position_ms);
void floe_set_shuffle(bool shuffle);
/// 0 off, 1 repeat context, 2 repeat track.
void floe_set_repeat(uint8_t mode);
void floe_set_volume(uint16_t volume);
/// Moves playback from the currently active device (e.g. a phone) to Tint.
void floe_transfer(void);
bool floe_add_to_queue(const char *uri);

/// Audio render thread only. Real-time safe. `left` and `right` must be distinct.
uint32_t floe_render(float *left, float *right, uint32_t frames);

void floe_take_stats(FloeStats *out);

/// Optional stereo tap of rendered PCM (before the Swift mixer volume). Disabled by default.
void floe_set_analysis_enabled(bool enabled);
/// Analysis queue only, never the audio render thread. Returns newest frames.
/// Arrays must be distinct and hold `capacity` floats each. Generation changes on
/// track/seek/pause and enable/disable; discard FFT history when it changes.
uint32_t floe_read_analysis(float *left, float *right, uint32_t capacity, uint64_t *generation);

#pragma clang assume_nonnull end

#endif
