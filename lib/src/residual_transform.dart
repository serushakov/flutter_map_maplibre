import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:vector_math/vector_math_64.dart';

/// The transform that reconciles a natively-rendered frame with the camera
/// Flutter is painting *this* frame at.
///
/// A native renderer is always at least a frame behind: it renders for camera
/// `rendered` while the map has already moved on to `current`. Displaying that
/// frame as-is makes the basemap slide against the Flutter marker layers, which
/// is the artefact every platform-view map plugin suffers from.
///
/// In Web Mercator, pan, zoom and rotation are *exact* similarity transforms of
/// the projected plane — not approximations. So the stale frame can be placed
/// perfectly, in the same Flutter frame as the markers, by transforming it
/// rather than waiting for it. Only symbol layout is momentarily stale: labels
/// scale slightly during a fling and snap crisp when the renderer catches up,
/// exactly as MapLibre GL JS behaves between re-layouts.
///
/// The derivation, in flutter_map's own terms. For a camera `X`,
/// `latLngToScreenOffset` is
///
///     screen_X(p) = R(θx) · (proj_X(p) − proj_X(X.center)) + half_X
///
/// where `R` is rotation, `θx` the camera bearing, and `half_X` half the
/// non-rotated viewport. Eliminating the projection between the two cameras
/// gives
///
///     screen_C(p) = k · R(θc − θr) · (screen_R(p) − half_R) + screen_C(R.center)
///
/// with `k` the zoom scale between them. That is this function, and it holds
/// for any point on earth — including points off-screen in either camera.
Matrix4 residualTransform({
  required MapCamera rendered,
  required MapCamera current,
}) {
  final scale = current.getZoomScale(current.zoom, rendered.zoom);
  final rotationDelta = current.rotationRad - rendered.rotationRad;

  // Where the rendered frame's centre point has moved to on the current screen.
  final anchor = current.latLngToScreenOffset(rendered.center);

  // The rendered frame's own centre, in its own pixels.
  final half = rendered.nonRotatedSize.center(Offset.zero);

  return Matrix4.identity()
    ..translateByDouble(anchor.dx, anchor.dy, 0, 1)
    ..rotateZ(rotationDelta)
    ..scaleByDouble(scale, scale, 1, 1)
    ..translateByDouble(-half.dx, -half.dy, 0, 1);
}
