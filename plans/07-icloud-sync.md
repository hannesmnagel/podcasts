# 07 — iCloud Sync

**Depends on:** 01 (App Group). **Gates:** the SwiftData schema — read this before building
06 (Mac) and before any new model fields in 02–05.
**Effort:** Medium–Large (1–1.5 weeks incl. migration testing).
**Approach:** **SwiftData + CloudKit** (`ModelConfiguration(cloudKitDatabase:)`), private
database. This is the natural fit since persistence is already SwiftData.

## ⚠️ The hard constraint that drives everything

SwiftData's CloudKit mirroring imposes schema rules that the **current models violate**:

1. **No `@Attribute(.unique)`** — CloudKit doesn't support unique constraints.
   Currently used on:
   - `LocalEpisodeState.episodeStableID`
   - `PodcastSubscription.stableID`
   - `Playlist.id`
2. **Every non-optional property must have a default value** (or be optional).
3. **Relationships must be optional and have inverses.** (Models currently use string IDs,
   no relationships — fine, but keep it that way or add proper inverses.)
4. All model types must be in the synced `ModelConfiguration`.

### Consequence: uniqueness must move to app logic
Dropping `.unique` means SwiftData no longer dedupes by `stableID`. Two risks:
- Local upserts (`LibraryStore.subscribe`, episode state creation) currently rely on the
  unique constraint / fetch-by-id. They already fetch-then-update in most paths — audit
  every insert to **fetch-by-stableID first, update if present, insert only if absent**.
- CloudKit sync can still create duplicates across devices in race conditions. Add a
  **dedupe-on-merge** pass: after remote changes import, collapse records sharing a
  `stableID` (keep newest by `lastListenedAt`/`updatedAt`, merge playback position via
  max). Trigger on `NSPersistentStoreRemoteChange` / SwiftData history.

## What to sync vs. keep local

| Model | Sync? | Notes |
|-------|-------|-------|
| `PodcastSubscription` | ✅ | The library — the whole point. |
| `LocalEpisodeState` | ⚠️ partial | Sync **playback position, lastListenedAt, isPlayed, queue/sortIndex**. Do **NOT** sync `downloadedFileURL`, `cachedImageFileURL`, `cachedAt`, `isDownloaded` — those are device-local (a file on phone A isn't on Mac B). Split device-local fields out or mark them ignored. |
| `Playlist` | ✅ | |
| `AppEvent` | ❌ | Local analytics/history; high volume, device-specific. Keep in a separate non-synced store. |
| `PodcastDailySummary` | ❓ | Decide: likely local. |

**Recommendation:** use **two `ModelConfiguration`s** in one `ModelContainer`:
- a **CloudKit-synced** config for `PodcastSubscription`, `Playlist`, and a sync-only view of
  episode listening state;
- a **local-only** config for `AppEvent`, download/cache state, diagnostics.

This likely means **splitting `LocalEpisodeState`** into:
- `EpisodeListeningState` (synced: position, played, lastListenedAt, queue order), and
- `EpisodeDownloadState` (local: file URLs, isDownloaded, cache timestamps),
keyed by the same `episodeStableID`. This is the cleanest model and avoids syncing dead file
paths. Migration required.

## Entitlements / setup (`project.yml`)
```yaml
com.apple.developer.icloud-container-identifiers: [iCloud.com.nagel.podcasts]
com.apple.developer.icloud-services: [CloudKit]
com.apple.developer.ubiquity-kvstore-identifier: $(TeamIdentifierPrefix)$(CFBundleIdentifier)
aps-environment: development   # CloudKit silent-push for sync
```
- Create the CloudKit container `iCloud.com.nagel.podcasts` in the portal.
- Add `remote-notification` background mode for push-driven sync.
- Build container with:
  ```swift
  let synced = ModelConfiguration("synced", schema: syncedSchema,
                                  cloudKitDatabase: .private("iCloud.com.nagel.podcasts"))
  let local  = ModelConfiguration("local", schema: localSchema, cloudKitDatabase: .none)
  ModelContainer(for: fullSchema, configurations: synced, local)
  ```

## Migration (existing users)
- This is a **breaking schema migration** (removing `.unique`, splitting the episode model,
  defaults on all properties). Use a SwiftData `VersionedSchema` + `SchemaMigrationPlan`
  (custom migration stage) to:
  1. Move `LocalEpisodeState` rows into `EpisodeListeningState` + `EpisodeDownloadState`.
  2. Backfill defaults; preserve `episodeStableID` linkage.
- Test migration from a real pre-update store on device before shipping. Keep a backup/export
  path in case migration fails.

## Implementation steps
1. Design final schema: drop `.unique`, defaults everywhere, split episode state, choose
   synced vs local configs.
2. Write `VersionedSchema` v1 (current) → v2 (CloudKit-ready) + migration plan.
3. Add iCloud/CloudKit entitlements + container + remote-notification mode in `project.yml`.
4. Switch `ModelContainer` creation in `PodcastsAppDelegate` to dual `ModelConfiguration`s.
5. Audit + fix every insert path for manual fetch-by-id upsert (`LibraryStore`, episode
   creation, playlists).
6. Implement dedupe-on-remote-change merge pass.
7. Verify CloudKit schema in the **CloudKit Console**; promote schema to Production before
   App Store release (dev schema ≠ prod schema is a classic shipping bug).
8. Test: two devices, offline edits + merge, fresh install pulls library, migration from v1.

## Risks / notes
- **Promote the CloudKit schema to Production** before release or sync silently fails for
  real users.
- Removing `.unique` without bulletproof app-level upsert → duplicate subscriptions/episodes.
  This is the #1 failure mode; budget test time for it.
- Don't sync device-local file URLs — they're meaningless on other devices and cause "ghost
  downloads."
- CloudKit private DB requires the user be signed into iCloud; degrade gracefully when not.
- Coordinate timing: land the schema change once, then build Mac (06) and any new model
  fields (02–05) on top of v2.
