# 01 — Foundation: App Group + Shared State

**Status:** prerequisite for plans 02, 03, 04, 05.
**Effort:** Small (½–1 day).
**Why:** Widgets, Live Activities, App Intents, and CarPlay run in separate processes (or
need to read state without launching the UI). They cannot reach `PlayerController` or the
SwiftData main context directly. We need a small, well-defined slice of shared state in an
App Group, plus a shared Swift module that all targets link against.

## Deliverables

1. App Group `group.com.nagel.podcasts` enabled on the main app (and every future
   extension).
2. A shared Swift framework/target `PodcatcherKit` (or a shared sources folder) holding:
   - `SharedPlaybackState` — Codable snapshot of what's playing.
   - `SharedLibrarySnapshot` — lightweight list of subscriptions + queue/continue-listening
     for widgets and CarPlay.
   - The data-transfer types that need to cross process boundaries (`EpisodeDTO`,
     `PodcastDTO` move here, or are mirrored).
3. A writer used by the main app and a reader used by extensions.

## Design

### App Group container
- `project.yml` → main `Podcasts` target entitlements:
  ```yaml
  com.apple.security.application-groups:
    - group.com.nagel.podcasts
  ```
- Add the same group to the App ID in the developer portal (or let automatic signing do it).

### Shared state location
Two channels, used for different things:

| Need | Mechanism |
|------|-----------|
| Tiny, hot "now playing" snapshot read by widget/Live Activity | `UserDefaults(suiteName: "group.com.nagel.podcasts")` JSON blob |
| Larger library/queue lists read by CarPlay & widget configuration | JSON file in the App Group container (`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`) |
| Downloaded audio files reachable from extensions | Move/ensure `LocalMediaCache` writes into the App Group container so CarPlay/widgets can resolve local URLs |

> Note: SwiftData itself *can* be pointed at the App Group container (relevant to plans
> 06/07). For 01 we deliberately keep the shared surface small and Codable rather than
> sharing the whole store — it keeps extensions cheap and avoids schema coupling.

### `SharedPlaybackState`
```swift
public struct SharedPlaybackState: Codable, Sendable, Equatable {
    public var episodeStableID: String?
    public var podcastStableID: String?
    public var title: String
    public var podcastTitle: String
    public var artworkFileURL: URL?      // resolved into App Group container
    public var isPlaying: Bool
    public var elapsed: TimeInterval
    public var duration: TimeInterval?
    public var speed: Double
    public var updatedAt: Date
}
```

### Writer (main app)
- New `SharedStateWriter` in the shared module.
- Subscribe to `PlayerController`'s published properties (`currentEpisode`, `isPlaying`,
  `elapsed`, `duration`, `speed`) in `RootTabController` (alongside the existing
  `observePlaybackPersistence()`), debounced (~1–2 s for elapsed; immediate on
  play/pause/track change).
- Persist artwork into the App Group container so the widget can render it without network.
- Call `WidgetCenter.shared.reloadAllTimelines()` on meaningful changes (track change,
  play/pause) — added in plan 02.

### Reader (extensions)
- `SharedStateReader.current() -> SharedPlaybackState?`
- `SharedStateReader.librarySnapshot() -> SharedLibrarySnapshot?`

## Implementation steps

1. Add `PodcatcherKit` framework target to `project.yml`
   (`platform: [iOS, macOS]`, embed in app). Move `EpisodeDTO`/`PodcastDTO` and stable-ID
   hashing into it (they're currently in `BackendClient.swift`), or re-export.
2. Add the App Group entitlement to the main target in `project.yml`.
3. Implement `SharedPlaybackState`, `SharedLibrarySnapshot`, `SharedStateWriter`,
   `SharedStateReader`.
4. Point `LocalMediaCache` (and artwork caching) at the App Group container; migrate any
   existing files on first launch.
5. Wire the writer into `RootTabController`.
6. `xcodegen generate`, build, confirm the main app still runs and the snapshot file/defaults
   are written (log + inspect container).

## Risks / notes
- Moving downloaded files to the App Group container needs a one-time migration so existing
  users don't lose downloads. Guard with a `UserDefaults` migration flag.
- Keep the shared module dependency-free (no UIKit-only types in the data layer) so the Mac
  target can link it too.
- Stay within Swift 6 strict concurrency: shared types are `Sendable`; the writer is
  `@MainActor`, the reader is `nonisolated`.
