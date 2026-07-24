import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';

/// The widest strip of the visible viewport, in logical px, that the
/// rendered texture leaves uncovered — 0 when the texture covers it fully.
///
/// [rendered] is the camera the front buffer was rendered for (crop-sized;
/// its canvas is [renderSize], centered — the same convention
/// `residualTransform` consumes via `withNonRotatedSize`). [current] is the
/// camera being painted, whose visible part is [visibleRect] of its screen.
///
/// Each corner of the visible viewport is projected into the rendered
/// canvas; the worst per-axis overshoot beyond the canvas bounds is the
/// uncovered strip. The camera-to-camera mapping is affine and the viewport
/// convex, so the maximum over the four corners is exact.
double underRenderPx({
  required MapCamera rendered,
  required Size renderSize,
  required MapCamera current,
  required Rect visibleRect,
}) {
  final canvas = rendered.withNonRotatedSize(renderSize);
  var worst = 0.0;
  for (final corner in <Offset>[
    visibleRect.topLeft,
    visibleRect.topRight,
    visibleRect.bottomLeft,
    visibleRect.bottomRight,
  ]) {
    final p = canvas.latLngToScreenOffset(current.screenOffsetToLatLng(corner));
    final outside = [
      -p.dx,
      p.dx - renderSize.width,
      -p.dy,
      p.dy - renderSize.height,
    ].reduce(math.max);
    if (outside > worst) worst = outside;
  }
  return worst;
}
