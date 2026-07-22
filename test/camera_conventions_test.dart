import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/src/camera_conventions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// MapLibre's world size in pixels at a given MapLibre zoom
/// (`mbgl::util::tileSize_D` is 512).
double maplibreWorldSize(double zoom) => 512.0 * math.pow(2, zoom);

/// The compass direction that appears at the top of the screen, in degrees
/// clockwise from north — which is the definition of MapLibre's bearing.
///
/// Derived from flutter_map's own projection rather than from its docs: a
/// point due north of the centre is placed on screen, and the angle it sits
/// at tells us how far the content was swung.
double directionAtScreenTop(MapCamera camera) {
  final centre = camera.latLngToScreenOffset(camera.center);
  final north = camera.latLngToScreenOffset(
    LatLng(camera.center.latitude + 0.01, camera.center.longitude),
  );
  final delta = north - centre;

  // Angle of north, measured clockwise from screen-up (y grows downwards).
  final northAngle = math.atan2(delta.dx, -delta.dy) * 180 / math.pi;

  // If north sits `northAngle` clockwise of up, then up is that far
  // anticlockwise of north.
  return (-northAngle) % 360;
}

void main() {
  group('zoom', () {
    test('matches flutter_map world size at the same scale', () {
      // The two conventions must describe a world of identical pixel width —
      // that is what makes it the same view.
      const crs = Epsg3857();
      for (final zoom in <double>[0, 5, 12, 13, 13.37, 18]) {
        expect(
          maplibreWorldSize(maplibreZoom(zoom)),
          closeTo(crs.scale(zoom), 1e-6),
          reason: 'flutter_map zoom $zoom',
        );
      }
    });

    test('is one level lower, since MapLibre tiles are twice the size', () {
      expect(maplibreZoom(13), 12);
    });
  });

  group('bearing', () {
    test('points the camera the way flutter_map swung the content', () {
      for (final rotation in <double>[0, 30, 45, 90, 180, 270, -45]) {
        final camera = MapCamera(
          crs: const Epsg3857(),
          center: const LatLng(59.437, 24.7536),
          zoom: 13,
          rotation: rotation,
          nonRotatedSize: const Size(400, 800),
        );

        expect(
          directionAtScreenTop(camera),
          closeTo(maplibreBearing(rotation) % 360, 0.01),
          reason: 'flutter_map rotation $rotation',
        );
      }
    });

    test('rotation 90 puts west at the top, i.e. bearing 270', () {
      expect(maplibreBearing(90) % 360, 270);
    });
  });
}
