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
/// native renderer, which renders each pushed camera before acknowledging it;
/// the remaining sub-frame gap is closed every Flutter frame by
/// [residualTransform], so the basemap stays pinned to the layers drawn above
/// it instead of sliding against them.
class MapLibreBasemap extends StatefulWidget {
  const MapLibreBasemap({
    super.key,
    required this.styleUrl,
    this.onDiagnostics,
    this.applyResidualTransform = true,
    this.overRenderFactor = 1.0,
  }) : assert(overRenderFactor >= 1.0);

  /// MapLibre style JSON URL. Changing it swaps the style in place without
  /// tearing down the renderer, which is what makes light/dark switching cheap.
  final String styleUrl;

  /// Periodic render statistics, for callers that want to surface or log them.
  final ValueChanged<Map<String, Object?>>? onDiagnostics;

  /// Escape hatch for debugging: with this false the rendered frame is drawn
  /// uncorrected, so the lag between the native renderer and the live camera
  /// becomes visible. Never disable in production.
  final bool applyResidualTransform;

  /// How much larger than the viewport to render, per axis.
  ///
  /// The renderer is always a little behind the live camera, so a stale frame
  /// only has pixels where it was drawn. When the camera *zooms out*, the
  /// residual transform shrinks that frame (scale < 1) and a bare ring appears
  /// around every edge; a pan bares one leading edge. Rendering a margin gives
  /// the transform material to pull into view instead of blank space.
  ///
  /// A factor `F` covers a zoom-out lag of up to `log2(F)` zoom levels and a
  /// pan lag of `(F - 1) / 2` of the viewport per side. The cost is `F * F`
  /// times the fill every frame, paid whether or not the camera is moving —
  /// so this trades constant GPU work for the absence of a transient artefact.
  /// 1.0 (the default) renders exactly the viewport and leaves the edges bare;
  /// reducing latency is the cheaper lever and shrinks the margin this needs.
  final double overRenderFactor;

  @override
  State<MapLibreBasemap> createState() => _MapLibreBasemapState();
}

class _MapLibreBasemapState extends State<MapLibreBasemap> {
  final _channel = MapLibreChannel();

  int? _textureId;

  /// The viewport size the current session was created for (unenlarged). Drives
  /// the recreate decision, so it is compared against the raw layout size.
  Size? _viewportSize;

  /// The size the texture is actually rendered at: [_viewportSize] scaled by
  /// [MapLibreBasemap.overRenderFactor]. Drives the residual transform and the
  /// texture layout, so the margin lands centred on the viewport.
  Size? _renderSize;

  /// The camera most recently pushed to the native renderer, treated as the
  /// camera the current texture contents were rendered with. Stamped only
  /// when the native side confirms the frame for it is in the texture.
  MapCamera? _rendered;

  /// Newest camera seen while a push was in flight, sent once it resolves.
  MapCamera? _pendingCamera;

  bool _pushInFlight = false;
  bool _creating = false;
  Timer? _diagnosticsTimer;

  /// Exponential moving average of _pushCamera call → reply, in ms — the
  /// pipeline latency the residual transform has to absorb, as a number.
  double? _pushToTextureMs;

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
      if (!mounted) return;
      widget.onDiagnostics?.call(<String, Object?>{
        ...diagnostics,
        if (_pushToTextureMs != null)
          'pushToTextureMs': double.parse(_pushToTextureMs!.toStringAsFixed(2)),
      });
    });
  }

  Future<void> _create(Size viewport, double devicePixelRatio) async {
    if (_creating) return;
    _creating = true;

    // Render a margin around the viewport so a zoom-out (which shrinks the
    // frame) has material to pull in from the edges instead of blank space.
    final factor = widget.overRenderFactor;
    final renderSize = Size(viewport.width * factor, viewport.height * factor);

    final result = await _channel.create(
      width: renderSize.width.round(),
      height: renderSize.height.round(),
      scale: devicePixelRatio,
      styleUrl: widget.styleUrl,
    );

    if (!mounted) return;
    setState(() {
      _textureId = result.textureId;
      _viewportSize = viewport;
      _renderSize = renderSize;
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
  /// Completing a push calls `setState`, which rebuilds, which pushes again —
  /// so without a stopping condition an idle map drives a permanent loop of
  /// channel round-trips.
  ///
  /// The native side renders the frame *before* replying, so a `true` result
  /// means the texture now shows exactly [camera] — stamping `_rendered` here
  /// is honest. On `false` the texture is unchanged and `_rendered` must stay
  /// put: the transform then keeps correcting relative to what is actually
  /// on screen, and the next camera change (or the animation-driven display
  /// link) repairs the content.
  void _pushCamera(MapCamera camera) {
    if (_textureId == null) return;
    if (_sameCamera(_rendered, camera)) return;

    // Mid-gesture the camera moves again before the previous push resolves.
    // Hold the newest and send it on completion: dropping it would leave the
    // texture rendered for a slightly stale camera once the gesture ends, and
    // nothing would rebuild to correct it.
    if (_pushInFlight) {
      _pendingCamera = camera;
      return;
    }

    _pushInFlight = true;
    final pushClock = Stopwatch()..start();
    _channel
        .setCamera(
          lat: camera.center.latitude,
          lng: camera.center.longitude,
          zoom: maplibreZoom(camera.zoom),
          bearing: maplibreBearing(camera.rotation),
        )
        .then((rendered) {
          _pushInFlight = false;
          if (!mounted) return;

          if (rendered) {
            final ms = pushClock.elapsedMicroseconds / 1000.0;
            _pushToTextureMs = _pushToTextureMs == null
                ? ms
                : _pushToTextureMs! * 0.8 + ms * 0.2;
            setState(() => _rendered = camera);
          }

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
        // bottom sheet drags, hence the tolerance. Compared against the
        // unenlarged viewport, since that is what `size` is.
        final current = _viewportSize;
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

        // Push during build, not post-frame: flutter_map rebuilds this widget
        // in the same frame the gesture moves the camera, so pushing here
        // starts the native render a full frame earlier. The send is
        // fire-and-forget async — its setState happens on reply, never
        // during this build.
        _pushCamera(camera);

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
