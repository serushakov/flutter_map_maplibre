import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';

import 'under_render.dart';

/// Whether a camera-driven native render should be admitted, or the existing
/// frame placed by the residual transform instead (spec:
/// docs/superpowers/specs/2026-07-24-drift-threshold-render-admission-design.md).
///
/// Admits when any of:
/// - no frame has been rendered yet ([rendered] null);
/// - zoom drifted a quantum from the rendered frame (zoom IN never bares the
///   canvas, so coverage alone would let labels blur indefinitely);
/// - bearing drifted a quantum (coverage handles rotation's corner-baring;
///   the quantum bounds label-orientation drift);
/// - the viewport is within [guardPx] of the rendered canvas's edge —
///   measured with the same 4-corner projection as [underRenderPx], but on
///   the signed slack before display rather than the damage after.
///
/// Tile-content renders (the ticker's update/repaint path) are not this
/// gate's business and must not be routed through it.
bool shouldAdmitRender({
  required MapCamera? rendered,
  required Size renderSize,
  required MapCamera current,
  required Rect visibleRect,
  double guardPx = 16.0,
  double zoomQuantum = 0.05,
  double bearingQuantumDeg = 0.1,
}) {
  if (rendered == null) return true;
  if ((current.zoom - rendered.zoom).abs() >= zoomQuantum) return true;
  if ((current.rotation - rendered.rotation).abs() >= bearingQuantumDeg) {
    return true;
  }
  return renderOvershootPx(
        rendered: rendered,
        renderSize: renderSize,
        current: current,
        visibleRect: visibleRect,
      ) >
      -guardPx;
}

/// Whether the rendered frame rests off-target in a way worth one settle
/// render: zoom or rotation residue scales/rotates every placed frame
/// (persistently blurry labels at rest), while pure translation is placed
/// pixel-exactly and needs nothing.
bool settleOffTarget({
  required MapCamera? rendered,
  required MapCamera current,
}) =>
    rendered != null &&
    (rendered.zoom != current.zoom || rendered.rotation != current.rotation);
