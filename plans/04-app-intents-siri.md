# 04 — App Intents + Siri + Shortcuts + Spotlight

**Depends on:** 01 (App Group + shared module). Provides the intents used by 02 & 03.
**Effort:** Medium (2–3 days).
**Framework:** modern **App Intents** (not legacy SiriKit `INPlayMediaIntent`). App Intents
gives Siri, the Shortcuts app, Spotlight, Action Button, and interactive widget/Live
Activity buttons from one definition.

## Intents to ship

| Intent | Parameters | Behavior |
|--------|-----------|----------|
| `PlayPauseIntent` | — | Toggle playback (used by widget/Live Activity buttons). |
| `SkipForwardIntent` / `SkipBackIntent` | seconds (default from settings) | Seek relative. |
| `PlayLatestEpisodeIntent` | `podcast: PodcastEntity` | Play newest episode of a podcast. |
| `PlayPodcastIntent` | `podcast: PodcastEntity` | Resume / start that show. |
| `ContinueListeningIntent` | — | Resume most-recent in-progress episode. |
| `SetPlaybackSpeedIntent` | `speed: Double` | Set global speed. |
| `AddToQueueIntent` | `episode: EpisodeEntity` | Append to queue. |
| `SleepTimerIntent` | `minutes: Int` | Start sleep timer. |

`PlayLatestEpisodeIntent` / `PlayPodcastIntent` carry a custom Siri phrase via
`AppShortcutsProvider` (e.g. *"Play latest <podcast> in Podcatcher"*).

## App Entities

- `PodcastEntity: AppEntity` with an `EntityQuery` backed by `SharedLibrarySnapshot`
  (App Group) so resolution works **without launching the UI**. Falls back to SwiftData
  when the app is foreground.
- `EpisodeEntity: AppEntity` similarly, for queue/continue-listening targets.
- Provide `suggestedEntities()` (subscriptions / recent episodes) so Shortcuts and Siri
  offer good autocompletion, and `DisplayRepresentation` with artwork.

## Where the work happens

- Intents need to drive the **single** `PlayerController` instance. Two cases:
  - **App in foreground/background-audio:** route to the live `PlayerController` via the
    app delegate / a shared `@MainActor` playback coordinator.
  - **App not running (e.g. widget button, Siri cold):** intent uses
    `openAppWhenRun = true` for "play X" style intents that need full audio session +
    streaming; lightweight transport toggles (`PlayPauseIntent`) can run in-process if an
    audio session is already active, otherwise open the app.
- Add a `PlaybackCoordinator` in `PodcatcherKit` exposing the small command surface
  (toggle, skip, play(stableID), setSpeed) that both the app and intents call.

## Spotlight & discoverability

- Donate `IntentDonationManager` / use `AppShortcut` so Siri suggestions surface common
  actions.
- Index podcasts/episodes with `CSSearchableItem` (Core Spotlight) so shows are searchable
  system-wide and deep-link in. (Optional second pass.)

## Implementation steps

1. Add an **App Intents extension** target *(or)* compile intents into the app +
   `PodcatcherKit` (App Intents can live in the app target; an extension lets them run when
   the app is closed). Recommend: intents in `PodcatcherKit`, `AppShortcutsProvider` in the
   app, plus an `AppIntentsExtension` for background execution of transport intents.
2. Implement `PodcastEntity` / `EpisodeEntity` + `EntityQuery` over the App Group snapshot.
3. Implement the transport intents (`PlayPauseIntent`, skip) against `PlaybackCoordinator`.
4. Implement library intents (`PlayLatest`, `PlayPodcast`, `ContinueListening`, speed,
   queue, sleep timer).
5. Add `AppShortcutsProvider` with Siri phrases.
6. (Optional) Core Spotlight indexing of subscriptions/episodes.
7. Test: Shortcuts app, "Hey Siri" phrases, Action Button assignment, cold-start vs warm,
   widget/Live Activity buttons calling the transport intents.

## Risks / notes
- Entity resolution must not block on network. Keep it App-Group-snapshot first.
- For cold-start "play" intents, ensure the audio session + now-playing handoff is set up
  the same way as a normal launch (reuse `PlayerController.refreshSystemPlaybackIntegration`).
- Keep intent `perform()` bodies `Sendable`/strict-concurrency clean; hop to `@MainActor`
  to touch `PlayerController`.
