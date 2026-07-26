import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';

/// The camera whose viewport is [visibleRect] of [full]'s screen.
///
/// Same zoom and bearing; only the center moves to [visibleRect]'s center.
/// `screenOffsetToLatLng` is the exact bearing-aware inverse of the
/// projection `residualTransform` is built on, so for every point on earth
///
///     cropped.latLngToScreenOffset(p) ==
///         full.latLngToScreenOffset(p) - visibleRect.topLeft
///
/// which is what lets a fixed-size texture cover just the visible part of a
/// deliberately oversized map layer (a host app may lay the map out taller
/// than the screen to push the camera center above a bottom sheet; the
/// overflow is clipped offscreen and need never be rendered).
///
/// Returns [full] itself when the rect covers the whole viewport: the
/// center round-trip through the projection carries a float epsilon that
/// would otherwise defeat the renderer's same-camera dedup.
MapCamera cropCamera(MapCamera full, Rect visibleRect) {
  if (visibleRect == (Offset.zero & full.nonRotatedSize)) return full;
  return full
      .withNonRotatedSize(visibleRect.size)
      .withPosition(center: full.screenOffsetToLatLng(visibleRect.center));
}
