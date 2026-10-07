//! Floe core: the C ABI the Swift app links against.
//!
//! The surface is deliberately small. `Sources/CFloeCore/floe_core.h` declares it
//! and must stay in sync with the `extern "C"` functions below. Everything that
//! talks to Spotify runs on a small tokio runtime owned by this crate; results go
//! back to Swift as JSON events through a single callback.

mod events;
mod pcm;

use std::{
    ffi::{CStr, CString, c_char, c_void},
    slice,
    sync::{Arc, Mutex, MutexGuard, OnceLock},
};

use librespot_core::{
    SessionConfig, SpotifyUri, authentication::Credentials, session::Session,
};
use librespot_playback::{
    config::{Bitrate, PlayerConfig},
    mixer::NoOpVolume,
    player::{Player, PlayerEvent, PlayerEventChannel},
};
use librespot_protocol::authentication::AuthenticationType;
use log::warn;
use serde_json::{Value, json};
use tokio::{runtime::Runtime, task::JoinHandle};

use crate::pcm::{FloeSink, Pcm};

/// Receives one JSON event; `json` is only valid during the call.
pub type EventCallback = extern "C" fn(context: *mut c_void, json: *const c_char);

struct Listener {
    callback: EventCallback,
    context: *mut c_void,
}

// SAFETY: `floe_init` requires the callback to be callable from any thread and
// the context to stay valid for the life of the process.
unsafe impl Send for Listener {}
unsafe impl Sync for Listener {}

struct Core {
    runtime: Runtime,
    listener: Listener,
    pcm: Arc<Pcm>,
    client_id: CString,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    session: Option<Session>,
    player: Option<Arc<Player>>,
    events: Option<JoinHandle<()>>,
    /// Bumped by every login and logout, so a superseded login can't install itself.
    generation: u64,
}

static CORE: OnceLock<Core> = OnceLock::new();

impl Core {
    fn emit(&self, event: Value) {
        if let Ok(json) = CString::new(event.to_string()) {
            (self.listener.callback)(self.listener.context, json.as_ptr());
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn player(&self) -> Option<Arc<Player>> {
        self.state().player.clone()
    }

    /// Stops playback and drops the session. Returns the new generation.
    fn teardown(&self) -> u64 {
        let (player, session, events, generation) = {
            let mut state = self.state();
            state.generation += 1;
            (
                state.player.take(),
                state.session.take(),
                state.events.take(),
                state.generation,
            )
        };
        self.pcm.set_gate(false);
        self.pcm.flush();
        if let Some(events) = events {
            events.abort();
        }
        if let Some(player) = player {
            player.stop();
            // Dropping the last handle joins the player thread; keep that off the caller.
            self.runtime.spawn_blocking(move || drop(player));
        }
        if let Some(session) = session {
            session.shutdown();
        }
        generation
    }

    fn connect(&'static self, credentials: Credentials) {
        let generation = self.teardown();
        self.emit(json!({ "type": "connecting" }));
        self.runtime.spawn(async move {
            let session = Session::new(SessionConfig::default(), None);
            if let Err(e) = session.connect(credentials, false).await {
                warn!("login failed: {e}");
                self.emit(json!({ "type": "login_failed", "message": e.to_string() }));
                return;
            }
            let username = session.username();
            let stored = Credentials {
                username: Some(username.clone()),
                auth_type: AuthenticationType::AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS,
                auth_data: session.auth_data(),
            };

            let pcm = self.pcm.clone();
            let player = Player::new(
                player_config(),
                session.clone(),
                Box::new(NoOpVolume), // volume is applied in AVAudioEngine
                move || Box::new(FloeSink::new(pcm)),
            );
            let events = self
                .runtime
                .spawn(forward_events(self, player.get_player_event_channel()));
            {
                let mut state = self.state();
                if state.generation != generation {
                    drop(state);
                    events.abort();
                    session.shutdown();
                    self.runtime.spawn_blocking(move || drop(player));
                    return;
                }
                state.session = Some(session.clone());
                state.player = Some(player);
                state.events = Some(events);
            }

            let stored = serde_json::to_value(&stored).unwrap_or(Value::Null);
            self.emit(json!({ "type": "credentials", "credentials": stored }));
            self.emit(json!({ "type": "connected", "username": username }));
        });
    }
}

fn player_config() -> PlayerConfig {
    PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        ditherer: None, // we output f32, which librespot never dithers anyway
        ..PlayerConfig::default()
    }
}

async fn forward_events(core: &'static Core, mut events: PlayerEventChannel) {
    while let Some(event) = events.recv().await {
        // Keep the gate in step with player-initiated state changes too.
        match event {
            PlayerEvent::Playing { .. } => core.pcm.set_gate(true),
            PlayerEvent::Paused { .. } => core.pcm.set_gate(false),
            _ => {}
        }
        if let Some(json) = events::player_event(&event) {
            core.emit(json);
        }
    }
}

fn init_logging() {
    let env = env_logger::Env::default()
        .default_filter_or("warn,floe_core=info,librespot_core=info,librespot_playback=info");
    let _ = env_logger::Builder::from_env(env)
        .format_timestamp_millis()
        .try_init();
}

/// # Safety
/// `ptr` must be null or point to a NUL-terminated string.
unsafe fn str_arg<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// Starts the core. Returns false if it was already started (the new callback
/// is then ignored).
///
/// # Safety
/// `callback` must be safe to call from any thread, and `context` must stay
/// valid for the life of the process.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_init(callback: EventCallback, context: *mut c_void) -> bool {
    let mut created = false;
    CORE.get_or_init(|| {
        created = true;
        init_logging();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("floe-core")
            .enable_all()
            .build()
            .expect("failed to start the tokio runtime");
        Core {
            runtime,
            listener: Listener { callback, context },
            pcm: Pcm::new(),
            client_id: CString::new(SessionConfig::default().client_id).unwrap_or_default(),
            state: Mutex::default(),
        }
    });
    created
}

