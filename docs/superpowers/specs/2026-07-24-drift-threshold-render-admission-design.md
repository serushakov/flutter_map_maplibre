# Drift-Threshold Render Admission (B) — Design

Date: 2026-07-24
Branch: `power-saving` (worktree `.claude/worktrees/maplibre-perf`)
Package: `packages/flutter_map_maplibre`
Builds on: `2026-07-24-lead-biased-over-render-design.md` (C — margin, velocity
bias, `underRenderPx`)

## Context

Today every build with a changed camera admits a native render. The ride-leg
soak measured GPS-follow holding ~118 renders/s for a whole drive at ~11 px/s
of screen motion — each render redrawing an almost identical frame. The
uncapped path also produced immediate heating, hard stutters, and lingering
lag on a zoom-out → pan-to-edge → refocus gesture ("regular mode" report,
2026-07-24).

The residual transform already places a stale frame pixel-exactly under pure
translation, and C's lead-biased margin gives every rendered frame ~109 px of
usable runway ahead of motion. B exploits both: **only admit a camera-driven
render when the current frame is about to run out of runway.** Between
admissions, the residual places the existing frame — Flutter-compositor cost,
no native render.

Expected admission rates (~393×852 viewport, factor 1.20):

- GPS-follow at ~11 px/s: one render every ~8–10 s (vs 60–118/s). The
  headline battery/thermal win.
- Hard fling at ~2000 px/s: ~20 admissions/s even uncapped — each render
  buys the whole runway, so B also fixes most of the uncapped fling/animation
  heat.
- Idle: unchanged (already parks).
- Pinch: ~1 render per 0.05 zoom levels; a fast 2-level pinch ≈ 40/s,
  additionally bounded by the frame cap when power saving.

## Success criteria

1. Follow-leg soak: camera renders/s ≤ 0.5 at steady follow, with
   `underRenderPx == 0`.
2. The zoom-out → pan-to-edge → refocus gesture in regular (uncapped) mode
   no longer produces immediate heating or hard stutters (subjective device
   check plus soak thermal/renders counters).
3. Fling behavior at cap-60 remains artifact-free (`underRenderPx == 0` under
   the C acceptance flings).
4. A settled map parks exactly as today; no admission machinery keeps the
   ticker alive.

## Design

### 1. Admission gate — pure function, `render_admission.dart`

A camera-driven render is **admitted** when any of:

- **Runway low**: the current viewport comes within a **guard band
  (default 16 logical px)** of the last rendered frame's edge. Computed with
  the same 4-corner projection as `underRenderPx` — project the current
  viewport corners into the rendered canvas and take the worst per-axis
  slack; admit when `slack < guard`. (underRenderPx measures damage after
  display; this measures remaining slack before display. Shared math,
  refactored so both call one corner-projection helper.)
- **Zoom quantum**: `|zoom − renderedZoom| ≥ 0.05` levels.
- **Bearing quantum**: `|bearing − renderedBearing| ≥ 0.1°`. Coverage math
  already handles the geometric corner-baring of rotation; the quantum bounds
  label-orientation drift.
- **No rendered frame yet** (first render, or after session recreate).

A **denied** admission skips `render()` entirely; placement falls through to
the existing `residualTransform` path, which is exact for any
rendered/current pair. Under pure translation the placed frame is
pixel-identical to a fresh render (modulo the consumed margin).

Tile-content renders — the ticker's `updateAvailable`/`needsRepaint` path —
are **not** gated. Tiles arriving for the rendered camera repaint at the
rendered camera as today.

### 2. Settle render

If the camera goes quiet (unchanged for ~300 ms) while the rendered frame is
off-target in **zoom or bearing** (e.g. a pinch ended mid-quantum), admit one
exact render so the map does not rest up to 3.5 % mis-scaled (persistently
blurry labels). Pure-translation staleness needs no settle — residual
placement is exact. After the settle render the ticker parks through the
unchanged `decideSleep` path.

Implementation: on each denied build admission where zoom/bearing differ,
(re)arm a one-shot ~300 ms timer that requests one admission; any admitted
render or further camera change cancels/re-arms it. The timer fires at most
once per gesture end — it never ticks periodically, so it cannot keep the
map from parking (criterion 4).

### 3. Where the gate lives

In `MaplibreBasemap`'s build path, before `_renderer.render(target)`:

