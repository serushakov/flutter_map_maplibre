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
bool decideSleep({
  required bool idleSinceLastJump,
  required bool updateAvailable,
  required bool needsRepaint,
}) => idleSinceLastJump && !updateAvailable && !needsRepaint;

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

  /// Creates runtime, map, and render session on the calling (UI) thread,
  /// attaching the borrowed back texture. Returns false on failure (details
  /// land in [diagnostics]).
  bool create({
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
  /// jump, [setStyle], or [pumpWork] finding work wakes it back up.
  bool get canSleep;

  /// Insurance-pump hook: drains the runtime event queue WITHOUT rendering
  /// and reports whether work appeared (update available or repaint needed).
  /// Owner-thread tasks (tile expiry refreshes) only progress when the queue
  /// is pumped, so a parked widget calls this on a slow timer.
  bool pumpWork();

  /// Swaps the style in place. No-op when not ready.
  void setStyle(String styleUrl);

  Map<String, Object?> diagnostics();

  /// Destroys session, map, and runtime on the calling (UI) thread.
  void dispose();
}
