# core/vendor

`librespot-playback/` is librespot's playback crate, copied from the commit that
`core/Cargo.toml` pins (`e023adbb`, 2026-10-05) and built in its place through the
`[patch]` section there. Everything else in librespot still comes from that commit.

## What differs from upstream

- `src/player.rs`, `PlayerTrackLoader::load_remote_track`: the audio key is requested
  together with the file (`futures_util::future::join`), not after it has opened. A
  song that isn't preloaded starts one round trip to Spotify sooner. The gain is not
  measured: it needs a live session, which the offline tests don't have.
- `Cargo.toml`: the fields and the three sibling crates that pointed into librespot's
  workspace are written out, since the crate no longer sits in it.

`diff -ru <librespot checkout>/playback core/vendor/librespot-playback` shows exactly this.

## Moving to a newer librespot

Change the `rev` in `core/Cargo.toml` and in `librespot-playback/Cargo.toml`, copy the
new `playback/` over this folder, and make the two changes above again. If upstream
has taken the change, delete this folder and the `[patch]` section.
