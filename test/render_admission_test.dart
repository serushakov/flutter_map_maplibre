import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/src/render_admission.dart';
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

MapCamera pannedEast(MapCamera camera, double px) => camera.withPosition(
  center: camera.screenOffsetToLatLng(
    camera.nonRotatedSize.center(Offset.zero) + Offset(px, 0),
  ),
);

void main() {
  final base = cameraAt();
  final fullRect = Offset.zero & const Size(400, 800);
  // 50px symmetric margin per axis.
  const renderSize = Size(500, 900);

  bool admit(MapCamera? rendered, MapCamera current) => shouldAdmitRender(
    rendered: rendered,
    renderSize: renderSize,
    current: current,
    visibleRect: fullRect,
  );

  test('no rendered frame yet → admit', () {
    expect(admit(null, base), isTrue);
  });

  test('same camera, comfortable slack → deny', () {
    expect(admit(base, base), isFalse);
  });

  test('pan leaving more than the guard band of slack → deny', () {
    // Slack 50-30 = 20 > 16.
    expect(admit(base, pannedEast(base, 30)), isFalse);
  });

  test('pan within the guard band of the edge → admit', () {
    // Slack 50-40 = 10 < 16.
    expect(admit(base, pannedEast(base, 40)), isTrue);
  });

  test('fully bared → admit', () {
    expect(admit(base, pannedEast(base, 60)), isTrue);
  });

  test('zoom quantum: 0.049 in → deny, 0.05 → admit, symmetric in sign', () {
    // Zoom IN covers geometrically; only the quantum can admit.
    expect(admit(base, base.withPosition(zoom: 13.049)), isFalse);
    expect(admit(base, base.withPosition(zoom: 13.05)), isTrue);
    expect(admit(base, base.withPosition(zoom: 12.95)), isTrue);
  });

  test('bearing quantum: 0.05° → deny, 0.1° → admit', () {
    expect(admit(base, cameraAt(rotation: 0.05)), isFalse);
    expect(admit(base, cameraAt(rotation: 0.1)), isTrue);
  });

  test(
    'settleOffTarget: zoom or rotation residue → true, translation → false',
    () {
      expect(settleOffTarget(rendered: null, current: base), isFalse);
      expect(settleOffTarget(rendered: base, current: base), isFalse);
      expect(
        settleOffTarget(rendered: base, current: pannedEast(base, 30)),
        isFalse,
      );
      expect(
        settleOffTarget(
          rendered: base,
          current: base.withPosition(zoom: 13.02),
        ),
        isTrue,
      );
      expect(
        settleOffTarget(rendered: base, current: cameraAt(rotation: 0.05)),
        isTrue,
      );
    },
  );
}