/// The OAuth client ID librespot's session login needs (Spotify's own, not the
/// app's Web API client ID). Valid for the life of the process.
#[unsafe(no_mangle)]
pub extern "C" fn floe_session_client_id() -> *const c_char {
    CORE.get().map_or(c"".as_ptr(), |core| core.client_id.as_ptr())
}

/// Logs in with an OAuth access token issued for `floe_session_client_id()`
/// with the `streaming` scope. Emits `connecting`, then `credentials` and
/// `connected`, or `login_failed`.
///
/// # Safety
/// `access_token` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_login_token(access_token: *const c_char) {
    let (Some(core), Some(token)) = (CORE.get(), unsafe { str_arg(access_token) }) else {
        return;
    };
    core.connect(Credentials::with_access_token(token));
}

/// Logs in with the reusable credentials from an earlier `credentials` event.
///
/// # Safety
/// `credentials_json` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_login_stored(credentials_json: *const c_char) {
    let (Some(core), Some(json)) = (CORE.get(), unsafe { str_arg(credentials_json) }) else {
        return;
    };
    match serde_json::from_str::<Credentials>(json) {
        Ok(credentials) => core.connect(credentials),
        Err(e) => core.emit(json!({
            "type": "login_failed",
            "message": format!("stored credentials are unreadable: {e}"),
        })),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_logout() {
    if let Some(core) = CORE.get() {
        core.teardown();
        core.emit(json!({ "type": "logged_out" }));
    }
}

/// Loads a `spotify:track:…` or `spotify:episode:…` URI. Returns false if the
/// URI is invalid or there is no session.
///
/// # Safety
/// `uri` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_load(uri: *const c_char, play: bool, position_ms: u32) -> bool {
    let Some(core) = CORE.get() else { return false };
    let Some(Ok(uri)) = (unsafe { str_arg(uri) }).map(SpotifyUri::from_uri) else {
        return false;
    };
    let Some(player) = core.player() else {
        return false;
    };
    core.pcm.flush();
    core.pcm.set_gate(play);
    player.load(uri, play, position_ms);
    true
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_play() {
    if let Some(core) = CORE.get() {
        core.pcm.set_gate(true);
        if let Some(player) = core.player() {
            player.play();
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_pause() {
    if let Some(core) = CORE.get() {
        core.pcm.set_gate(false);
        if let Some(player) = core.player() {
            player.pause();
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_seek(position_ms: u32) {
    if let Some(core) = CORE.get() {
        core.pcm.flush();
        if let Some(player) = core.player() {
            player.seek(position_ms);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_stop() {
    if let Some(core) = CORE.get() {
        core.pcm.set_gate(false);
        core.pcm.flush();
        if let Some(player) = core.player() {
            player.stop();
        }
    }
}

/// Render-thread entry point: writes `frames` samples into each channel buffer
/// (silence where nothing is buffered) and returns how many came from Spotify.
/// Real-time safe: never blocks or allocates.
///
/// # Safety
/// `left` and `right` must be distinct buffers of at least `frames` floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_render(left: *mut f32, right: *mut f32, frames: u32) -> u32 {
    if left.is_null() || right.is_null() {
        return 0;
    }
    let (left, right) = unsafe {
        (
            slice::from_raw_parts_mut(left, frames as usize),
            slice::from_raw_parts_mut(right, frames as usize),
        )
    };
    match CORE.get() {
        Some(core) => core.pcm.render(left, right) as u32,
        None => {
            left.fill(0.0);
            right.fill(0.0);
            0
        }
    }
}

#[repr(C)]
pub struct FloeStats {
    pub frames_rendered: u64,
    pub underruns: u64,
    pub peak: f32,
    pub buffered_ms: u32,
}

/// Audio counters for diagnostics; `peak` is the max |sample| since the last call.
///
/// # Safety
/// `out` must point to a writable `FloeStats`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_take_stats(out: *mut FloeStats) {
    let (Some(core), false) = (CORE.get(), out.is_null()) else {
        return;
    };
    let s = core.pcm.take_stats();
    unsafe {
        out.write(FloeStats {
            frames_rendered: s.frames_rendered,
            underruns: s.underruns,
            peak: s.peak,
            buffered_ms: s.buffered_ms,
        });
    }
}
