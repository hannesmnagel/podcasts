# Production Platform Expansion — Plan Index

Goal: take The Podcatcher from a single iOS app to a full Apple-platform product:
widgets, Live Activities, Siri/App Intents, CarPlay, a Mac app, and iCloud sync across
all of it.

## Read this first — shared facts

- **Project generation is XcodeGen.** `project.yml` is the source of truth. Every new
  target, entitlement, and Info.plist key goes in `project.yml`, then `xcodegen generate`.
  Never add targets through the Xcode UI — they will be wiped on regenerate.
- **Bundle id prefix:** `com.nagel` · main app `com.nagel.podcasts` · team `X5933694SW`.
- **Deployment targets:** iOS 26.1, macOS 15.0 (see notes in the Mac plan).
- **Swift 6, strict concurrency `complete`, default actor isolation `nonisolated`.**
- **Persistence:** SwiftData. Container built in
  `ios/PodcastsApp/App/PodcastsApp.swift` (`PodcastsAppDelegate.init`) with models:
  `PodcastSubscription`, `LocalEpisodeState`, `LocalEpisodeArtifact`, `Playlist`,
  `AppEvent`, `PodcastDailySummary`.
- **Playback:** `PlayerController` (`@MainActor ObservableObject`), a single instance owned
  by the app delegate. Remote Command Center + Now Playing info are already wired here.
- **Networking:** `BackendClient` → `https://podcasts.hannesnagel.com`. DTOs `PodcastDTO`,
  `EpisodeDTO`; stable IDs via SHA256 hashing (`stableID`).
- **Downloads:** `LocalMediaCache`; downloaded path on `LocalEpisodeState.downloadedFileURL`.
- **TestFlight:** `scripts/testflight-build.sh` (see `ios/AGENTS.md`). Don't bypass.

## Recommended build order

1. **[01 — Foundation: App Group + Shared State](01-foundation-app-group.md)**
   Unblocks every extension. Do this first.
2. **[02 — Widgets (WidgetKit)](02-widgets.md)**
3. **[03 — Live Activity / Dynamic Island](03-live-activity.md)**
4. **[04 — App Intents + Siri + Shortcuts + Spotlight](04-app-intents-siri.md)**
5. **[05 — CarPlay](05-carplay.md)** — request the entitlement from Apple in parallel
   with step 1; approval has a waiting period.
6. **[06 — Mac app](06-mac-app.md)**
7. **[07 — iCloud sync](07-icloud-sync.md)** — can start after step 1; touches the
   SwiftData schema, so coordinate with whatever else is in flight.

## Dependency graph

```
01 Foundation ─┬─> 02 Widgets ──> 03 Live Activity
               ├─> 04 App Intents ──> 05 CarPlay
               ├─> 06 Mac app
               └─> 07 iCloud sync (schema change — gate everything else's models on this)
```

## Cross-cutting risks

- **iCloud sync forces a SwiftData schema change** (drop `@Attribute(.unique)`, make
  properties optional/defaulted). If sync is on the roadmap, read plan 07 *before*
  building widgets/Mac so their data access assumptions match the final schema.
- **App Group is a hard prerequisite** for widgets, Live Activities, intents, and CarPlay
  to read playback/library state without launching the full app.
- **Entitlement lead time:** CarPlay audio requires Apple approval. File the request early.
