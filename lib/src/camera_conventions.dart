/// Translation between `flutter_map`'s camera conventions and MapLibre's.
///
/// The two libraries describe the same Web Mercator camera with different
/// units. Neither is wrong, but a value handed across unconverted is silently
/// plausible — the map still renders, still pans, still looks like a map — so
/// these are worth stating explicitly rather than inlining at the call site.
library;

/// MapLibre's zoom for a `flutter_map` zoom.
///
/// Zoom is defined by how many pixels wide the world is, and the two libraries
/// disagree on the tile size that anchors it:
///
///   flutter_map (`Epsg3857.scale`):  world = 256 · 2^z
///   MapLibre    (`util::tileSize`):  world = 512 · 2^z
///
/// So the same view is one zoom level lower in MapLibre's numbering. Passing
/// the value through unconverted renders the basemap at exactly twice the
/// intended scale: the map is still centred correctly, so it reads as "the
/// map moves faster than my finger" rather than as a zoom bug.
double maplibreZoom(double flutterMapZoom) => flutterMapZoom - 1;

/// MapLibre's bearing for a `flutter_map` rotation, in degrees.
///
/// `flutter_map` rotates the *content*: `latLngToScreenOffset` turns projected
/// points about the centre by `+rotationRad`, so with y pointing down a
/// positive rotation swings the map clockwise on screen.
///
/// MapLibre's bearing rotates the *camera* — the compass direction the viewer
/// faces, clockwise from north — which swings the content the other way. The
/// two are therefore negatives of each other: `flutter_map` rotation 90°
/// (east at the bottom of the screen, west at the top) is MapLibre bearing
/// 270°.
double maplibreBearing(double flutterMapRotation) => -flutterMapRotation;
