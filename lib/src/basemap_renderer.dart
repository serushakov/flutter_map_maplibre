import 'package:flutter_map/flutter_map.dart';

/// What the ticker should do this frame.
enum TickDecision {
  /// Map is settled: no pending update event, no repaint request.
  skipIdle,

  /// A camera render already produced this frame's pixels; rendering again
  /// would be the same content at ~2ms a pop. Frame-granular — the wall-clock
  /// suppression window from the channel era died with the race.
  skipRenderedThisFrame,

  render,
}

/// The idle/suppression gate, pure so it is testable without FFI. Idle wins
/// over suppression so `skippedTicks` counts idle frames the way the channel
/// implementation did.
TickDecision decideTick({
  required bool updateAvailable,
  required bool needsRepaint,
  required bool renderedSinceLastTick,
}) {
  if (!updateAvailable && !needsRepaint) return TickDecision.skipIdle;
  if (renderedSinceLastTick) return TickDecision.skipRenderedThisFrame;
  return TickDecision.render;
}

/// Whether the ticker may park. Idle must have been observed since the last
/// camera jump: flags alone can look clear while tiles for a new camera are
/// still loading (partial render with no repaint requested) — MAP_IDLE is
/// the renderer's own "that frame was final" and only it opens the gate.
/// [unpublishedJump] vetoes the park when the last camera jump's render or
/// present failed: the screen still shows the old camera, so parking would
/// freeze the fallback frame with no flag the insurance pump can see, and
/// sleep stays vetoed until a successful render publishes it.
bool decideSleep({
  required bool idleSinceLastJump,
  required bool updateAvailable,
  required bool needsRepaint,
  required bool unpublishedJump,
}) =>
    idleSinceLastJump && !updateAvailable && !needsRepaint && !unpublishedJump;

/// Whether the power-saving frame cap allows presenting a new frame now.
/// A null cap (power saving off) always allows.
bool frameCapSatisfied({
  required Duration? frameCap,
  required Duration sinceLastPresent,
}) => frameCap == null || sinceLastPresent >= frameCap;

/// The native renderer as the basemap widget sees it. One implementation
/// talks FFI ([FfiBasemapRenderer]); tests inject a fake. The defining
/// property: [lastRenderedCamera] is ground truth for what the front buffer
/// shows — measured, never estimated.
abstract interface class BasemapRenderer {
  /// True after a successful [create] and before [dispose].
  bool get isReady;

  /// The camera the published front buffer was rendered for, or null before
  /// the first successful render. Unlike the channel era's `_rendered` stamp,
  /// this is written only after the render + present actually completed.
  MapCamera? get lastRenderedCamera;

  /// Creates runtime, map, and render session, attaching the borrowed back
  /// texture. Synchronous on iOS (the future completes before it returns);
  /// a worker-thread round-trip on Android. Returns false on failure
  /// (details land in [diagnostics]).
  Future<bool> create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  });

  /// Synchronously renders and presents [camera]. Returns true when the front
  /// buffer now shows it (including the no-op case where it already did).
  bool render(MapCamera camera);

  /// Ticker hook: pump events, apply [decideTick], render+present if due.
  /// Returns true when a new frame was presented (callers rebuild so the
  /// transform stays true to the new content).
  bool tick();

  /// True when the map has reported MAP_IDLE since the last camera jump and
  /// no update or repaint is pending: the widget's ticker may stop. A camera
  /// jump, [setStyle], or [pumpWork] finding work clears the latch so this
  /// turns false again. Implementations must also return false when the
  /// session is not ready. Stopping and restarting the ticker is the
  /// widget's job — this getter only reports, it does not wake anything
  /// itself.
  bool get canSleep;

  /// Insurance-pump hook: drains the runtime event queue WITHOUT rendering
  /// and reports whether work appeared (update available or repaint needed).
  /// Owner-thread tasks (tile expiry refreshes) only progress when the queue
  /// is pumped, so a parked widget calls this on a slow timer.
  bool pumpWork();

  /// Minimum interval between presented frames (the power-saving ~60fps
  /// cap), or null for uncapped. A capped attempt renders nothing and
  /// leaves its work pending: the camera stays jumped-but-unpublished
  /// (which vetoes parking) and the update/repaint flags stay set, so the
  /// next eligible tick or build render lands it.
  ///
  /// The window is measured start-to-start (admission to admission), not
  /// present-to-present, so it does not double-count the GPU-blocking
  /// render+blit time. A failed render also consumes the window; the
  /// tick-driven retry may therefore be deferred by up to one cap interval,
  /// which is acceptable.
  abstract Duration? frameCap;

  /// Swaps the style in place. No-op when not ready.
  void setStyle(String styleUrl);

  /// Set by the widget from TickerMode: true while an opaque route covers
  /// the map (subtree muted). While covered, a cache-purge nudge is
  /// deferred instead of applied — a muted map consumes no repaints, and a
  /// half-applied nudge leaves the texture presenting pre-purge pixels
  /// indefinitely (the blit re-presents the undrawn framebuffer and the
  /// settle guard then reports the camera as already rendered).
  abstract bool coveredForCachePurge;

  /// True when a cache purge landed while [coveredForCachePurge] was set;
  /// consumes the flag. The widget calls this on refocus and, when true,
  /// recreates the whole session — the cold-start path, which provably
  /// renders the post-purge truth.
  bool flushCachePurgeNudge();

  Map<String, Object?> diagnostics();

  /// Destroys session, map, and runtime on the calling (UI) thread.
  void dispose();
}
