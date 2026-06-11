# 06 — Mac App

**Depends on:** 01 (shared `PodcatcherKit` module). Strongly coordinate with 07 (iCloud
sync) — a Mac app is only compelling if the library syncs.
**Effort:** Medium–Large (1–2 weeks depending on approach).

## The approach decision

The iOS app is **UIKit scene/tab-controller shell + SwiftUI views** (`RootTabController`,
SwiftUI screens). Three options:

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Mac Catalyst** ("Optimize for Mac") | Reuse the entire iOS target, fastest path, one codebase | UIKit-isms, some AppKit polish needs `NSObject`/plugins; AVPlayer + MediaPlayer carry over | **Recommended primary path** |
| **Native SwiftUI macOS target** | Best Mac feel (menus, multiple windows, sidebar) | Rebuild the UIKit shell (`RootTabController`, scene delegates, mini player) in SwiftUI/AppKit; more code | Consider later if Catalyst feels off |
| **Designed for iPad on Apple Silicon** | Zero work | No Mac affordances, can't customize | Stopgap only |

**Recommendation:** Ship **Mac Catalyst** first (reuses playback, downloads, SwiftData,
backend, and the new shared module wholesale), then selectively replace shell pieces with
AppKit/SwiftUI Mac idioms.

> Deployment-target note: iOS target is `26.1`. Catalyst "Optimize for Mac" maps iOS 26 →
> macOS 26 (Tahoe). The repo already has a separate macOS 15.0 target (`WorkerMonitor`), but
> that's unrelated. Decide the Catalyst minimum macOS explicitly in `project.yml`.

## Catalyst plan

### Target setup (`project.yml`)
- Add Mac Catalyst as a destination of the existing `Podcasts` target
  (`SUPPORTS_MACCATALYST: YES`, `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER`, set
  `MACOSX_DEPLOYMENT_TARGET`/Catalyst SDK appropriately). XcodeGen supports this via
  `supportedDestinations` / `SUPPORTS_MACCATALYST`.
- Same App Group + (later) iCloud entitlements as iOS.

### What needs Mac-specific handling
- **Scene/window:** `PodcastsSceneDelegate` works under Catalyst; add a window size,
  toolbar, and consider a sidebar layout instead of the bottom tab bar for the Mac idiom
  (`UISplitViewController` / SwiftUI `NavigationSplitView`) — phase 2.
- **Mini player & Now Playing:** AVPlayer + `MPNowPlayingInfoCenter`/Remote Command Center
  already work on Mac. Verify media key handling.
- **Downloads:** `LocalMediaCache` + App Group container path differs on Mac — verify
  container URL resolution and background URLSession behavior under Catalyst.
- **HealthKit:** the app links HealthKit (sleep recovery). **Not available on Catalyst** —
  guard all HealthKit usage behind `#if !targetEnvironment(macCatalyst)` (and `canImport`)
  so the Mac build compiles and the sleep-recovery feature degrades gracefully.
- **BackgroundTasks (`BGTaskScheduler`):** behaves differently on Mac; gate/adjust the
  refresh scheduling.
- **Menus:** add a real menu bar (`UIMenuBuilder`) — Playback (play/pause, skip, speed),
  Library, View — for a credible Mac app.
- **Widgets/Live Activity:** WidgetKit widgets (plan 02) appear in macOS Notification Center;
  Live Activities are iOS-only (skip on Mac).

## Implementation steps
1. Enable Mac Catalyst on the `Podcasts` target in `project.yml`; set Mac deployment target.
2. Make it **compile**: guard HealthKit, audit `#available`/`targetEnvironment` for any
   iOS-only APIs; fix `BGTaskScheduler` usage.
3. Get playback + library browsing working end-to-end on Mac.
4. Add menu bar commands and a window toolbar.
5. Phase 2: sidebar/split layout; AppKit polish (resizable, multiple windows if desired).
6. Verify App Group + downloads + Now Playing + widgets on macOS.
7. Coordinate release with iCloud sync (07) so the Mac shows the same library.

## Risks / notes
- **HealthKit + BackgroundTasks are the main compile blockers** under Catalyst — plan for
  conditional compilation from the start.
- Catalyst signing/notarization differs from iOS App Store; update the release scripts
  (`scripts/testflight-build.sh` is iOS-only — a Mac build/notarize path is needed).
- Without iCloud sync the Mac app starts with an empty library — that's why 06 and 07 ship
  together for a good first-run.
