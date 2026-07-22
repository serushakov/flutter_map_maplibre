import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import 'camera_conventions.dart';
import 'maplibre_channel.dart';
import 'residual_transform.dart';

/// A natively-rendered MapLibre vector basemap, for use as a `flutter_map`
/// layer in place of `TileLayer`.
///
/// Drop it in as the first child of a [FlutterMap]; everything above it —
/// markers, polylines, overlays — stays ordinary Flutter widgets:
///
/// ```dart
/// FlutterMap(
///   options: ...,
///   children: [
///     MapLibreBasemap(styleUrl: 'https://.../style.json'),
///     MarkerLayer(markers: ...),
///   ],
/// )
/// ```
///
/// The camera stays owned by `flutter_map`. Camera changes are pushed to the
/// native renderer, which is always at least a frame behind; that gap is closed
/// every Flutter frame by [residualTransform], so the basemap stays pinned to
/// the layers drawn above it instead of sliding against them.
class MapLibreBasemap extends StatefulWidget {
  const MapLibreBasemap({
    super.key,
    required this.styleUrl,
    this.onDiagnostics,
    this.applyResidualTransform = true,
  });

  /// MapLibre style JSON URL. Changing it swaps the style in place without
  /// tearing down the renderer, which is what makes light/dark switching cheap.
  final String styleUrl;

  /// Periodic render statistics, for callers that want to surface or log them.
  final ValueChanged<Map<String, Object?>>? onDiagnostics;

  /// Escape hatch for debugging: with this false the rendered frame is drawn
  /// uncorrected, so the lag between the native renderer and the live camera
  /// becomes visible. Never disable in production.
  final bool applyResidualTransform;

  @override
  State<MapLibreBasemap> createState() => _MapLibreBasemapState();
}

class _MapLibreBasemapState extends State<MapLibreBasemap> {
  final _channel = MapLibreChannel();

  int? _textureId;
  Size? _renderSize;

  /// The camera most recently pushed to the native renderer, treated as the
  /// camera the current texture contents were rendered with. True within a
  /// frame or two — exactly what the residual transform absorbs.
  MapCamera? _rendered;

  /// Newest camera seen while a push was in flight, sent once it resolves.
  MapCamera? _pendingCamera;

  bool _pushInFlight = false;
  bool _creating = false;
  Timer? _diagnosticsTimer;

  @override
  void didUpdateWidget(MapLibreBasemap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.styleUrl != widget.styleUrl && _textureId != null) {
      _channel.setStyle(widget.styleUrl);
    }
  }

  @override
  void dispose() {
    _diagnosticsTimer?.cancel();
    _channel.dispose();
    super.dispose();
  }

  /// Only polls while a caller is listening — no cost otherwise.
  void _startDiagnosticsPolling() {
    if (widget.onDiagnostics == null || _diagnosticsTimer != null) return;
    _diagnosticsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final diagnostics = await _channel.diagnostics();
      if (mounted) widget.onDiagnostics?.call(diagnostics);
    });
  }

  Future<void> _create(Size size, double devicePixelRatio) async {
    if (_creating) return;
    _creating = true;

    final result = await _channel.create(
      width: size.width.round(),
      height: size.height.round(),
      scale: devicePixelRatio,
      styleUrl: widget.styleUrl,
    );

    if (!mounted) return;
    setState(() {
      _textureId = result.textureId;
      _renderSize = size;
    });

    widget.onDiagnostics?.call(result.diagnostics);
    _startDiagnosticsPolling();
  }

  /// True when the native renderer is already showing this exact camera, so
  /// pushing it again would be pure cost.
  static bool _sameCamera(MapCamera? a, MapCamera b) =>
      a != null &&
      a.center.latitude == b.center.latitude &&
      a.center.longitude == b.center.longitude &&
      a.zoom == b.zoom &&
      a.rotation == b.rotation;

  /// Pushes [camera] to the renderer, at most one call in flight.
  ///
  /// The early return on an unchanged camera is what makes the widget settle.
  /// Completing a push calls `setState`, which rebuilds, which schedules the
  /// next push — so without a stopping condition an idle map drives a
  /// permanent loop of channel round-trips, each one telling MapLibre via
  /// `mln_map_request_repaint` that the map is dirty when nothing moved.
  void _pushCamera(MapCamera camera) {
    if (_textureId == null) return;
    if (_sameCamera(_rendered, camera)) return;

    // Mid-gesture the camera moves again before the previous push resolves.
    // Hold the newest and send it on completion: dropping it would leave the
    // texture rendered for a slightly stale camera once the gesture ends, and
    // nothing would rebuild to correct it. The residual transform keeps that
    // placed correctly, but it would be visibly rendered for the wrong zoom.
    if (_pushInFlight) {
      _pendingCamera = camera;
      return;
    }

    _pushInFlight = true;
    _channel
        .setCamera(
          lat: camera.center.latitude,
          lng: camera.center.longitude,
          zoom: maplibreZoom(camera.zoom),
          bearing: maplibreBearing(camera.rotation),
        )
        .whenComplete(() {
          _pushInFlight = false;
          if (!mounted) return;
          setState(() => _rendered = camera);

          final pending = _pendingCamera;
          _pendingCamera = null;
          if (pending != null && !_sameCamera(camera, pending)) {
            _pushCamera(pending);
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

        // The borrowed-texture session cannot be resized in place, so a size
        // change means creating a new one. Sizes churn every frame while a
        // bottom sheet drags, hence the tolerance.
        final current = _renderSize;
        final needsCreate =
            current == null ||
            (current.width - size.width).abs() > 1 ||
            (current.height - size.height).abs() > 1;

        if (needsCreate && size.isFinite && !size.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _create(size, devicePixelRatio);
          });
        }

        final textureId = _textureId;
        final renderSize = _renderSize;
        final rendered = _rendered;

        if (textureId == null || renderSize == null) {
          return const SizedBox.shrink();
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pushCamera(camera);
        });

        // Draw the texture from the first frame. Waiting for the first camera
        // push to resolve means a failed/slow push hides the map entirely,
        // which is indistinguishable from the renderer not working.
        final renderedOrCurrent = rendered ?? camera;

        return Transform(
          transform: widget.applyResidualTransform
              ? residualTransform(
                  rendered: renderedOrCurrent.withNonRotatedSize(renderSize),
                  current: camera,
                )
              : Matrix4.identity(),
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: renderSize.width,
            maxWidth: renderSize.width,
            minHeight: renderSize.height,
            maxHeight: renderSize.height,
            child: Texture(textureId: textureId),
          ),
        );
      },
    );
  }
}
