# Velocity-Aware Lead-Biased Over-Render — Design

Date: 2026-07-24
Branch: `power-saving` (worktree `.claude/worktrees/maplibre-perf`)
Package: `packages/flutter_map_maplibre`

## Context

With the power-saving frame cap active, some Flutter frames display a *stale*
native frame, placed exactly by `residualTransform`. Under pure translation the
stale frame is pixel-correct everywhere it has content — but it has no content
for the strip of viewport newly exposed at the leading edge of motion. That
strip is the **under-render** artifact.

Where it bites, by the numbers (~393×852 logical viewport):

- **GPS-follow at bus speed** (~11 px/s at z16): inter-present drift at cap-60
  is ~0.2 px — invisible with zero margin. Not the problem.
- **Manual fling** (2000–3000 px/s): at cap-60 on a 120 Hz panel, every capped
  frame is ~8 ms stale → a 16–25 px blank strip. Clearly visible. This is the
  battle.
- **Future drift-based admission ("B")**: renders seconds apart during follow
  → tens of px of drift between admissions. This design's runway machinery is
  what will make B viable; B itself is out of scope here.

The existing `overRenderFactor` renders the camera centered in an enlarged
texture, so a symmetric margin hangs on all four sides. Motion consumes margin
on only one side; the trailing margin is wasted. Biasing the *rendered camera*
ahead along the motion vector repositions the whole margin budget in front of
travel — same texture size, roughly double the usable runway.

## Success criteria

1. With the frame cap at 60 fps on a 120 Hz display, a fling-heavy scripted
   soak shows **zero uncovered viewport pixels** (`underRenderPx == 0`) with
   bias on, and demonstrably nonzero with bias off (proving the metric works).
2. No render-cost or behavior change when the feature is inert (cap off, or
   cap ≥ display refresh rate, or `overRenderFactor == 1.0`).
3. The bias never fights the park logic: a settled camera parks exactly as it
   does today.

## Design

### 1. Velocity estimator (package-internal, no new API)

Each build where the camera center moved, update an EMA velocity vector in
**screen px/s** from the delta between successive build cameras
(screen-projected centers; dt from frame timestamps). No app-supplied hint:
the follow tween and flings are both smooth curves, so differentiation off
build cameras is clean, and it covers every motion source uniformly.

- Velocity is expressed in the current camera's screen space, so bearing and
  zoom are inherently accounted for.
- EMA time constant ~100 ms: smooths pan jitter, tracks a fling's decay within
  a few frames.
- When no camera change is observed for a frame, the estimate is left alone
  (see hysteresis below — the applied bias freezes anyway).

### 2. Lead bias

```
maxBias      = 0.85 × (renderSize − viewport) / 2      // per axis, logical px
desiredBias  = clamp(velocity × leadTime, maxBias)
leadTime     = 2 × frameCap                            // ~33 ms at cap-60
```

- `leadTime` covers the worst staleness window (one cap interval) plus
  estimator lag, with 2× headroom.
- The 0.85 safety factor keeps a sliver of trailing margin so an abrupt
  reversal doesn't under-render on the very next capped frame.
- At `overRenderFactor` 1.15 the total margin is anisotropic — ~59 px
  horizontally, ~128 px vertically on the ~393×852 viewport. Fully
  lead-biased, that covers a ~2000 px/s fling at cap-60 comfortably on the
  vertical axis (the dominant fling direction) and just about horizontally,
  degrading gracefully (thin sliver) above that.

### 3. Hysteresis, not decay

The **applied** bias updates only when it differs from the desired bias by
more than a quantum (~8 px, either axis). When motion stops, the applied bias
**freezes** — it is never decayed toward zero.

Rationale: a stale bias is harmless (the rendered content is correct wherever
the margin sits), whereas decaying it would keep changing the rendered camera
on an otherwise still map, forcing renders and vetoing the ticker park. Freeze
is what keeps this feature invisible to `decideSleep`.

### 4. Rendered camera and placement

When the feature is active, the camera handed to `BasemapRenderer.render()` is
the existing `cropCamera(camera, visibleRect)` with its center shifted by the
applied bias (via `screenOffsetToLatLng`).

Placement needs no new math:

- On success, `lastRenderedCamera` is the biased camera (ground truth, as
  today). Whenever the rendered camera differs from the current build camera —
  bias, capped frame, or failure — placement goes through `residualTransform`,
  which is already exact for any rendered/current pair.
- The identity `placed` fast path remains for the unbiased-success case.

