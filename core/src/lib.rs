//! Floe core: the C ABI the Swift app links against.
//!
//! The surface is deliberately small. `Sources/CFloeCore/floe_core.h` declares it
//! and must stay in sync with the `extern "C"` functions below. Everything that
//! talks to Spotify runs on a small tokio runtime owned by this crate; results go
//! back to Swift as JSON events through a single callback.
//!
//! Playback runs through librespot's Spirc: Floe is a Spotify Connect device, and
//! Spotify's own context logic (playlists, albums, queue, shuffle, repeat,
//! autoplay) drives the player, exactly as with the official clients.

mod analysis;
mod events;
mod pcm;

use std::{
    ffi::{CStr, CString, c_char, c_void},
    slice,
    sync::{
        Arc, Mutex, MutexGuard, OnceLock,
        atomic::{AtomicU16, Ordering},
    },
    time::Duration,
};

use librespot_connect::{
    ConnectConfig, LoadContextOptions, LoadRequest, LoadRequestOptions, Options, PlayingTrack,
    Spirc,
};
use librespot_core::{
    Error, SessionConfig, SpotifyUri, authentication::Credentials, config::DeviceType,
    session::Session,
};
use librespot_playback::{
    config::{Bitrate, PlayerConfig},
    mixer::{Mixer, MixerConfig, NoOpVolume},
    player::{Player, PlayerEvent, PlayerEventChannel},
};
use librespot_protocol::authentication::AuthenticationType;
use log::warn;
use serde::Deserialize;
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
    spirc: Option<Arc<Spirc>>,
    spirc_task: Option<JoinHandle<()>>,
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

    fn spirc(&self) -> Option<Arc<Spirc>> {
        self.state().spirc.clone()
    }

    /// Runs a Spirc command, logging (not surfacing) failures: they only happen
    /// when the Connect loop has already stopped, which emits `disconnected`.
    fn command(&self, f: impl FnOnce(&Spirc) -> Result<(), Error>) {
        if let Some(spirc) = self.spirc() {
            if let Err(e) = f(&spirc) {
                warn!("Spirc command failed: {e}");
            }
        }
    }

    /// Disconnects the Connect device and drops the session. Returns the new generation.
    fn teardown(&self) -> u64 {
        let (old, generation) = {
            let mut state = self.state();
            let generation = state.generation + 1;
            let fresh = State { generation, ..State::default() };
            (std::mem::replace(&mut *state, fresh), generation)
        };
        self.pcm.set_gate(false);
        self.pcm.flush();

        self.runtime.spawn(async move {
            if let Some(spirc) = old.spirc {
                let _ = spirc.shutdown(); // tells Spotify the device is gone
            }
            if let Some(task) = old.spirc_task {
                let _ = tokio::time::timeout(Duration::from_secs(3), task).await;
            }
            if let Some(events) = old.events {
                events.abort();
            }
            if let Some(session) = old.session {
                session.shutdown();
            }
            if let Some(player) = old.player {
                // Dropping the last handle joins the player thread.
                tokio::task::spawn_blocking(move || drop(player));
            }
        });
        generation
    }

    fn connect(&'static self, credentials: Credentials, volume: u16) {
        let generation = self.teardown();
        self.emit(json!({ "type": "connecting" }));
        self.runtime.spawn(async move {
            let session = Session::new(SessionConfig::default(), None);
            let pcm = self.pcm.clone();
            let player = Player::new(
                player_config(),
                session.clone(),
                Box::new(NoOpVolume), // volume is applied in AVAudioEngine
                move || Box::new(FloeSink::new(pcm)),
            );
            let player_events = player.get_player_event_channel();
            let mixer = Arc::new(FloeMixer(AtomicU16::new(volume)));

            // Spirc connects the session itself, after registering its listeners.
            let (spirc, spirc_task) = match Spirc::new(
                connect_config(volume),
                session.clone(),
                credentials,
                player.clone(),
                mixer,
            )
            .await
            {
                Ok(pair) => pair,
                Err(e) => {
                    warn!("login failed: {e}");
                    self.emit(json!({ "type": "login_failed", "message": e.to_string() }));
                    session.shutdown();
                    tokio::task::spawn_blocking(move || drop(player));
                    return;
                }
            };

            let events = self.runtime.spawn(forward_events(self, player_events));
            let spirc_task = self.runtime.spawn(async move {
                spirc_task.await;
                // The Connect loop ends on shutdown (generation moved on) or when
                // the session drops (network change, sleep); Swift reconnects.
                if self.state().generation == generation {
                    self.emit(json!({ "type": "disconnected" }));
                }
            });

            let username = session.username();
            let stored = Credentials {
                username: Some(username.clone()),
                auth_type: AuthenticationType::AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS,
                auth_data: session.auth_data(),
            };
            {
                let mut state = self.state();
                if state.generation != generation {
                    drop(state);
                    let _ = spirc.shutdown();
                    events.abort();
                    session.shutdown();
                    tokio::task::spawn_blocking(move || drop(player));
                    return;
                }
                *state = State {
                    session: Some(session),
                    player: Some(player),
                    spirc: Some(Arc::new(spirc)),
                    spirc_task: Some(spirc_task),
                    events: Some(events),
                    generation,
                };
            }

            let stored = serde_json::to_value(&stored).unwrap_or(Value::Null);
            self.emit(json!({ "type": "credentials", "credentials": stored }));
            self.emit(json!({ "type": "connected", "username": username }));
        });
    }
}

