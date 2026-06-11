# 02 — Widgets (WidgetKit)

**Depends on:** 01 (App Group + shared state).
**Effort:** Medium (2–3 days).
**Platforms:** iOS Home Screen, iOS Lock Screen, StandBy; same target reused for macOS
(plan 06) and the Live Activity (plan 03).

## Widgets to ship

1. **Now Playing** (systemSmall, systemMedium, accessoryRectangular, accessoryInline)
   - Artwork, episode title, podcast title, progress bar.
   - Tap → deep link into Now Playing screen.
   - Play/pause + skip buttons via `AppIntent` (interactive widgets, iOS 17+). Pairs with
     plan 04 intents.
2. **Up Next / Continue Listening** (systemMedium, systemLarge)
   - Top N from queue / continue-listening, each row tappable to start playback (intent).
3. **Lock Screen accessory** (accessoryCircular progress ring + accessoryInline) — the
   modern replacement for "complications" on iPhone. (True watch complications are out of
   scope per the roadmap; Apple Watch app deferred.)

## Architecture

- New target `PodcatcherWidgets` (Widget Extension) in `project.yml`:
  ```yaml
  PodcatcherWidgets:
    type: app-extension
    platform: iOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.nagel.podcasts.widgets
    entitlements:
      properties:
        com.apple.security.application-groups: [group.com.nagel.podcasts]
    dependencies:
      - target: PodcatcherKit
  ```
  Embed in the `Podcasts` app target.
- `TimelineProvider` reads `SharedStateReader.current()` and `.librarySnapshot()` from the
  App Group — **no network calls in the widget**. Backend fetches stay in the main app;
  the widget only renders the snapshot.
- Artwork rendered from the App Group cached file (written by the writer in plan 01).
  Never load remote images in the extension timeline.

## Refresh strategy

- Widgets are timeline-driven, not live. The progress bar uses
  `Text(timerInterval:)` / `ProgressView(timerInterval:)` so it animates between reloads
  without burning timeline budget.
- Main app calls `WidgetCenter.shared.reloadAllTimelines()` on: play, pause, track change,
  queue change, significant seek. (Hook into `SharedStateWriter`.)
- Provide a near-future timeline entry so a paused/stale widget still looks right.

## Interactive controls

- Buttons use `Button(intent:)` with `PlayPauseIntent`, `SkipForwardIntent`,
  `SkipBackIntent` from plan 04. These run in the app's background context; the intent
  mutates playback and rewrites the shared snapshot, then reloads timelines.
- If plan 04 isn't done yet, ship read-only widgets first and add buttons after.

## Deep linking

- `widgetURL(URL)` per entry, scheme e.g. `podcatcher://episode/<stableID>` and
  `podcatcher://nowplaying`. Handle in `PodcastsSceneDelegate` (`scene(_:openURLContexts:)`)
  → route through `RootTabController`.

## Implementation steps

1. Add the widget target + App Group entitlement in `project.yml`; add `PodcatcherKit` dep.
2. Build `Provider: TimelineProvider` (placeholder, snapshot, timeline) reading shared state.
3. Build SwiftUI views per family; respect `widgetRenderingMode` for tinted/accessory.
4. Add `widgetURL` deep links; implement URL handling in the scene delegate.
5. Add `WidgetCenter` reloads in `SharedStateWriter`.
6. (After plan 04) add `Button(intent:)` controls.
7. Test: each family in widget gallery, Lock Screen accessories, StandBy, deep links,
   stale/paused states.

## Risks / notes
- Widget extension memory budget is tight — keep artwork pre-downscaled in the App Group.
- `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` is on; share an asset
  catalog or duplicate the placeholder art into the widget target.
- Accessory widgets must look correct in `.accented`/`.vibrant` rendering modes.