```
cropped  = cropCamera(camera, visibleRect)
target   = _biasedCamera(cropped, renderSize)      // C, unchanged
admit    = shouldAdmitRender(rendered: _renderer.lastRenderedCamera,
                             current: cropped, renderSize, guard, quanta)
rendered = admit ? _renderer.render(target) : false
```

- The gate compares the **unbiased** current camera against the last
  **rendered** (biased) camera — what matters is whether the viewport is
  still comfortably inside the rendered canvas, and `lastRenderedCamera` is
  ground truth for that canvas.
- The renderer's `frameCap` remains an independent second gate underneath:
  an admitted-but-capped render defers through the existing pending-flags
  retry. B and the cap compose; neither knows about the other.
- `decideTick`, `decideSleep`, the insurance pump, and failure retry paths
  are untouched. Fewer camera jumps only make parking easier.

### 4. Activation and margin (Vedu wiring)

B is **always on** for the vector basemap — regular mode and power saving
alike. Consequences:

- The margin goes always-on: `MaplibreBasemapLayer` passes
  `overRenderFactor: 1.20` unconditionally; the `leadMarginActive` predicate
  and its refresh-rate probe retire. Non-ProMotion devices newly pay the
  1.44× render area per admission — offset by admissions dropping ~50–100×.
- Bias `leadTime` needs a value when `frameCap` is null: constant 33 ms.
  (Bias saturates its clamp at fling speeds regardless of leadTime; at
  follow speeds bias is negligible either way.)
- Power saving keeps its 60 fps cap and its non-map savings (marker tween
  snap, LivenessDot hold) unchanged. How the two modes should differ
  long-term (tighter guard band? retire the cap?) is **deliberately
  deferred** — all knobs stay available and composable.

New `MapLibreBasemap` constructor parameters, both with defaults:
`admissionGuardPx = 16.0`, `admissionZoomQuantum = 0.05`. The bearing
quantum stays a package constant (Vedu's map does not rotate; no app-side
tuning need).

### 5. Diagnostics

- `admits` / `admissionSkips` counters in the diagnostics map (cumulative,
  like `cameraRenders`), flowing automatically into MLNDIAG lines, the
  overlay, and soak JSONLs.
- `underRenderPx` (from C) remains the artifact police.

## Non-goals

- Caps below 60 fps — B makes them plausible; validate in a separate cycle.
- Dynamic guard band / quantum tuning per mode — deferred with the mode
  question (§4).
- Gating tile-content renders — they repaint the already-rendered camera and
  are cheap relative to camera jumps; measure before touching.
- App-supplied motion hints — the runway math needs none.

## Edge cases

- **Fling reversal**: unchanged from C — the trailing reserve plus the guard
  band absorb it; the C spec's honest caveat (≈10 px strips possible for a
  few frames on a hard reversal) carries over and the soak's reversal phase
  polices it.
- **Session recreate** (style change, factor change, rotation):
  `lastRenderedCamera` resets → first build admits unconditionally. C's
  bias-reset-on-create carries over.
- **Render failure**: an admitted render that fails leaves the existing
  unpublished-jump veto and retry machinery in charge; the gate does not
  cache "admitted" state, so the next build re-evaluates from ground truth.
- **Zoom in vs out**: zoom-out bares corners fast → runway rule admits
  early on its own; zoom-in never bares → the quantum is the only zoom-in
  trigger, hence the settle render.
- **Park interaction**: denied admissions change no renderer state at all;
  the settle timer is one-shot. `decideSleep` sees exactly today's inputs.

## Testing

Unit (`render_admission_test.dart`, pure):

- Slack computation vs known camera pairs (reuse `under_render` fixtures):
  inside-with-slack → deny; within guard of an edge → admit; fully bared →
  admit.
- Zoom quantum: 0.049 deny, 0.05 admit; symmetric in sign.
- Bearing quantum: below/above epsilon.
- No rendered camera → admit.

Widget (fake renderer):

- Small pan (< runway − guard): no render call, residual placement, correct
  pixels (existing transform harness).
- Cumulative small pans crossing the guard → exactly one new render.
- Pinch past 0.05 → admit; pinch ending mid-quantum → settle render fires
  once after the quiet window, then `canSleep`.
- Uncapped + B: fling sequence admits ~per-runway, not per-frame (count
  `render()` calls).
- `admits`/`admissionSkips` counters report through diagnostics.

Device acceptance:

- Follow-leg soak (criterion 1), regular-mode gesture check (criterion 2),
  C fling re-check at cap-60 (criterion 3).
