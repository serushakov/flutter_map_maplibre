import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/src/viewport_crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

MapCamera cameraAt({
  LatLng center = const LatLng(59.437, 24.7536),
  double zoom = 13,
  double rotation = 0,
  Size size = const Size(400, 800),
}) => MapCamera(
  crs: const Epsg3857(),
  center: center,
  zoom: zoom,
  rotation: rotation,
  nonRotatedSize: size,
);

/// The property the whole design rests on: the cropped camera's screen is
/// the full camera's screen shifted by the rect origin, for every point on
/// earth. flutter_map's own projection is the oracle — nothing here
/// re-derives it.
void expectCropMatchesProjection(MapCamera full, Rect rect) {
  final cropped = cropCamera(full, rect);

  const samples = <LatLng>[
    LatLng(59.437, 24.7536), // Tallinn
    LatLng(59.4, 24.6), // south-west of centre
    LatLng(59.5, 24.9), // north-east of centre
    LatLng(58.38, 26.72), // Tartu — far off-screen
  ];

  for (final point in samples) {
    final actual = cropped.latLngToScreenOffset(point);
    final expected = full.latLngToScreenOffset(point) - rect.topLeft;
    expect(
      (actual - expected).distance,
      lessThan(0.01),
      reason: 'point $point: cropped gave $actual, expected $expected',
    );
  }
}

void main() {
  test('returns the same camera when the rect is the whole viewport', () {
    final full = cameraAt();
    expect(
      identical(cropCamera(full, const Rect.fromLTWH(0, 0, 400, 800)), full),
      isTrue,
      reason:
          'the unpinned path must not round-trip the center through the '
          'projection — an epsilon there would defeat the renderer\'s '
          'same-camera dedup and re-render on every rebuild',
    );
  });

  test('bottom-aligned crop matches the projection', () {
    expectCropMatchesProjection(
      cameraAt(),
      const Rect.fromLTWH(0, 200, 400, 600),
    );
  });

  test('crop matches the projection under bearing', () {
    expectCropMatchesProjection(
      cameraAt(rotation: 37),
      const Rect.fromLTWH(0, 200, 400, 600),
    );
    expectCropMatchesProjection(
      cameraAt(rotation: 90),
      const Rect.fromLTWH(0, 200, 400, 600),
    );
  });

  test('crop matches the projection under zoom and bearing together', () {
    expectCropMatchesProjection(
      cameraAt(zoom: 16.4, rotation: 213),
      const Rect.fromLTWH(0, 350, 400, 450),
    );
  });

  test('unrotated bottom crop moves the center straight south', () {
    final full = cameraAt();
    final cropped = cropCamera(full, const Rect.fromLTWH(0, 200, 400, 600));
    expect(cropped.nonRotatedSize, const Size(400, 600));
    expect(cropped.center.latitude, lessThan(full.center.latitude));
    expect(cropped.center.longitude, closeTo(full.center.longitude, 1e-9));
  });

  test('preserves zoom and rotation', () {
    final cropped = cropCamera(
      cameraAt(zoom: 15.3, rotation: 42),
      const Rect.fromLTWH(0, 100, 400, 700),
    );
    expect(cropped.zoom, 15.3);
    expect(cropped.rotation, 42);
  });
}
