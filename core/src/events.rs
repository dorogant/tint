//! librespot `PlayerEvent`s as the JSON events the Swift side decodes
//! (see `Sources/Floe/Core/CoreEvent.swift`).

use librespot_metadata::audio::{AudioItem, UniqueFields};
use librespot_playback::player::PlayerEvent;
use serde_json::{Value, json};

pub fn player_event(event: &PlayerEvent) -> Option<Value> {
    Some(match event {
        PlayerEvent::Loading {
            track_id,
            position_ms,
            ..
        } => json!({ "type": "loading", "uri": track_id.to_uri(), "position_ms": position_ms }),
        PlayerEvent::Playing {
            track_id,
            position_ms,
            ..
        } => json!({ "type": "playing", "uri": track_id.to_uri(), "position_ms": position_ms }),
        PlayerEvent::Paused {
            track_id,
            position_ms,
            ..
        } => json!({ "type": "paused", "uri": track_id.to_uri(), "position_ms": position_ms }),
        PlayerEvent::Seeked {
            track_id,
            position_ms,
            ..
        }
        | PlayerEvent::PositionCorrection {
            track_id,
            position_ms,
            ..
        } => json!({ "type": "position", "uri": track_id.to_uri(), "position_ms": position_ms }),
        PlayerEvent::Stopped { track_id, .. } => {
            json!({ "type": "stopped", "uri": track_id.to_uri() })
        }
        PlayerEvent::EndOfTrack { track_id, .. } => {
            json!({ "type": "end_of_track", "uri": track_id.to_uri() })
        }
        PlayerEvent::Unavailable { track_id, .. } => {
            json!({ "type": "unavailable", "uri": track_id.to_uri() })
        }
        PlayerEvent::TrackChanged { audio_item } => track(audio_item),
        PlayerEvent::ShuffleChanged { shuffle } => json!({ "type": "shuffle", "shuffle": shuffle }),
        PlayerEvent::RepeatChanged { context, track } => {
            let mode = if *track { 2 } else if *context { 1 } else { 0 };
            json!({ "type": "repeat", "mode": mode })
        }
        _ => return None,
    })
}

fn track(item: &AudioItem) -> Value {
    let (artists, album): (Vec<Value>, Option<&str>) = match &item.unique_fields {
        UniqueFields::Track { artists, album, .. } => (
            artists
                .0
                .iter()
                .map(|a| json!({ "name": a.name, "uri": a.id.to_uri() }))
                .collect(),
            Some(album.as_str()),
        ),
        UniqueFields::Local {
            artists, album, ..
        } => (
            artists.iter().map(|name| json!({ "name": name })).collect(),
            album.as_deref(),
        ),
        UniqueFields::Episode { show_name, .. } => (vec![json!({ "name": show_name })], None),
    };
    let cover = item.covers.iter().max_by_key(|c| c.width).map(|c| c.url.as_str());
    json!({
        "type": "track",
        "uri": item.uri,
        "name": item.name,
        "artists": artists,
        "album": album,
        "duration_ms": item.duration_ms,
        "explicit": item.is_explicit,
        "cover_url": cover,
    })
}
