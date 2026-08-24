# Task list: persistent cache + offline seeding

Companion to `2026-08-24-persistent-cache-and-offline-seeding.md`. Groundwork
already landed (uncommitted): offline ffigen bindings, `MaplibreCache.configure`
wired into both runtime creation paths, `runtimeEventHook` seam, podspec `-u`
fix, both device probes passed (spec risk 1 retired).

Order is dependency-driven; tasks within a phase are mostly parallelizable.

## Phase 0 — upstream source checks — DONE 2026-08-24 (see spec "Source checks")

- [x] **0.1** Same-URL `Style::loadURL` — **PARTIAL**: no layer dedupes and
      304s can't suppress the reparse, but in-memory tiles survive (tileset
      value-equality skips `clearAll`). Purge nudge is therefore
      `set_style_url` + `mln_render_session_clear_data` + repaint, called on
      the renderer (the widget layer dedupes equal URLs).
- [x] **0.2** `invalidate*` — **refuted `refreshRegion`**: `OfflineDownload`
      checks `length(data)` only and sends no conditional headers
      (invalidate + re-activate = zero-request no-op), and invalidated rows
      stop rendering offline. `refreshRegion` cut from the API; INVALIDATE
      never called in product paths; `invalidateAmbient()` not exposed.
- [x] **0.3** Resource transform — **confirmed**: cache keyed by the literal
      pre-transform URL; dark/light dedup holds as designed.

## Phase 1 — pure Dart foundations — DONE 2026-08-24

- [x] **1.1** `estimateTileCount` (`lib/src/offline/tile_count.dart`): pure
      Web-Mercator, antimeridian split capped at row width, Mercator-limit
      clamp; hand-computed pyramid tests in `test/tile_count_test.dart`
      (union semantics live in the facade: the estimate is per-pyramid and
      is *not* multiplied by style count).
- [x] **1.2** Model types (`lib/src/offline/offline_types.dart`):
      `OfflineRegionDefinition` (double zooms — mirrors the native struct,
      value-equal for purge round-trips), `OfflineRegionProgress` (mirrors
      `mln_offline_region_status`, `+` sums a style pair),
      `OfflineRegion` (group id + summed snapshot), `TileBudgetExceeded`.
- [x] **1.3** `OfflineLink` seam (`lib/src/offline/offline_link.dart`):
      command methods with caller `requestId`s + sealed `OfflineEvent`
      completions (created/list/deleted/ambient/status/error/failed);
      handles consumed implementation-side, plain values only across the
      boundary; `AmbientCacheOp` enum has no INVALIDATE (check 0.2).

## Phase 2 — iOS path (machinery already probe-proven)

- [x] **2.1** `FfiOfflineLink` (`lib/src/offline/ffi_offline_link.dart`):
      commands over the shared runtime, events via `runtimeEventHook`,
      pending-op table keyed by native operation id, snapshot/list/status
      handles consumed in-file; `pump()` delegates to the renderer's new
      static `pumpSharedRuntime()` (works with zero live renderers via
      static scratch).
- [x] **2.2** Runtime user-refcount:
      `FfiBasemapRenderer.acquireRuntimeUser()/releaseRuntimeUser()`
      (creation refactored into `_ensureSharedRuntime`); the link holds one
      user start→dispose, and the facade disposes the link only when all
      requests and downloads drain — so an active download outlives the
      last map, and an idle app keeps today's teardown.
- [x] **2.3** `MaplibreOffline` facade (`lib/src/offline/maplibre_offline.dart`):
      `createRegion` (budget check, group-id metadata, one native region
      per style, observe+activate, rollback on partial failure,
      `OfflineRegionHandle` with combined progress + `whenComplete`),
      `listRegions` (metadata grouping, summed status snapshots),
      `deleteRegion` (whole group; aborts an active handle), fatal
      tile-limit errors fail the handle. Android factory throws until
      phase 3.
- [x] **2.4** 12 facade tests over `FakeOfflineLink`
      (`test/maplibre_offline_test.dart`): create→progress→complete, pair
      accounting, budget rejection pre-native, fatal + non-fatal errors,
      delete-while-active, unknown delete, list grouping incl. foreign
      regions, rollback on failed second create, start failure, idle
      teardown asserted via `link.disposed`. Suite: 137 green.
