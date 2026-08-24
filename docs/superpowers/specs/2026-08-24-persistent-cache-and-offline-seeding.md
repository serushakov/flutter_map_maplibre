# Persistent cache and offline region seeding — design

**Date:** 2026-08-24
**Scope:** Dart facade + `fmm_worker.cpp` protocol extension + ffigen allowlist.
No upstream (maplibre-native-ffi) changes, no native artifact rebuilds.
**Status:** proposed

## Problem

Opening the app on a subpar connection renders an empty basemap, even when
every visible tile was loaded the last time the app ran. The cause is one
line, present twice: both runtime creation sites pass `:memory:` as the cache
database path (`ffi_basemap_renderer.dart` `_acquireSharedRuntime`, iOS/sync;
`fmm_worker.cpp` `Create()`, Android worker), so MapLibre's cache dies with
the process. The README has carried this as a known gap since the spike.

The consuming app needs two behaviors, with different reasons to exist:

1. **Seeded region** — the app pre-downloads a caller-defined region at
   caller-defined zooms, so the map renders *something* immediately on next
   cold start regardless of connectivity. Because rendering is vector, a
   seeded tile is a real, usable map — not a blurry placeholder.
2. **Ambient cache** — classic LRU of whatever was loaded during browsing,
   bounded by a caller-defined disk budget.

Plus one operational requirement: a **remote kill switch**. Tiles are
deployed weekly under stable URLs; if a broken tileset ships (blank or
garbled tiles), the operator must be able to remotely force client devices
to drop their cached set and refetch. The trigger value arrives over Firebase
Remote Config, which delivers asynchronously — the mechanism must tolerate
the value changing while maps are already live.

## What upstream already provides

Both cache behaviors are **one SQLite database** in MapLibre Native, with two
retention classes, and the vendored mln C API exposes the whole machinery:

- `mln_runtime_options.cache_path` + `maximum_cache_size` (gated by
  `MLN_RUNTIME_OPTION_MAXIMUM_CACHE_SIZE`) — the durable database and the
  ambient byte cap.
- Offline regions: `mln_offline_tile_pyramid_region_definition` (style URL,
  bounds, min/max zoom, pixel ratio, ideographs) through
  `mln_runtime_offline_region_create_start` / `..._set_download_state_start`
  / `..._get_status_start` / `..._delete_start` / `..._list_start`, all async
  with completion via `MLN_RUNTIME_EVENT_OFFLINE_OPERATION_COMPLETED` and
  progress via `MLN_RUNTIME_EVENT_OFFLINE_REGION_STATUS_CHANGED` on the same
  event queue the renderers already poll. A region download fetches tiles
  **and** the style, glyphs, and sprites — without which a vector map renders
  nothing.
- Region resources are pinned (exempt from ambient eviction); ambient
  resources evict LRU under the byte cap.
- Maintenance: `mln_runtime_run_ambient_cache_operation_start`
  (reset / pack / invalidate / clear) and
  `mln_runtime_offline_region_invalidate_start`.
- Cache-first-with-revalidate is upstream default behavior: cached resources
  — including expired ones — are served immediately while the network
  refreshes them. Goal 1's UX therefore falls out of durability alone;
  seeding only widens what "cached" covers.