/// Holds Spotify's volume (0…65535). Both local and remote (phone) changes pass
/// through `set_volume`, so this is where Swift learns about them.
struct FloeMixer(AtomicU16);

impl Mixer for FloeMixer {
    fn open(_: MixerConfig) -> Result<Self, Error> {
        Ok(Self(AtomicU16::new(u16::MAX / 2)))
    }

    fn volume(&self) -> u16 {
        self.0.load(Ordering::Relaxed)
    }

    fn set_volume(&self, volume: u16) {
        self.0.store(volume, Ordering::Relaxed);
        if let Some(core) = CORE.get() {
            core.emit(json!({ "type": "volume", "volume": volume }));
        }
    }
}

fn player_config() -> PlayerConfig {
    PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        ditherer: None, // we output f32, which librespot never dithers anyway
        ..PlayerConfig::default()
    }
}

fn connect_config(volume: u16) -> ConnectConfig {
    ConnectConfig {
        name: "Floe".to_string(),
        device_type: DeviceType::Computer,
        initial_volume: volume,
        ..ConnectConfig::default()
    }
}

async fn forward_events(core: &'static Core, mut events: PlayerEventChannel) {
    while let Some(event) = events.recv().await {
        // Keep the gate in step with remote (phone) play/pause too.
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

/// What Swift asks to play; mirrors the Web API's `/me/player/play` body.
#[derive(Deserialize)]
struct LoadSpec {
    /// `spotify:playlist:…`, `spotify:album:…`, `spotify:artist:…`,
    /// `spotify:user:<id>:collection` (Liked Songs), …
    context_uri: Option<String>,
    /// Plain track list, used when there's no context URI.
    #[serde(default)]
    tracks: Vec<String>,
    start_uri: Option<String>,
    start_index: Option<u32>,
    #[serde(default)]
    shuffle: bool,
    /// 0 off, 1 context, 2 track.
    #[serde(default)]
    repeat: u8,
    #[serde(default)]
    position_ms: u32,
}

impl LoadSpec {
    fn into_request(self) -> Option<LoadRequest> {
        let options = LoadRequestOptions {
            start_playing: true,
            seek_to: self.position_ms,
            context_options: Some(LoadContextOptions::Options(Options {
                shuffle: self.shuffle,
                repeat: self.repeat == 1,
                repeat_track: self.repeat == 2,
            })),
            playing_track: self
                .start_uri
                .map(PlayingTrack::Uri)
                .or(self.start_index.map(PlayingTrack::Index)),
        };
        match self.context_uri {
            Some(uri) => Some(LoadRequest::from_context_uri(uri, options)),
            None if !self.tracks.is_empty() => Some(LoadRequest::from_tracks(self.tracks, options)),
            None => None,
        }
    }
}

fn init_logging() {
    let env = env_logger::Env::default().default_filter_or(
        "warn,floe_core=info,librespot_core=info,librespot_playback=info,librespot_connect=info",
    );
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
/// with the `streaming` scope, and starts the Connect device at `volume`.
/// Emits `connecting`, then `credentials` and `connected`, or `login_failed`.
///
/// # Safety
/// `access_token` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_login_token(access_token: *const c_char, volume: u16) {
    let (Some(core), Some(token)) = (CORE.get(), unsafe { str_arg(access_token) }) else {
        return;
    };
    core.connect(Credentials::with_access_token(token), volume);
}

/// Logs in with the reusable credentials from an earlier `credentials` event.
///
/// # Safety
/// `credentials_json` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_login_stored(credentials_json: *const c_char, volume: u16) {
    let (Some(core), Some(json)) = (CORE.get(), unsafe { str_arg(credentials_json) }) else {
        return;
    };
    match serde_json::from_str::<Credentials>(json) {
        Ok(credentials) => core.connect(credentials, volume),
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

/// Plays a context or track list described by JSON (see `LoadSpec`), making
/// Floe the active Connect device. Returns false if the JSON is invalid or
/// there is no session.
///
/// # Safety
/// `request_json` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_load(request_json: *const c_char) -> bool {
    let Some(core) = CORE.get() else { return false };
    let Some(request) = (unsafe { str_arg(request_json) })
        .and_then(|json| serde_json::from_str::<LoadSpec>(json).ok())
        .and_then(LoadSpec::into_request)
    else {
        return false;
    };
    let Some(spirc) = core.spirc() else { return false };
    core.pcm.flush();
    core.pcm.set_gate(true);
    // Commands are ignored unless this device is active; activating an
    // already-active device is a no-op.
    let result = spirc.activate().and_then(|()| spirc.load(request));
    if let Err(e) = &result {
        warn!("load failed: {e}");
    }
    result.is_ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_play() {
    if let Some(core) = CORE.get() {
        core.pcm.set_gate(true);
        core.command(Spirc::play);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_pause() {
    if let Some(core) = CORE.get() {
        core.pcm.set_gate(false);
        core.command(Spirc::pause);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_next() {
    if let Some(core) = CORE.get() {
        core.pcm.flush();
        core.command(Spirc::next);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_previous() {
    if let Some(core) = CORE.get() {
        core.pcm.flush();
        core.command(Spirc::prev);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_seek(position_ms: u32) {
    if let Some(core) = CORE.get() {
        core.pcm.flush();
        core.command(|spirc| spirc.set_position_ms(position_ms));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_set_shuffle(shuffle: bool) {
    if let Some(core) = CORE.get() {
        core.command(|spirc| spirc.shuffle(shuffle));
    }
}

/// 0 off, 1 repeat context, 2 repeat track.
#[unsafe(no_mangle)]
pub extern "C" fn floe_set_repeat(mode: u8) {
    if let Some(core) = CORE.get() {
        core.command(|spirc| {
            spirc.repeat(mode == 1)?;
            spirc.repeat_track(mode == 2)
        });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floe_set_volume(volume: u16) {
    if let Some(core) = CORE.get() {
        core.command(|spirc| spirc.set_volume(volume));
    }
}

/// Moves playback from whichever device is active (e.g. the phone) to Floe.
#[unsafe(no_mangle)]
pub extern "C" fn floe_transfer() {
    if let Some(core) = CORE.get() {
        core.pcm.set_gate(true);
        core.command(|spirc| spirc.transfer(None));
    }
}

/// # Safety
/// `uri` must be a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_add_to_queue(uri: *const c_char) -> bool {
    let Some(core) = CORE.get() else { return false };
    let Some(Ok(uri)) = (unsafe { str_arg(uri) }).map(SpotifyUri::from_uri) else {
        return false;
    };
    core.command(|spirc| spirc.add_to_queue(uri));
    true
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

/// Enables the optional rendered-PCM tap. Disabled by default.
#[unsafe(no_mangle)]
pub extern "C" fn floe_set_analysis_enabled(enabled: bool) {
    if let Some(core) = CORE.get() {
        core.pcm.analysis.set_enabled(enabled);
    }
}

/// Analysis queue only. Returns newest stereo frames plus a seek/track generation.
/// # Safety
/// `left` and `right` must be distinct writable arrays of `capacity` floats;
/// `generation` must point to a writable u64.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn floe_read_analysis(
    left: *mut f32,
    right: *mut f32,
    capacity: u32,
    generation: *mut u64,
) -> u32 {
    if left.is_null() || right.is_null() || generation.is_null() {
        return 0;
    }
    let Some(core) = CORE.get() else {
        unsafe { *generation = 0; }
        return 0;
    };
    let (left, right) = unsafe {
        (slice::from_raw_parts_mut(left, capacity as usize),
         slice::from_raw_parts_mut(right, capacity as usize))
    };
    let (frames, epoch) = core.pcm.analysis.read_latest(left, right);
    unsafe { *generation = epoch; }
    frames as u32
}
