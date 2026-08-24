import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart' show LatLng;

/// One native region's geometry + style, the unit the C API creates and the
/// purge sequence captures/recreates. Zooms are doubles because that is what
/// `mln_offline_tile_pyramid_region_definition` round-trips; the public
/// facade only ever writes whole numbers into them.
class OfflineRegionDefinition {
  const OfflineRegionDefinition({
    required this.styleUrl,
    required this.south,
    required this.west,
    required this.north,
    required this.east,
    required this.minZoom,
    required this.maxZoom,
    required this.pixelRatio,
    this.includeIdeographs = false,
  });

  final String styleUrl;
  final double south;
  final double west;
  final double north;
  final double east;
  final double minZoom;
  final double maxZoom;
  final double pixelRatio;
  final bool includeIdeographs;

  LatLngBounds get bounds =>
      LatLngBounds(LatLng(south, west), LatLng(north, east));

  @override
  bool operator ==(Object other) =>
      other is OfflineRegionDefinition &&
      other.styleUrl == styleUrl &&
      other.south == south &&
      other.west == west &&
      other.north == north &&
      other.east == east &&
      other.minZoom == minZoom &&
      other.maxZoom == maxZoom &&
      other.pixelRatio == pixelRatio &&
      other.includeIdeographs == includeIdeographs;

  @override
  int get hashCode => Object.hash(
    styleUrl,
    south,
    west,
    north,
    east,
    minZoom,
    maxZoom,
    pixelRatio,
    includeIdeographs,
  );

  @override
  String toString() =>
      'OfflineRegionDefinition($styleUrl, s$south w$west n$north e$east, '
      'z$minZoom-$maxZoom, dpr $pixelRatio)';
}

/// Mirror of `mln_offline_region_status`, also used as the combined
/// progress across a multi-style region group (fields summed; see the spec
/// on why required counts double-count shared bytes across a style pair).
class OfflineRegionProgress {
  const OfflineRegionProgress({
    required this.completedResources,
    required this.requiredResources,
    required this.completedTiles,
    required this.requiredTiles,
    required this.completedBytes,
    required this.requiredIsPrecise,
    required this.isComplete,
    required this.isDownloading,
  });

  static const zero = OfflineRegionProgress(
    completedResources: 0,
    requiredResources: 0,
    completedTiles: 0,
    requiredTiles: 0,
    completedBytes: 0,
    requiredIsPrecise: false,
    isComplete: false,
    isDownloading: false,
  );

  /// Resources = tiles + style JSON + TileJSON + glyphs + sprites.
  final int completedResources;
  final int requiredResources;
  final int completedTiles;
  final int requiredTiles;

  /// Bytes of completed resources (tiles included).
  final int completedBytes;

  /// False while the download is still discovering the resource list, so
  /// required counts may still grow.
  final bool requiredIsPrecise;
  final bool isComplete;
  final bool isDownloading;

  OfflineRegionProgress operator +(OfflineRegionProgress other) =>
      OfflineRegionProgress(
        completedResources: completedResources + other.completedResources,
        requiredResources: requiredResources + other.requiredResources,
        completedTiles: completedTiles + other.completedTiles,
        requiredTiles: requiredTiles + other.requiredTiles,
        completedBytes: completedBytes + other.completedBytes,
        requiredIsPrecise: requiredIsPrecise && other.requiredIsPrecise,
        isComplete: isComplete && other.isComplete,
        isDownloading: isDownloading || other.isDownloading,
      );

  @override
  bool operator ==(Object other) =>
      other is OfflineRegionProgress &&
      other.completedResources == completedResources &&
      other.requiredResources == requiredResources &&
      other.completedTiles == completedTiles &&
      other.requiredTiles == requiredTiles &&
      other.completedBytes == completedBytes &&
      other.requiredIsPrecise == requiredIsPrecise &&
      other.isComplete == isComplete &&
      other.isDownloading == isDownloading;

  @override
  int get hashCode => Object.hash(
    completedResources,
    requiredResources,
    completedTiles,
    requiredTiles,
    completedBytes,
    requiredIsPrecise,
    isComplete,
    isDownloading,
  );

  @override
  String toString() =>
      'OfflineRegionProgress(tiles $completedTiles/$requiredTiles, '
      'resources $completedResources/$requiredResources'
      '${requiredIsPrecise ? '' : '+'}, $completedBytes bytes'
      '${isComplete ? ', complete' : ''})';
}

/// A seeded region as the caller sees it: one logical seed spanning one
/// native region per style URL, listed and deleted as a unit.
class OfflineRegion {
  const OfflineRegion({
    required this.id,
    required this.styleUrls,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.pixelRatio,
    required this.progress,
  });

  /// Group id — stable across launches (persisted in the native regions'
  /// metadata), opaque to the caller.
  final String id;
  final List<String> styleUrls;
  final LatLngBounds bounds;
  final int minZoom;
  final int maxZoom;
  final double pixelRatio;

  /// Status snapshot at list time, summed across the group.
  final OfflineRegionProgress progress;

  @override
  String toString() =>
      'OfflineRegion($id, ${styleUrls.length} style(s), z$minZoom-$maxZoom, '
      '$progress)';
}

/// Thrown by `createRegion` before anything native runs when the
/// Web-Mercator estimate for the requested pyramid exceeds the caller's
/// budget.
class TileBudgetExceeded implements Exception {
  const TileBudgetExceeded({
    required this.estimatedTiles,
    required this.maxTiles,
  });

  final int estimatedTiles;
  final int maxTiles;

  @override
  String toString() =>
      'TileBudgetExceeded: region needs ~$estimatedTiles tiles, '
      'budget is $maxTiles';
}