The work is: plumbing a real path, extending the Android worker protocol,
regenerating bindings (the offline **functions** are absent from
`ffigen.yaml`'s allowlist — the structs and enums are already generated),
and a Dart facade.

## How the one database behaves (semantics the design leans on)

### Everything is keyed by URL

The cache's primary key is the literal resolved URL of each resource. All
sharing and all busting behavior follows from this one fact:

- **Dark/light style pairs dedup for free.** Both styles resolve their
  sources to tile URL templates; identical templates produce byte-identical
  per-tile URLs, hitting the same rows. The megabytes (tiles) are stored
  once; only the style JSONs, sprites, and (usually shared) glyphs differ.
  There is no "these styles share a source" logic anywhere — one table, one
  key. Regions pin by reference (region ↔ resource join), so a second region
  over the same bounds for the other theme downloads only the delta, and
  deleting one region never strands the other's resources.
- **Identical means character-identical.** A per-style API key or reordered
  query param in the tile URL means a full second copy. Theme pairs must
  share tile source URLs exactly.

### Styles: offline-capable, revalidated on opportunity

A style JSON is an ordinary resource row (`MLN_RESOURCE_KIND_STYLE`). On
every style *load* (map create, dark/light swap, purge nudge) the cached
copy — even expired — is handed to the renderer immediately, and if expired
and online, a conditional request races behind it. A 304 refreshes the
expiry; a 200 re-parses and applies the updated style in place on the live
map, without refetching sources shared with the old style. A live map does
not poll the style mid-session; launches and theme swaps are the
opportunities.

### Server-side invariants

The design leans on three properties of the tile/style hosting, recorded
here because breaking them silently degrades the caching story:

1. **Stable tile URLs.** Versioning is expressed through HTTP cache headers
   and (for emergencies) the cache key below — never URL rotation.
2. **Theme pairs share tile source URLs**, character-identical.
3. **Style JSON served with short max-age (or `no-cache`) + etag.** It is a
   tiny file; making every launch a 304 check is what carries routine style
   updates to devices. Tiles get long max-age.

### URL migration is the one non-self-healing case

If the style JSON is updated server-side to point at *new tile URLs*, the
ambient cache self-heals (offline, the cached old style references the
cached old tiles — internally consistent; online, both refresh), but a
seeded region stays pinned to the old URLs and silently contributes nothing
while occupying disk. There is no cheap client-side heal — source check 0.2
below showed region downloads reuse whatever the database already holds and
never revalidate — so the answer is the blunt one that already exists: flip
the cache key, or delete and recreate the region. Server-side invariant 1
exists precisely so this stays a never-event.

## Public API

### Cache configuration — process-level, not per-widget

Runtimes are shared (per-thread on iOS; one per worker on Android), so cache
path and budget are runtime config, not widget config. Making them
`MapLibreBasemap` parameters would invite two widgets disagreeing about the
same database.

```dart
/// Call once, before the first MapLibreBasemap is built or any offline
/// call is made. Throws StateError if a runtime already exists.
MaplibreCache.configure(
  directory: appSupportDir.path,      // caller-owned; no path_provider dep
  maxAmbientBytes: 50 * 1024 * 1024,  // ambient (evictable) budget
);
```

Unconfigured behavior stays exactly today's `:memory:` — no silent writes to
a default location the caller never chose. The database lives at
`<directory>/maplibre_cache.db`. A maintenance passthrough `pack()` is
exposed; there is no public `clearAll()` — the cache key (below) is the
single destructive path — and no `invalidateAmbient()`: source check 0.2
showed invalidated rows are *withheld from rendering while offline* (blank
map until revalidated online), the opposite of this package's purpose.

### Cache key — the remote kill switch

```dart
/// Callable at any time, any number of times, idempotent. Completes when
/// the purge (if any) has been committed.
await MaplibreCache.setCacheKey(String? key);
```

The key is an opaque token compared for **difference** against a persisted
copy (equality, not ordering — a rollback to an older value still triggers).
A changed key means "what you have cached is suspect" and triggers a **full
destructive purge**:

1. List regions and capture their definitions.
2. Delete every region (unpins their resources — `CLEAR` alone cannot touch
   region-pinned rows).
3. Clear the ambient cache (now everything is deletable).
4. Recreate the regions from the captured definitions and activate their
   downloads, so seeds rebuild from the (fixed) server as connectivity
   allows.
5. Nudge every live map — two calls per renderer, because source check 0.1
   found neither suffices alone. Re-issue `set_style_url` with the current
   URL: no layer at or below the C API dedupes equal URLs, so style JSON,
   TileJSON, sprites and glyphs all re-fetch — but the render side keeps its
   in-memory tiles (the reparsed tileset compares value-equal, so the tile
   pyramid is never cleared). Then `mln_render_session_clear_data`, which
   empties the render sources so the next update re-creates them with empty
   pyramids and every visible tile re-fetches; then request repaint. The
   nudge must call the renderer directly — `MapLibreBasemap` dedupes equal
   URLs at the widget layer.

Purge-only, deliberately: routine freshness flows through HTTP revalidation
(the server-side invariants above), so the key exists solely for the
shipped-broken-tiles incident, and an emergency brake does not need a gentle
setting. An invalidate-severity tier was considered and dropped — with
stale-serving, invalidation would keep showing garbled tiles to offline and
slow-network users, which is exactly the failure being fought. One code path
also means the rarely-exercised emergency path is the same path as any
locally-triggered clear, so it stays tested.

**Mid-flight tolerance** (the Firebase Remote Config flow: launch with
defaults or last-activated config, fetch asynchronously, possibly activate a
new key while maps are live):

- Called before any runtime exists → record intent; the purge runs at first
  runtime creation, before anything is served.
- Called mid-flight → the purge runs immediately on the utility runtime
  (below). The purge is retroactive by construction: it removes every row
  present at that moment, including tiles fetched since launch, and anything
  fetched afterwards comes from the fixed server. No window for a bad tile
  to survive as "fresh".
- Unchanged key → no-op, so calling it on every Remote Config activation is
  free and needs no app-side bookkeeping.
- **Crash ordering:** the new key is persisted only *after* the purge
  sequence commits. A crash mid-purge re-runs it on next launch
  (at-least-once; re-running is safe — captured definitions are re-read from
  whatever regions still exist). The persisted key lives in a small
  package-owned prefs file next to the database — not inside it, so it
  survives the purge itself.
- `null` → the feature is off; real-key → `null` does nothing ("stopped
  managing", not "bust").

Accepted consequences, stated so they are not rediscovered as surprises:

- A flip is a **full re-download** — every seed rebuilds from scratch and
  ambient starts empty. Acceptable for a rare event; the key is not a thing
  to wire to release automation.
- Devices offline at flip time go blank until they next reach the server; a
  device offline across the whole incident window renders the broken seed
  until then. Inherent to any client-side mechanism.

### Offline seeding

```dart
final region = await MaplibreOffline.createRegion(
  styleUrls: [lightStyleUrl, darkStyleUrl], // seed both themes as a unit
  bounds: LatLngBounds(sw, ne),             // flutter_map types at the boundary
  minZoom: 6,
  maxZoom: 14,
  maxTiles: 4000,                           // Dart-side guard, see below
  pixelRatio: devicePixelRatio,             // affects raster sub-resources only
);

region.progress.listen((p) {
  // p.completedTiles / p.requiredTiles / p.completedBytes / p.isComplete
});
await region.whenComplete;

final regions = await MaplibreOffline.listRegions();
await MaplibreOffline.deleteRegion(id);
int estimate = MaplibreOffline.estimateTileCount(bounds, minZoom, maxZoom);
```

Semantics carried straight from the C API: `createRegion` issues
`region_create_start` per style URL and immediately
`set_download_state(ACTIVE)`; progress is the status-changed event stream;
`whenComplete` resolves on `status.complete` across the set. Download
continues while the app runs regardless of whether a map widget is live.

`styleUrls` takes a list because "seed my map" almost always means both
themes, and forgetting dark is exactly the bug someone ships (first offline
cold start happens at night, in dark mode, against a light-only seed). The
primitive stays one-region-per-style underneath; the wrapper creates the
pair as a unit — one handle, combined progress, deleted together. Thanks to
URL-keyed dedup the second theme costs kilobytes.

**No `refreshRegion`.** The obvious implementation — invalidate +
re-activate — was refuted by source check 0.2: `OfflineDownload` decides
per resource on `length(data)` alone (`offline_database.cpp:580`), so
re-activation after invalidate completes instantly with **zero** network
requests; and it builds its requests without conditional headers
(`offline_download.cpp:455-519` bypasses `MainResourceLoader`), so it could
never get 304 economics anyway. Worse, invalidated rows stop rendering
offline until revalidated online. Routine freshness therefore stays with
HTTP revalidation on the render path; the emergency stays with the cache
key. Re-activating an existing region (`createRegion` over the same
definition, or resuming after a kill) remains valid — it tops up *missing*
rows and is near-free when nothing is missing, which the probe observed.

**Tile budget.** The C API surfaces a tile-count-limit-exceeded *event* but
no limit *setter* (the native ceiling is upstream's default). So
"acceptable amount of tiles" is enforced Dart-side: `estimateTileCount` is
pure Web-Mercator arithmetic (unit-testable), `createRegion` throws before
touching native when the estimate exceeds `maxTiles`, and the native limit
event is still surfaced as a terminal error on `progress`. The budget
applies to the **union** across `styleUrls` (shared-source pairs are
estimated once); native per-region status counters will still report each
region's full requirement even though disk is shared — do not "fix" that
discrepancy later. The byte budget from `configure` governs only the ambient
class; region bytes are bounded by the tile budget. Tiles for seeded, bytes
for ambient — the only shape the native layer supports, and it matches the
two knobs as originally framed.

**Estimate imprecision, accepted:** sources whose max zoom is below the
requested `maxZoom` make the estimate an over-count (fails safe); glyphs and
sprites are not counted (bounded, small).

## Where offline operations execute

The mln API is owner-thread affine, so `MaplibreOffline` needs a runtime it
may legally call. The original draft proposed a dedicated utility runtime on
both platforms; the probe (below) killed that on iOS: **the mln runtime is
one-per-thread** — a second `mln_runtime_create` on the Dart main thread
returns `MLN_STATUS_INVALID_STATE` (this is why `FfiBasemapRenderer` shares
one refcounted runtime already). Revised topology:

- **iOS:** offline operations run on the **renderers' shared runtime**, on
  the UI thread. The event-consumer entanglement this was feared to cause is
  already solved by the pump's routing: map-sourced events go to their
  renderer via `_liveByMap`, and everything else — the runtime-scoped
  offline events — goes to a registered hook (`runtimeEventHook`, added and
  probe-validated). `MaplibreOffline` registers the hook, holds a runtime
  user-refcount while downloads or purges are active (so disposing the last
  map does not tear the runtime down mid-download), and drives its own slow
  pump timer while active, since the renderers' ticker parks on idle.
- **Android:** a dedicated worker thread — `fmm_worker.cpp` grows an
  *offline mode*: a `Worker` created without map/session (skip
  `mln_map_create`/`fmm_attach`), driven by new commands. A separate thread
  makes a separate runtime legal there.

All cache-key purge steps run through `MaplibreOffline`'s runtime path —
never through the render-worker render protocol — so `setCacheKey` has one
code path whether or not maps are live. Consequence of the revised topology:
the multi-connection SQLite question is now **Android-only** (where two live
maps already mean two runtimes on one file today, before offline work adds
any).

## Probe results (2026-08-24, iPhone 17 Pro simulator, debug build)

`OfflineCacheProbe` (`lib/src/ffi/offline_cache_probe.dart`, driven from the
example app via `--dart-define=FMM_AUTO_PROBE=true`) ran the machinery
end-to-end against the live shared runtime. All legs passed:

- **Durable cache**: `MaplibreCache.configure` + real path → runtime create
  OK, map renders, database on disk grew to ~20.5 MB.
- **Region seeding**: create → take-result → set-observed →
  set-download-state(ACTIVE), every status 0; Tallinn ±0.015°/±0.03°,
  z12–14 downloaded 20/20 tiles, **416 resources** (style, glyphs, sprites
  dominate — ~19.6 MB for 20 vector tiles), `complete: true` in seconds.
  Status/completion events routed cleanly through the renderer pump's hook
  while the map stayed live.
- **Offline cold start** (the headline): relaunch of the same install with
  `mln_network_status_set(OFFLINE)` before any runtime — the map rendered
  the seeded Tallinn fully, labels included, purely from the database.
- **Offline region re-create**: the probe's create-on-every-launch ran
  while offline and completed 20/20 instantly by pinning already-present
  resources — re-activation tops up only missing rows (resume semantics;
  see the no-`refreshRegion` note for why this is not a refresh).

### Android leg (2026-08-24, Pixel 6 API 33 emulator, debug build)

The worker create command gained `cache_path` + `max_cache_size`
(`fmm_worker_post_create` → `Command` → `mln_runtime_options`), plumbed from
`MaplibreCache` through `WorkerLink.postCreate`. All legs passed:

- **Two workers, one file — the spec's risk 1**: first map (Tallinn, light)
  live, second map pushed (Helsinki, dark) — two worker threads, two mln
  runtimes, both writing the same `maplibre_cache.db`. Database grew
  normally (0.77 → 1.7 MB), rolling journal active, zero mbgl/SQLite errors
  in logcat (the only "database is locked" noise was Google Play services'
  own phenotype.db). Pop back and pan the first map: still clean.
- **Offline cold start through the worker path**: force-stop, `svc wifi
  disable` + `svc data disable` (real device-level offline, not the mln
  flag), cold start — Tallinn renders fully from the worker's file-backed
  cache.
- **MAP_IDLE under real offline**: requests fail fast, the map idles and
  the ticker parks (`idleEvents: 7, parks: 6`) — confirming finding 3 below
  is specific to the mln network-status flag (never-started requests), not
  offline in general. The production concern narrows to: don't hold
  `mln_network_status_set(OFFLINE)` for long stretches on battery.

Risk 1 is therefore **retired**: both topologies in the revised design are
device-validated. What remains before building the facade is ordinary
implementation work, not concurrency archaeology.

Findings that changed the plan or need carrying forward:

1. **One-runtime-per-thread** → iOS utility runtime impossible; topology
   revised as above. (`runtimeEventHook`, `sharedRuntimeForProbe`,
   `pumpSharedRuntimeForProbe` on `FfiBasemapRenderer` are the seams.)
2. **Linker dead-strips unreferenced mln symbols**: `mln_network_status_*`
   lives in an archive member the `-u _mln_ffi_symbol_keeper` anchor does
   not reach; each such symbol needs its own `-u` in the podspec (done for
   the network pair — audit any future dlsym-only symbol the offline
   facade calls, and remember a podspec edit needs a manual `pod install`).
3. **Forced-offline starves MAP_IDLE**: with network status OFFLINE, online
   requests never start and never fail, the map never reaches
   `RenderMode::Full`-idle, so the ticker never parks (`parks: 0`,
   `tickerActive: true` for the whole session). The ticker-gate spec's
   "failed tiles still idle" reasoning covers failing requests, not
   never-started ones. Real offline devices fail fast, so this may be
   simulator-flag-specific — but verify on hardware, and consider the
   insurance-pump/park interaction if the app ever drives
   `mln_network_status_set` in production.
4. **Simulator app process quirks**: `Platform.environment` is unusable for
   test flags (`HOME` is null, `SIMCTL_CHILD_*` did not surface); the
   example uses a flag file next to the database instead, and derives the
   cache directory from `Directory.systemTemp.parent`.

## Source checks (2026-08-24, vendored mbgl in maplibre-native-ffi)

Three read-the-source verifications ran before facade work; two changed the
design:

- **0.1 same-URL style reload — PARTIAL.** Nothing dedupes on URL equality
  from `mln_map_set_style_url` down (`map.cpp:2847`,
  `style_impl.cpp:65-68`), and a 304 on the style JSON cannot suppress the
  reparse (`priorData` folded back in `online_file_source.cpp:537-544`).
  But the render side keeps its tiles: `diffSources` matches by id+type
  (`style_diff.cpp:50-55`) and the value-equal tileset skips
  `TilePyramid::clearAll` (`render_tile_source.cpp:593-609`). Hence the
  two-call purge nudge with `mln_render_session_clear_data`
  (`render_orchestrator.cpp:855-880` resets `sourceImpls` → every render
  source recreated with an empty pyramid). Session owner thread only.
- **0.2 invalidate — refuted `refreshRegion`, banned `invalidateAmbient`.**
  The SQL preserves data/etags (`UPDATE ... expires=0, must_revalidate=1`,
  `offline_database.cpp:710-794`) and the *render* path revalidates with
  real 304s — but `OfflineDownload` checks `length(data)` only
  (`offline_database.cpp:580`, `offline_download.cpp:482-511`) and sends no
  conditional headers, so invalidate + re-activate is a zero-request no-op.
  And invalidated rows fail `Response::isUsable` (`response.hpp:44`), so
  they stop rendering offline — a blank seeded region until connectivity.
  No product path calls INVALIDATE, ever.
- **0.3 resource-transform ordering — CONFIRMED.** The cache is keyed by
  the pre-transform, pre-normalization URL: DB read and write-back use the
  caller's resource (`main_resource_loader.cpp:48-87`),
  `offline_database.cpp:482` binds that URL, and the transform mutates a
  request-local copy (`online_file_source.cpp:595-598`). Dark/light dedup
  holds exactly as designed.

## Android worker protocol changes

New commands (same FIFO, no coalescing — offline ops are cheap to *post*;
the work is native-async):

| command | payload |
|---|---|
| `kOfflineCreate` | creates runtime only (no map/session) |
| `kOfflineRegionCreate` | style URL, bounds, zooms, pixel ratio |
| `kOfflineSetDownloadState` | region id, active/inactive |
| `kOfflineRegionsList`, `kOfflineRegionDelete`, `kOfflineRegionGetStatus` | region id where applicable |
| `kOfflineAmbientOp` | one of reset/pack/clear (invalidate exists in the enum but is never sent — check 0.2) |
| `kOfflinePump` | drains events, posts progress |

New completion kinds (mirrored in Dart, same discipline as the existing
`kCreated…kDestroyed` block): `kOfflineOpCompleted` (operation id, kind,
status, plus flattened result — region info list for list/create),
`kOfflineRegionStatus` (region id + the `mln_offline_region_status`
counters), `kOfflineRegionError` (region id, reason). Snapshot/list handles
(`take_result`, `snapshot_get`, `list_destroy`) are consumed entirely
worker-side; only plain values cross the port — the existing protocol's
rule.

The facade drives `kOfflinePump` on the same timer it uses on iOS, so both
platforms share one Dart state machine over a `WorkerLink`-style seam
(`OfflineLink`), fake-injectable exactly like the render worker's — the
download state machine and the purge sequence get tested without native
code.

The purge nudge for live maps rides the existing style-change plumbing
(in-place `set_style_url`, already a supported path with repaint and ticker
restart) plus one new render-worker command, `kClearData`
(`mln_render_session_clear_data`, legal only on the session's owner thread
— which is exactly the worker thread). iOS calls both directly on the
renderer.

## ffigen additions

Add to `functions.include` and regenerate: the
`mln_runtime_offline_region_*_start/take_result` family (create, get,
regions_list, get_status, set_download_state, delete, update_metadata),
`mln_runtime_run_ambient_cache_operation_start`,
`mln_runtime_offline_operation_discard`,
`mln_offline_region_snapshot_get/destroy`,
`mln_offline_region_list_count/get/destroy`,
`mln_network_status_set/get`, and `mln_render_session_clear_data` (the
purge nudge — same translation unit as the session functions already
reached by dlsym, but if lookup ever throws, it needs its own podspec `-u`
like the network pair did). (iOS calls these from Dart; Android calls them
from `fmm_worker.cpp`, which includes the header directly — but the bindings
must still carry the structs' current layout, which they already do.)

## Changes to the two `:memory:` sites

- `_acquireSharedRuntime` (iOS/sync): read path + byte cap from
  `MaplibreCache`; unconfigured → `:memory:` as today.
- `fmm_worker.cpp Create()`: `cache_path` and `maximum_cache_size` become
  fields on the create command, passed through `fmm_worker_post_create`
  (two new parameters on the FFI signature; `WorkerLink.postCreate` gains
  them). Dart fills them from `MaplibreCache`.

## Risks and open questions

1. **Multiple connections to one SQLite file — RETIRED.** iOS shares one
   runtime (probe-validated); Android's two-workers-one-file case ran clean
   on the emulator (see probe results): normal growth, no lock errors, no
   corruption. The offline worker's third connection is the same shape.
   The `OfflineLink` seam still exists as the fallback boundary if hardware
   ever disagrees with the emulator.
2. **Same-URL style reload must not short-circuit — RESOLVED (partial).**
   See source check 0.1: no dedupe anywhere, but a bare reload keeps
   in-memory tiles, so the nudge is `set_style_url` +
   `mln_render_session_clear_data` + repaint. One Dart-side trap survives:
   `MapLibreBasemap` itself dedupes equal URLs at the widget layer
   (`maplibre_basemap.dart:230`), so the nudge goes through the renderer,
   never a widget rebuild.
3. **Region delete must actually release pinned bytes for the subsequent
   clear** — the delete→clear ordering must leave no orphaned rows. The
   on-device gate asserts this with a byte count, not an assumption.
4. **Resource-transform ordering — RESOLVED.** See source check 0.3: the
   cache key is the pre-transform URL, so a transform *can* decouple cache
   identity from physical endpoint (canonical URL in the style, real
   endpoint applied at request time) if deliberate URL churn ever needs a
   client-side answer. Not used in this design (invariant 1 forbids churn).
5. **Style-server coupling.** A seeded region hard-codes its style URLs;
   apps rotating style URLs (cache-busting params) silently stop matching.
   Covered by server-side invariant 1; recovery is the cache key (see the
   URL-migration section).
6. **Eviction vs. the byte cap.** `maximum_cache_size` governs ambient only;
   total disk = ambient cap + region bytes. `listRegions` exposes per-region
   `completedBytes` so the caller can display and manage the real total.

## Not in scope

Background/OS-scheduled downloads (caller's job — the API is resumable via
`setDownloadState`), raster fallback on style-load failure (separate README
item), merge-database import of pre-built packs (API exists; add later if
the host app ships packs), attribution (unchanged, still owed).

## Test plan

- **Pure Dart:** tile-count estimator against hand-computed pyramids
  (antimeridian, high-latitude bounds, union across shared-source style
  pairs); facade state machine over a fake `OfflineLink` with scripted
  completions — create→active→progress→complete, delete-while-active, budget
  rejection, limit-exceeded surfacing, the full purge sequence, key
  comparison including crash-ordering (key persisted only after commit) and
  mid-flight arrival. Same pattern as the existing suite.
- **On device (the gate):**
  - *Risk-1 probe first:* two runtimes, one database, concurrent
    ambient writes + region download, no corruption or lockups.
  - Seed a region over Tallinn on wifi → force-quit → airplane mode → cold
    start → the seeded area renders fully, labels included, at seeded zooms.
  - Ambient: browse an unseeded area → restart offline → last-viewed area
    renders.
  - Byte cap: fill past `maxAmbientBytes`, confirm eviction spares the
    region.
  - Kill switch: flip the key with a map live → tiles visibly re-render
    fresh; verify the database was emptied (byte count) and seeds rebuilt;
    flip while offline → blank basemap, self-heals on connectivity.
