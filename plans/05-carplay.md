# 05 — CarPlay

**Depends on:** 01 (App Group + shared module), benefits from 04 (playback coordinator).
**Effort:** Medium (3–4 days), **plus Apple entitlement lead time — start now.**

## ⚠️ Do this first (blocking, has a waiting period)

CarPlay audio apps require the **`com.apple.developer.carplay-audio`** entitlement, which
must be **requested and approved by Apple** (developer.apple.com → Support → CarPlay
entitlement request). You cannot build a provisioning profile or TestFlight without it.
File the request at the very start of this whole project so it's approved by the time the
rest is built.

## Scope

CarPlay "Audio" app category. Browse + play, no custom drawing (CarPlay uses system
templates):

- **Tab bar (`CPTabBarTemplate`)** with:
  - *Subscriptions* (`CPListTemplate`, grid of shows → episode list).
  - *Up Next / Queue* (`CPListTemplate`).
  - *Continue Listening / Recents* (`CPListTemplate`).
  - *Downloads* (`CPListTemplate`, offline-playable items).
- **Now Playing** is the system `CPNowPlayingTemplate` — driven by the existing
  `MPNowPlayingInfoCenter` + Remote Command Center already configured in `PlayerController`.
  Add CarPlay-relevant buttons (speed, skip interval) via `CPNowPlayingButton`s.

## Architecture

- New scene: `CPTemplateApplicationSceneDelegate` declared in the app's
  `UIApplicationSceneManifest` (currently `UIApplicationSupportsMultipleScenes: false` — set
  to `true` and add a second scene configuration for the CarPlay role
  `CPTemplateApplicationSceneSessionRoleApplication`).
- `project.yml` Info.plist additions:
  ```yaml
  UIApplicationSceneManifest:
    UIApplicationSupportsMultipleScenes: true
    UISceneConfigurations:
      UIWindowSceneSessionRoleApplication: [ ... existing PodcastsSceneDelegate ... ]
      CPTemplateApplicationSceneSessionRoleApplication:
        - UISceneConfigurationName: CarPlay
          UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).CarPlaySceneDelegate
  ```
- `CarPlaySceneDelegate` builds templates from `SharedLibrarySnapshot` (App Group) +
  SwiftData when available; plays via the shared `PlaybackCoordinator` → `PlayerController`.
- Artwork from the App Group cached files (CarPlay needs local images, sized to its specs).

## Key behaviors

- Selecting an episode starts playback through the same path as the phone UI (reuse
  `PlayerController.play`), so Now Playing, Live Activity, and widgets all stay in sync.
- Offline awareness: when no connectivity (`NetworkMonitor`), surface Downloads prominently
  and mark un-downloaded items appropriately.
- Respect CarPlay list length limits; paginate long episode lists (`CPListTemplate`
  sections / "load more" rows).

## Implementation steps

1. **File the CarPlay entitlement request with Apple (day 1).**
2. Once approved: add `com.apple.developer.carplay-audio` to entitlements in `project.yml`.
3. Flip `UIApplicationSupportsMultipleScenes` to `true`; add the CarPlay scene config.
   Verify the existing phone scene still connects (regression risk — test on device).
4. Implement `CarPlaySceneDelegate` + tab/list templates from the shared snapshot.
5. Wire selection → `PlaybackCoordinator`; confirm `CPNowPlayingTemplate` reflects state.
6. Add Now Playing buttons (speed, skip interval).
7. Test in the CarPlay Simulator (Xcode → I/O → External Displays → CarPlay) and in a real
   vehicle/head unit if possible.

## Risks / notes
- **Multiple-scenes flip is the riskiest change** — it touches the main app's launch path.
  Test phone launch, backgrounding, state restoration thoroughly after the change.
- CarPlay enforces strict template/interaction limits; don't try to render custom UI.
- All data access must be instant (App Group snapshot) — no spinners blocking the driver.
- Entitlement approval can take days to weeks; the rest of the implementation is gated on it
  only for signing/testing on device, but you can build templates against the simulator
  earlier with a development provisioning that includes the entitlement once granted.
