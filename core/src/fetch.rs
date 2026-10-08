use std::time::Duration;

use librespot_audio::AudioFetchParams;

fn params(read_ahead: Duration) -> AudioFetchParams {
    // This pinned player also uses the during-playback window as its blocking
    // startup threshold. One second fits in the decoder's initial 64 KiB block
    // even at 320 kbps. Adaptive CDN prefetch remains enabled with its defaults.
    AudioFetchParams {
        read_ahead_during_playback: read_ahead,
        ..AudioFetchParams::default()
    }
}

pub fn configure() {
    // A bounded diagnostic override permits comparison against upstream's 5 s
    // default without rebuilding. Normal launches use 1 s.
    let milliseconds = std::env::var("FLOE_AUDIO_READ_AHEAD_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| (1000..=5000).contains(value))
        .unwrap_or(1000);
    if AudioFetchParams::set(params(Duration::from_millis(milliseconds))).is_err() {
        log::warn!("Audio fetch parameters were already initialized");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shorter_startup_keeps_decoder_blocks_and_network_recovery() {
        let tuned = params(Duration::from_secs(1));
        let defaults = AudioFetchParams::default();
        assert_eq!(tuned.read_ahead_during_playback, Duration::from_secs(1));
        assert_eq!(tuned.minimum_download_size, 64 * 1024);
        assert_eq!(tuned.minimum_throughput, defaults.minimum_throughput);
        assert_eq!(tuned.download_timeout, defaults.download_timeout);
        assert_eq!(tuned.prefetch_threshold_factor, defaults.prefetch_threshold_factor);
        assert_eq!(tuned.maximum_assumed_ping_time, defaults.maximum_assumed_ping_time);
    }
}
