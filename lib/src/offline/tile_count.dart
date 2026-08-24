import 'dart:math' as math;

/// Web-Mercator's usable latitude range; anything beyond projects onto the
/// edge tile row, so bounds are clamped here rather than rejected.
const mercatorLatitudeLimit = 85.05112878;

/// Number of tiles a tile-pyramid region over [south]..[north] /
/// [west]..[east] covers across zooms [minZoom]..[maxZoom] inclusive.
///
/// Pure Web-Mercator arithmetic — the Dart-side budget guard from the
/// spec (docs/superpowers/specs/2026-08-24-persistent-cache-and-offline-
/// seeding.md). Deliberately an over-count relative to what a download
/// actually fetches: sources whose own max zoom is lower than [maxZoom]
/// are still counted at every requested zoom (fails safe), and glyphs /
/// sprites / style JSON are not tiles and not counted (bounded, small).
///
/// [west] greater than [east] means the bounds cross the antimeridian and
/// cover the two longitude ranges `[west, 180]` and `[-180, east]`.
/// Latitudes may exceed the Mercator limit; they clamp to the edge row.
int estimateTileCount({
  required double south,
  required double west,
  required double north,
  required double east,
  required int minZoom,
  required int maxZoom,
}) {
  if (minZoom < 0 || maxZoom < minZoom) {
    throw ArgumentError('zoom range must satisfy 0 <= minZoom <= maxZoom');
  }
  if (maxZoom > 30) {
    // 4^31 columns would overflow the shift math long before any real
    // tileset exists there.
    throw ArgumentError('maxZoom must be <= 30');
  }
  if (south > north) {
    throw ArgumentError('south must not exceed north');
  }
  var total = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final n = 1 << z;
    final rows = _tileY(south, z) - _tileY(north, z) + 1;
    final int columns;
    if (west <= east) {
      columns = _tileX(east, z) - _tileX(west, z) + 1;
    } else {
      // Antimeridian crossing: [west .. 180] plus [-180 .. east]. The two
      // ranges can overlap at coarse zooms where both edges land on the
      // same tile, so cap at the row width.
      columns = math.min((n - _tileX(west, z)) + (_tileX(east, z) + 1), n);
    }
    total += rows * columns;
  }
  return total;
}

int _tileX(double longitude, int zoom) {
  final n = 1 << zoom;
  final x = ((longitude + 180.0) / 360.0 * n).floor();
  return x.clamp(0, n - 1);
}

int _tileY(double latitude, int zoom) {
  final n = 1 << zoom;
  final lat =
      latitude.clamp(-mercatorLatitudeLimit, mercatorLatitudeLimit) *
      math.pi /
      180.0;
  final y =
      ((1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2 * n)
          .floor();
  return y.clamp(0, n - 1);
}
