import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/src/under_render.dart';
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

/// [camera] panned [px] east (screen +x) at the same zoom.
MapCamera pannedEast(MapCamera camera, double px) => camera.withPosition(
  center: camera.screenOffsetToLatLng(
    camera.nonRotatedSize.center(Offset.zero) + Offset(px, 0),
  ),
);

void main() {
  final base = cameraAt();
  final fullRect = Offset.zero & const Size(400, 800);

  test('same camera, no margin: fully covered', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(400, 800),
        current: base,
        visibleRect: fullRect,
      ),
      closeTo(0, 0.01),
    );
  });

  test('30px pan with no margin bares a 30px strip', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(400, 800),
        current: pannedEast(base, 30),
        visibleRect: fullRect,
      ),
      closeTo(30, 0.1),
    );
  });

  test('a 50px symmetric margin covers a 30px pan', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(500, 900),
        current: pannedEast(base, 30),
        visibleRect: fullRect,
      ),
      closeTo(0, 0.01),
    );
  });

  test('a 60px pan overruns the 50px margin by 10', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(500, 900),
        current: pannedEast(base, 60),
        visibleRect: fullRect,
      ),
      closeTo(10, 0.1),
    );
  });

  test('lead bias extends the runway ahead and shortens it behind', () {
    final biased = pannedEast(base, 40); // rendered 40px ahead of base
    // 60px pan east: viewport sits 20px past base center relative to the
    // biased canvas center; margin 50 → covered.
    expect(
      underRenderPx(
        rendered: biased,
        renderSize: const Size(500, 900),
        current: pannedEast(base, 60),
        visibleRect: fullRect,
      ),
      closeTo(0, 0.01),
    );
    // 20px pan WEST: trailing runway is 50 − 40 = 10 → 10px bared.
    expect(
      underRenderPx(
        rendered: biased,
        renderSize: const Size(500, 900),
        current: pannedEast(base, -20),
        visibleRect: fullRect,
      ),
      closeTo(10, 0.1),
    );
  });

  test('zoom-out bares the edges', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(400, 800),
        current: base.withPosition(zoom: 12.5),
        visibleRect: fullRect,
      ),
      greaterThan(0),
    );
  });

  test('cropped viewport of a taller layer, the Vedu sheet shape', () {
    // Layer 400x1000, visible bottom 400x800 strip; rendered camera is the
    // crop itself → covered exactly.
    final layer = cameraAt(size: const Size(400, 1000));
    final visible = const Rect.fromLTWH(0, 200, 400, 800);
    final crop = layer
        .withNonRotatedSize(visible.size)
        .withPosition(center: layer.screenOffsetToLatLng(visible.center));
    expect(
      underRenderPx(
        rendered: crop,
        renderSize: const Size(400, 800),
        current: layer,
        visibleRect: visible,
      ),
      closeTo(0, 0.01),
    );
  });

  test('renderOvershootPx: negative slack when covered with room', () {
    // 50px symmetric margin, 30px pan: nearest edge is 50-30=20px away.
    expect(
      renderOvershootPx(
        rendered: base,
        renderSize: const Size(500, 900),
        current: pannedEast(base, 30),
        visibleRect: fullRect,
      ),
      closeTo(-20, 0.1),
    );
  });

  test('renderOvershootPx: positive overshoot matches underRenderPx', () {
    expect(
      renderOvershootPx(
        rendered: base,
        renderSize: const Size(500, 900),
        current: pannedEast(base, 60),
        visibleRect: fullRect,
      ),
      closeTo(10, 0.1),
    );
  });

  test('renderOvershootPx: same camera, symmetric margin → slack = margin', () {
    expect(
      renderOvershootPx(
        rendered: base,
        renderSize: const Size(500, 900),
        current: base,
        visibleRect: fullRect,
      ),
      closeTo(-50, 0.1),
    );
  });
}
