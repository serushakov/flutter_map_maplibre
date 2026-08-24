import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('estimateTileCount', () {
    test('whole world is the full pyramid', () {
      expect(
        estimateTileCount(
          south: -90,
          west: -180,
          north: 90,
          east: 180,
          minZoom: 0,
          maxZoom: 0,
        ),
        1,
      );
      // 1 + 4 + 16 — latitudes beyond the Mercator limit clamp to the
      // edge rows instead of erroring.
      expect(
        estimateTileCount(
          south: -90,
          west: -180,
          north: 90,
          east: 180,
          minZoom: 0,
          maxZoom: 2,
        ),
        21,
      );
    });

    test('bounds inside one tile cost one tile per zoom', () {
      expect(
        estimateTileCount(
          south: 0.001,
          west: 0.001,
          north: 0.002,
          east: 0.002,
          minZoom: 0,
          maxZoom: 10,
        ),
        11,
      );
    });

    test('north-east quadrant, hand-computed rows and columns', () {
      // z1: exactly the NE quadrant tile. z2: columns x2..x3, rows y0..y1
      // (85° is still inside the Mercator limit, so row 0 is included).
      expect(
        estimateTileCount(
          south: 0.0001,
          west: 0.0001,
          north: 85.0,
          east: 179.9,
          minZoom: 1,
          maxZoom: 2,
        ),
        1 + 4,
      );
    });

    test('antimeridian crossing counts both sides', () {
      // west > east: [170..180] + [-180..-170]. z1: columns x1 and x0,
      // rows y0..y1 = 4 tiles.
      expect(
        estimateTileCount(
          south: -10,
          west: 170,
          north: 10,
          east: -170,
          minZoom: 1,
          maxZoom: 1,
        ),
        4,
      );
    });

    test('antimeridian crossing matches the same span at Greenwich', () {
      // A 20°-wide strip should cost the same whether it straddles the
      // antimeridian or the prime meridian.
      final crossing = estimateTileCount(
        south: -10,
        west: 170,
        north: 10,
        east: -170,
        minZoom: 0,
        maxZoom: 6,
      );
      final greenwich = estimateTileCount(
        south: -10,
        west: -10,
        north: 10,
        east: 10,
        minZoom: 0,
        maxZoom: 6,
      );
      expect(crossing, greenwich);
    });

    test('antimeridian crossing never exceeds the row width', () {
      // At z0 both edges land on the single world tile; the two wrap
      // segments must not double-count it.
      expect(
        estimateTileCount(
          south: -10,
          west: 170,
          north: 10,
          east: -170,
          minZoom: 0,
          maxZoom: 0,
        ),
        1,
      );
    });

    test('polar latitudes clamp to the Mercator edge row', () {
      // 89.99° clamps to the limit; at z3 both 80° and the limit are in
      // row 0, and 0.1°..0.2° share column 4.
      expect(
        estimateTileCount(
          south: 80,
          west: 0.1,
          north: 89.99,
          east: 0.2,
          minZoom: 3,
          maxZoom: 3,
        ),
        1,
      );
    });

    test('rejects invalid ranges', () {
      expect(
        () => estimateTileCount(
          south: 0,
          west: 0,
          north: 1,
          east: 1,
          minZoom: -1,
          maxZoom: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => estimateTileCount(
          south: 0,
          west: 0,
          north: 1,
          east: 1,
          minZoom: 3,
          maxZoom: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => estimateTileCount(
          south: 2,
          west: 0,
          north: 1,
          east: 1,
          minZoom: 0,
          maxZoom: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => estimateTileCount(
          south: 0,
          west: 0,
          north: 1,
          east: 1,
          minZoom: 0,
          maxZoom: 31,
        ),
        throwsArgumentError,
      );
    });

    test('a real seed: Tallinn ±0.015°/±0.03°, z12–14', () {
      // The probe's region downloaded 20 tiles for this pyramid; the
      // estimate must be in the same range and never under-count.
      final estimate = estimateTileCount(
        south: 59.437 - 0.015,
        west: 24.7536 - 0.03,
        north: 59.437 + 0.015,
        east: 24.7536 + 0.03,
        minZoom: 12,
        maxZoom: 14,
      );
      expect(estimate, greaterThanOrEqualTo(20));
      expect(estimate, lessThan(40));
    });
  });

  group('OfflineRegionProgress', () {
    test('sums across a style pair, ANDs precision and completeness', () {
      const a = OfflineRegionProgress(
        completedResources: 10,
        requiredResources: 20,
        completedTiles: 5,
        requiredTiles: 8,
        completedBytes: 1000,
        requiredIsPrecise: true,
        isComplete: true,
        isDownloading: false,
      );
      const b = OfflineRegionProgress(
        completedResources: 1,
        requiredResources: 30,
        completedTiles: 1,
        requiredTiles: 8,
        completedBytes: 50,
        requiredIsPrecise: false,
        isComplete: false,
        isDownloading: true,
      );
      final sum = a + b;
      expect(sum.completedResources, 11);
      expect(sum.requiredResources, 50);
      expect(sum.completedTiles, 6);
      expect(sum.requiredTiles, 16);
      expect(sum.completedBytes, 1050);
      expect(sum.requiredIsPrecise, false);
      expect(sum.isComplete, false);
      expect(sum.isDownloading, true);
    });
  });

  group('OfflineRegionDefinition', () {
    test('value equality for purge capture/recreate round-trips', () {
      const def = OfflineRegionDefinition(
        styleUrl: 'https://example.com/style.json',
        south: 59.4,
        west: 24.7,
        north: 59.5,
        east: 24.8,
        minZoom: 12,
        maxZoom: 14,
        pixelRatio: 3,
      );
      const same = OfflineRegionDefinition(
        styleUrl: 'https://example.com/style.json',
        south: 59.4,
        west: 24.7,
        north: 59.5,
        east: 24.8,
        minZoom: 12,
        maxZoom: 14,
        pixelRatio: 3,
      );
      expect(def, same);
      expect(def.hashCode, same.hashCode);
      expect(def.bounds.south, 59.4);
      expect(def.bounds.east, 24.8);
    });
  });
}
