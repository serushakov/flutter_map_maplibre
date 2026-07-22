import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/src/residual_transform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Ground truth for every test below.
///
/// The transform's whole job is to make a frame rendered at camera R land where
/// camera C would have drawn it. So for any point on earth, pushing its
/// R-screen position through the transform must land on its C-screen position.
/// flutter_map's own projection is the oracle — nothing here re-derives it.
void expectTransformMatchesProjection(
  MapCamera rendered,
  MapCamera current, {
  double tolerance = 0.01,
}) {
  final transform = residualTransform(rendered: rendered, current: current);

  const samples = <LatLng>[
    LatLng(59.437, 24.7536), // Tallinn
    LatLng(59.4, 24.6), // south-west of centre
    LatLng(59.5, 24.9), // north-east of centre
    LatLng(58.38, 26.72), // Tartu — far off-screen
    LatLng(0, 0), // null island, extreme case
  ];

  for (final point in samples) {
    final actual = MatrixUtils.transformPoint(
      transform,
      rendered.latLngToScreenOffset(point),
    );
    final expected = current.latLngToScreenOffset(point);

    expect(
      (actual - expected).distance,
      lessThan(tolerance),
      reason: 'point $point: transform gave $actual, projection says $expected',
    );
  }
}

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

void main() {
  test('identity when cameras match', () {
    final camera = cameraAt();
    expectTransformMatchesProjection(camera, camera);
  });

  test('pure pan', () {
    expectTransformMatchesProjection(
      cameraAt(),
      cameraAt(center: const LatLng(59.45, 24.78)),
    );
  });

  test('pure zoom, integer step', () {
    expectTransformMatchesProjection(cameraAt(zoom: 13), cameraAt(zoom: 14));
  });

  test('pure zoom, fractional — the case raster tiles cannot do', () {
    expectTransformMatchesProjection(cameraAt(zoom: 13), cameraAt(zoom: 13.37));
  });

  test('zoom out', () {
    expectTransformMatchesProjection(cameraAt(zoom: 15), cameraAt(zoom: 13.5));
  });

  test('pure rotation', () {
    expectTransformMatchesProjection(cameraAt(), cameraAt(rotation: 30));
  });

  test('rotation from a non-zero starting bearing', () {
    expectTransformMatchesProjection(
      cameraAt(rotation: 45),
      cameraAt(rotation: 12.5),
    );
  });

  test('combined pan, zoom and rotation — a real fling frame', () {
    expectTransformMatchesProjection(
      cameraAt(zoom: 13, rotation: 15),
      cameraAt(
        center: const LatLng(59.4405, 24.7601),
        zoom: 13.42,
        rotation: 21.75,
      ),
    );
  });

  test(
    'viewport that is taller than the screen, as the sheet drag produces',
    () {
      // MainMapMapView renders the map into an OverflowBox taller than the
      // viewport, resized every frame while the sheet drags.
      expectTransformMatchesProjection(
        cameraAt(size: const Size(400, 1100)),
        cameraAt(
          center: const LatLng(59.44, 24.76),
          size: const Size(400, 1100),
        ),
      );
    },
  );

  test('decomposes to the expected scale and rotation', () {
    final rendered = cameraAt(zoom: 13, rotation: 10);
    final current = cameraAt(zoom: 14, rotation: 40);
    final transform = residualTransform(rendered: rendered, current: current);

    // A similarity transform: the upper-left 2x2 is scale * rotation.
    final a = transform.storage[0];
    final b = transform.storage[1];

    expect(math.sqrt(a * a + b * b), closeTo(2.0, 1e-9));
    expect(math.atan2(b, a), closeTo(30 * math.pi / 180, 1e-9));
  });
}
