import 'dart:math' as math;
import 'dart:ui';

/// Positions the fixed over-render margin ahead of camera motion.
///
/// Estimates the viewport's screen-space velocity from successive build
/// observations and yields a bias — how far ahead of the current center the
/// rendered camera should look — so capped frames, placed by the residual
/// transform, keep the leading edge covered.
///
/// Pure state machine: the widget feeds observations; nothing here touches
/// clocks or bindings. Hysteresis instead of decay: the applied bias moves
/// only when the desired bias strays more than [quantumPx], and freezes when
/// motion stops — a stale bias is harmless (content is correct wherever the
/// margin sits), while decaying it would keep changing the rendered camera
/// on a still map and veto the ticker park.
class LeadBias {
  LeadBias({
    this.timeConstant = const Duration(milliseconds: 100),
    this.quantumPx = 8.0,
    this.safetyFactor = 0.85,
  });

  /// EMA time constant of the velocity estimate.
  final Duration timeConstant;

  /// Applied-bias dead band, logical px.
  final double quantumPx;

  /// Fraction of the margin the bias may consume; the remainder stays as
  /// trailing reserve so an abrupt reversal doesn't bare the very next
  /// capped frame.
  final double safetyFactor;

  Offset _velocity = Offset.zero;
  Offset _applied = Offset.zero;

  /// Latest velocity estimate in screen px/s, pointing the way the viewport
  /// travels (where new content appears).
  Offset get velocity => _velocity;

  /// The bias renders are currently shifted by.
  Offset get applied => _applied;

  void reset() {
    _velocity = Offset.zero;
    _applied = Offset.zero;
  }

  /// Feed one build's observation; returns the bias to apply this build.
  ///
  /// [travel] is how far the viewport moved since the previous observation,
  /// in current-camera screen px. [maxBias] is the per-axis margin available
  /// for lead ((renderSize − viewport) / 2). [leadTime] is how far ahead to
  /// look — the caller passes twice the frame cap.
  Offset update({
    required Offset travel,
    required Duration elapsed,
    required Size maxBias,
    required Duration leadTime,
  }) {
    if (elapsed <= Duration.zero || travel == Offset.zero) return _applied;
    final dt = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final alpha =
        1 - math.exp(-elapsed.inMicroseconds / timeConstant.inMicroseconds);
    _velocity = Offset.lerp(_velocity, travel / dt, alpha)!;
    final lead = leadTime.inMicroseconds / Duration.microsecondsPerSecond;
    final desired = Offset(
      (_velocity.dx * lead).clamp(
        -maxBias.width * safetyFactor,
        maxBias.width * safetyFactor,
      ),
      (_velocity.dy * lead).clamp(
        -maxBias.height * safetyFactor,
        maxBias.height * safetyFactor,
      ),
    );
    if ((desired - _applied).distance > quantumPx) _applied = desired;
    return _applied;
  }
}
