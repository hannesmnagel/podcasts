# Sync and Identity

## Client-private sync

SwiftData models are mirrored to the user's private CloudKit database:

- subscriptions
- playlists
- queue
- playback positions
- downloaded episode state
- per-user settings such as playback speed
- bookmarks/highlights later

The backend cannot see this data.

## Podcast identity

`podcastID = SHA256(normalized feed URL)`.

Normalization lowercases scheme/host, removes fragments, and trims whitespace. Redirect canonicalization may be stored separately, but original feed URLs remain valid aliases.

## Episode identity

`episodeID = SHA256(podcastID + normalized episode GUID if present, otherwise canonical audio URL/title/published date fallback)`.

Audio URL changes must not change the episode ID if GUID is stable.

## Artifact ownership

- Server owns public podcast/episode records and shared artifacts.
- Client owns user-specific state.
- Worker owns artifact production attempts.

## Demand signal

`POST /episodes/:id/artifact-requests` increments anonymous counters. It has no account ID and no durable user identifier.