- [x] **2.5** iOS simulator smoke (2026-08-24, iPhone 17 Pro sim): example's
      cache FAB now drives the real facade; auto-run seeded the light+dark
      pair as one unit — combined progress streamed to completion,
      `listRegions` returned one group (2 styles, 40/40 tiles, 572/572
      resources, 27.2 MB counted / 20.3 MB on disk — URL dedup visible),
      and the same install relaunched with the offline flag rendered
      Tallinn fully from the seed (ticker even parked: a complete seed
      reaches idle offline, softening probe caveat 3).
      **Race found & fixed on device:** a fully-deduped member can complete
      inside one synchronous pump batch before `createRegion` finishes its
      ack sequence, then never emits again — first surfaced as a
      permanently-incomplete pair. Fix: register the group (event routing)
      *before* observe/activate, plus a status-snapshot prime per member;
      regression-tested with an instantly-complete fake link.

## Phase 3 — Android offline worker

- [x] **3.1** `OfflineWorker` in `fmm_worker.cpp`: dedicated map-less owner
      thread + own runtime; commands create/regionCreate/setObserved/
      setDownloadState/list/delete/getStatus/ambient (reset/pack/clear
      only)/pump/destroy via `fmm_offline_*` entry points; typed
      completions (kinds 100–108, incl. strings + metadata bytes over the
      port); worker-side pending-op table, snapshot/list handles consumed
      worker-side; self-pumps at 50ms while ops are in flight so acks
      don't wait on Dart's slow timer. (`kClearData` on the render worker
      moved to phase 4 with the purge nudge.)
- [x] **3.2** `WorkerOfflineLink` (`lib/src/offline/worker_offline_link.dart`)
      decodes the port messages back into `OfflineEvent`s; facade picks
      `WorkerOfflineLink` on Android, `FfiOfflineLink` elsewhere. Same
      facade state machine, zero Android-specific logic above the link.
- [x] **3.3** Emulator smoke (2026-08-24, Pixel 6 API 33): facade-driven
      pair seed on the offline worker while a map rendered on a render
      worker (two runtimes, one DB) — identical results to iOS (40/40
      tiles, 572/572 resources, one grouped region); cold start with
      wifi+data disabled renders Tallinn from the seed, ticker parks.

## Phase 4 — cache key (purge-only)

- [ ] **4.1** Key persistence: package-owned prefs file next to (not inside)
      the DB; read at startup; write only after a purge commits
      (at-least-once semantics).
- [ ] **4.2** `MaplibreCache.setCacheKey(String?)`: equality not ordering;
      null = feature off; callable pre-runtime (records intent, sweeps at
      first runtime creation); idempotent; tolerates mid-flight arrival
      (Remote Config lands after maps are live) and key changes while a
      purge is already running.
- [ ] **4.3** Purge sequence: capture region definitions → delete regions
      (CLEAR can't touch pinned rows) → ambient CLEAR → recreate +
      reactivate seeds → persist key → nudge every live renderer:
      same-URL `set_style_url` + `mln_render_session_clear_data` + repaint
      (per 0.1; renderer-level, not widget — the widget dedupes; ffigen
      addition needed for `clear_data` on iOS, `kClearData` command on
      Android).
- [ ] **4.4** Tests: crash-ordering (key persisted only post-commit → rerun
      is safe), mid-flight key switch, purge-while-download-active,
      no-op when key unchanged.

## Phase 5 — hardening + polish

- [ ] **5.1** Ambient byte-cap eviction check on device: small
      `maxAmbientBytes`, pan far, DB stays bounded, pinned region tiles
      survive.
- [ ] **5.2** Example app: replace `OfflineCacheProbe` UI with the real
      `MaplibreOffline` API (seed button, region list, progress, cache-key
      switch); drop or de-export `offline_cache_probe.dart` from the public
      surface (keep `forceOffline` somewhere test-only).
- [ ] **5.3** Docs: README caching section (configure, seeding, cache key,
      server-side invariants: stable tile URLs, theme pairs sharing
      character-identical source URLs, style JSON no-cache+etag); dartdoc on
      the public API.
- [ ] **5.4** Full sweep: `dart format`, `flutter analyze`, full test suite,
      both-platform manual smoke; commit(s).

## Carried caveats

- Don't hold `mln_network_status_set(OFFLINE)` long-term on battery — under
  the flag the iOS ticker starves MAP_IDLE parking.
- Any new dlsym-only mln symbol needs its own podspec `-u` flag **and** a
  manual `pod install` in `example/ios`.
