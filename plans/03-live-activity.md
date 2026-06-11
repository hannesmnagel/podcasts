# 03 — Live Activity / Dynamic Island

**Depends on:** 01 (App Group), shares the widget target from 02.
**Effort:** Medium (2–3 days).
**Why:** This is the modern Lock Screen "now playing" surface and the Dynamic Island
presence. It's what users mean by "lock screen complication" for a media app.

## Scope

A single ActivityKit Live Activity for the currently-playing episode:

- **Lock Screen banner:** artwork, episode + podcast title, progress bar with elapsed/
  remaining, play/pause + skip ±30/±15 buttons.
- **Dynamic Island:**
  - *compact leading:* artwork thumbnail · *compact trailing:* play/pause.
  - *minimal:* small play state glyph.
  - *expanded:* artwork, titles, progress, transport controls.
- Tapping the activity deep-links into Now Playing (`podcatcher://nowplaying`).

## Architecture

- `ActivityAttributes` + `ContentState` defined in `PodcatcherKit` (shared module) so both
  the app (starts/updates) and the widget extension (renders) see them:
  ```swift
  public struct NowPlayingActivityAttributes: ActivityAttributes {
      public struct ContentState: Codable, Hashable {
          public var isPlaying: Bool
          public var elapsed: TimeInterval
          public var duration: TimeInterval?
          public var speed: Double
          public var updatedAt: Date
      }
      public var episodeStableID: String
      public var title: String
      public var podcastTitle: String
      public var artworkFileURL: URL?   // App Group container
  }
  ```
- The Live Activity UI lives in the **widget extension target** (`02`) via
  `ActivityConfiguration` in the same `WidgetBundle`.
- Add `NSSupportsLiveActivities = YES` to the **main app** Info.plist (`project.yml`).

## Lifecycle (owned by the main app)

- New `LiveActivityController` (`@MainActor`) observing `PlayerController`:
  - **start** when playback begins and no activity exists.
  - **update** on play/pause, track change, significant seek, speed change. Throttle elapsed
    updates (e.g. on state change + every ~15 s) — ActivityKit budget is limited.
  - **end** on stop / app teardown / episode finished.
- Use `staleDate` and `ProgressView(timerInterval:)` so the bar advances smoothly between
  updates without per-second pushes.
- Wire start/update/end next to the existing playback observers in `RootTabController`.

## Interactive buttons

- `Button(intent:)` with the same `PlayPauseIntent` / `SkipForwardIntent` /
  `SkipBackIntent` from plan 04. They mutate playback and call
  `activity.update(...)`.

## Implementation steps

1. Define `NowPlayingActivityAttributes` in `PodcatcherKit`.
2. Add `NSSupportsLiveActivities` to the app Info.plist in `project.yml`.
3. Add `ActivityConfiguration` to the widget bundle (Lock Screen + Dynamic Island regions).
4. Implement `LiveActivityController`; hook into `PlayerController` observation.
5. Wire interactive intents (after/with plan 04).
6. Test: start/stop, lock screen, Dynamic Island compact/minimal/expanded, button actions,
   staleness after backgrounding, multiple rapid track changes.

## Risks / notes
- **No remote push needed** — local updates only (we drive it from the foreground/audio
  background mode). Don't pull in APNs for this.
- ActivityKit throttles frequent updates; rely on `timerInterval` rendering, not 1 Hz pushes.
- Ensure exactly one activity at a time; reuse/replace on track change rather than stacking.
- Requires a physical device for full Dynamic Island testing.