### 5. `underRenderPx` diagnostic

New diagnostic: whenever a displayed frame's rendered camera differs from the
current camera, compute in Dart the uncovered viewport area — the widest blank
strip in px between the viewport rect and the placed texture rect. Report the
max observed since the last diagnostics poll as `underRenderPx` in the
diagnostics map; the soak JSONL picks it up automatically alongside the
existing `mln` keys.

This is the acceptance instrument for criterion 1, and later the regression
metric for B.

### 6. Activation rule and host app wiring

The feature (margin + bias) is active **only when the frame cap is below the
display's maximum refresh rate**:

```dart
final refresh = View.of(context).display.refreshRate; // iOS: maximumFramesPerSecond
final capFps  = 1000 / frameCap.inMilliseconds;
final factor  = powerSavingActive && capFps < refresh ? 1.15 : 1.0;
```

- Cap off → every displayed frame is fresh (same-frame render); margin buys
  nothing and would cost +32 % area per render at up to ~118 renders/s. Inert.
- Cap 60 on a 60 Hz panel → the map keeps up with the screen; no stale frames
  to cover. Inert. (Occasional phase-jitter capped frames are a single 16 ms
  stale frame — same artifact class as ordinary jank; not worth margin.)
  Non-ProMotion devices — also the GPU-weaker ones — thus never pay for the
  margin at all.
- Cap 60 on a 120 Hz panel → active at 1.15.

The factor lives in the host app's wiring (`MaplibreBasemapLayer`), not the package:
`overRenderFactor` stays a plain constructor parameter, tunable per app.
Package-side, bias is inert whenever the margin is zero
(`overRenderFactor == 1.0` → `maxBias == 0`), with no separate flag.

Changing power-saving mode changes the factor and therefore **recreates the
map session** (the texture size is fixed at create; ~seconds of style reload).
Accepted: mode changes are rare (manual toggle, or OS battery-saver flip in
auto mode).

## Non-goals

- Drift-threshold render admission (B) — separate battle, separate spec.
- Dynamic margin resizing — texture size is fixed per session by design.
- App-supplied velocity hints — YAGNI until the estimator demonstrably fails.
- Caps below 60 fps — unlocked by this machinery but validated later with B.

## Edge cases

- **Pinch zoom / rotation**: residual placement stays geometrically exact, but
  label sizing distorts with zoom delta — unchanged from today's capped
  behavior. Bias is a pure translation and neither helps nor hurts here.
- **Reversal mid-fling**: the 15 % trailing reserve plus hysteresis absorb
  gentle reversals fine. A hard fling reversal is a harder case: it starts
  from a fully wrong-way EMA, and at the host app's numbers the trailing reserve is
  only ~4 px horizontally (15 % of the ~28 px half-margin), while swinging
  the bias to the new direction takes ~70-100 ms (the EMA time constant).
  Bared strips of ~10 px can plausibly appear on a handful of capped frames
  during that swing. This is not yet measured — to be quantified by adding a
  fling-reversal stretch to the device soak leg. Tuning (e.g. a faster EMA
  on sign flip) is deferred until the soak gives real numbers.
- **Park interaction**: freeze-not-decay guarantees the rendered camera stops
  changing when the build camera does; `decideSleep` sees exactly today's
  inputs.
- **`fixedViewport`**: bias composes with `cropCamera` — it shifts the crop
  center; the visible-rect math is untouched.

## Testing

Unit (pure, no FFI):

- Estimator: constant-velocity camera sequence → estimate converges to truth;
  jittery pan → EMA stays bounded; direction reversal → sign flips within the
  time constant.
- Bias: clamped to `maxBias`; `leadTime` scaling; zero when margin is zero.
- Hysteresis: sub-quantum desired-bias changes leave applied bias untouched;
  motion stop freezes it (no further rendered-camera changes).
- Placement: for a biased rendered camera, `residualTransform` maps shared
  ground points of rendered → current screens exactly (reuse the existing
  transform test harness).
- `underRenderPx`: known camera pairs → known strip widths; zero when the
  bias covers the drift.

Widget (fake renderer):

- Capped frame under simulated fling with bias active → `underRenderPx == 0`;
  with factor 1.0 → nonzero.
- Settled camera with frozen bias → ticker parks (canSleep path unchanged).

Device acceptance:

- Fling-heavy scripted soak at cap-60 on the iPhone 14 Pro (120 Hz):
  `underRenderPx` 0 with bias, nonzero without; renders/s unchanged vs cap-60
  baseline (bias must not add renders).
