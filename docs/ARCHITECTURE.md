# Architecture

## Components

- **iOS app:** SwiftUI, SwiftData, CloudKit private database, AVPlayer-based playback, local downloads, transcript UI.
- **Backend:** Vapor + Postgres. Stores public podcast metadata, episode metadata, transcript/chapter/fingerprint artifacts, and anonymous demand counters.
- **Mac worker:** Swift command-line worker that polls backend for prioritized work, downloads audio, transcribes locally, and uploads artifacts.

## Privacy model

Backend does not have user accounts for MVP. It never stores subscriptions, playlists, playback position, queue contents, search history, or listening history. The only demand signal is an anonymous counter incremented when a client asks whether an episode has a transcript/chapter/fingerprint artifact.

## Audio pipeline

Use `AVPlayer` first for streaming, downloaded file playback, background audio, route changes, AirPlay, lock screen controls, and buffering. Use `AVPlayerItem.audioTimePitchAlgorithm = .timeDomain` and set `rate` for high-speed playback. If quality above 3x is not good enough, add a custom `AVAudioEngine` path later.

## Episode intelligence pipeline

1. Parse RSS/Atom feeds into stable podcast/episode records.
2. Clients request artifacts for episodes they view/listen to; this increments anonymous demand.
3. Worker claims highest-priority missing artifacts.
4. Worker downloads audio, fingerprints rendition, transcribes locally, chapterizes, and uploads artifacts.
5. iOS app displays transcript/chapters and can seek by segment.
