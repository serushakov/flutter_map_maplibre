import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import 'basemap_renderer.dart';
import 'ffi/ffi_basemap_renderer.dart';
import 'lead_bias.dart';
import 'maplibre_channel.dart';
import 'render_admission.dart';
import 'residual_transform.dart';
import 'under_render.dart';
import 'viewport_crop.dart';

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
/// The camera stays owned by `flutter_map`. Each build renders the frame
/// synchronously via dart:ffi before returning, so the texture content
/// matches the camera by construction and the basemap draws at identity —
/// no estimation, no stamping. The residual transform survives only as the
/// failure fallback, correcting against the renderer's ground-truth
/// [BasemapRenderer.lastRenderedCamera].
/// When the hosting layout is deliberately larger than what is visible, see
/// [fixedViewport].
class MapLibreBasemap extends StatefulWidget {
  const MapLibreBasemap({
    super.key,
    required this.styleUrl,
    this.onDiagnostics,
    this.frameCap,
    this.applyResidualTransform = true,
    this.overRenderFactor = 1.0,
    this.renderScale = 1.0,
    this.admissionGuardPx = 16.0,
    this.admissionZoomQuantum = 0.05,
    this.fixedViewport,
    this.viewportAlignment = Alignment.bottomCenter,
    this.rendererFactory,
  }) : assert(overRenderFactor >= 1.0),
       assert(renderScale > 0.0 && renderScale <= 1.0);

  /// MapLibre style JSON URL. Changing it swaps the style in place without
  /// tearing down the renderer, which is what makes light/dark switching
  /// cheap.
  final String styleUrl;

  /// Periodic render statistics, for callers that want to surface or log
  /// them.
  final ValueChanged<Map<String, Object?>>? onDiagnostics;

  /// Minimum interval between presented native frames — the power-saving
  /// cap (see [BasemapRenderer.frameCap]). Null means uncapped. Only the
  /// native render rate drops; the Flutter ticker and gesture pipeline are
  /// unaffected.
  final Duration? frameCap;

  /// Escape hatch for debugging: with this false a failed render is drawn
  /// uncorrected. Never disable in production.
  final bool applyResidualTransform;

  /// How much larger than the viewport to render, per axis. With the
  /// same-frame render the texture is never behind the camera on the happy
  /// path, so 1.0 (exact viewport) is the expected value; the margin only
  /// papers over failure frames.
  final double overRenderFactor;

  /// Fraction of the device pixel ratio to render at. 1.0 renders native
  /// resolution; lower trades sharpness for fill-rate — on high-density
  /// panels (3.5 dpr) 0.7-0.85 is hard to tell apart while cutting fragment
  /// work by the square. The texture is upscaled by the compositor; camera
  /// math is unaffected (the map's logical size never changes).
  final double renderScale;

  /// Admission guard band: a camera-driven render is admitted only when the
  /// viewport comes within this many logical px of the rendered canvas's
  /// edge (or crosses [admissionZoomQuantum]). Between admissions the
  /// residual transform places the existing frame — exact under translation.
  final double admissionGuardPx;

  /// Zoom drift from the rendered frame that admits a render on its own.
  /// Zooming in never bares the canvas, so without this quantum labels
  /// would blur indefinitely under coverage-only admission.
  final double admissionZoomQuantum;

  /// When set, the texture viewport is pinned to this size and layout size
  /// changes never recreate the session. Use when the layer's widget is
  /// deliberately laid out larger than what is visible (Vedu lays the map
  /// out taller than the screen to push the camera center above the bottom
  /// sheet): pass the truly visible size and the offscreen remainder is
  /// never rendered. Null means the layout size is the viewport, recreating
  /// on any layout change.
  final Size? fixedViewport;

  /// Where the fixed viewport sits inside the (possibly larger) layer.
  /// Ignored when [fixedViewport] is null.
  final Alignment viewportAlignment;

  /// Test seam: build the renderer. Defaults to the FFI implementation.
  final BasemapRenderer Function()? rendererFactory;

  @override
  State<MapLibreBasemap> createState() => _MapLibreBasemapState();
}

class _MapLibreBasemapState extends State<MapLibreBasemap>
    with SingleTickerProviderStateMixin {
  final _channel = MapLibreChannel();
  late final BasemapRenderer _renderer =
      (widget.rendererFactory ?? FfiBasemapRenderer.new)();

  int? _textureId;

  /// The viewport size the current session was created for (unenlarged).
  Size? _viewportSize;

  /// [_viewportSize] scaled by [MapLibreBasemap.overRenderFactor]; what the
  /// texture is actually rendered at.
  Size? _renderSize;

  /// The [MapLibreBasemap.overRenderFactor] the live session was created
  /// with. Session identity — [needsCreate] — is keyed on this alongside
  /// [_viewportSize] so a factor change is caught even if it lands mid-flight
  /// against an in-progress [_create] (see [_create]'s stale-callback guard).
  double? _sessionFactor;

  /// The [MapLibreBasemap.renderScale] the live session was created with —
  /// session identity alongside [_sessionFactor], same staleness rules.
  double? _sessionScale;

  Ticker? _ticker;
  Timer? _insurancePump;
  int _parks = 0;
  bool _creating = false;
  Timer? _diagnosticsTimer;

  final _leadBias = LeadBias();
  MapCamera? _prevBiasCamera;
  Duration? _prevBiasTime;

  /// The worst [underRenderPx] observed since the last diagnostics poll —
  /// max, not average, since a single bared frame is what a user sees.
  double _underRenderPxMax = 0;

  /// Camera-driven admission counters (cumulative, like [_parks]): how many
  /// gate DECISIONS rendered vs placed the existing frame. Only builds whose
  /// camera differs from [_gateCamera] (or where [_settleForced] forces an
  /// admission) move either counter — a same-camera rebuild (parent rebuild,
  /// idle tick) touches neither, so these stay an honest count of
  /// camera-driven admission decisions rather than every build. `admits`
  /// counts admitted attempts, including ones the frame cap then deferred.
  int _admits = 0;
  int _admissionSkips = 0;

  /// The unbiased `camera` ([MapCamera.of]) the admission gate last
  /// evaluated — compared against the current build's camera to tell a
  /// camera-driven build apart from a same-camera rebuild for
  /// [_admits]/[_admissionSkips]. Updated every build that reaches the gate,
  /// regardless of outcome.
  MapCamera? _gateCamera;

  /// Set by the settle timer to force one exact render after a gesture ends
  /// off-quantum; cleared by the next successful render.
  bool _settleForced = false;

  Timer? _settleTimer;

  /// The camera the running settle window was armed against; a build with a
  /// different camera re-arms, a rebuild with the same camera leaves the
  /// window running (parent rebuilds must not push settling out forever).
  MapCamera? _settleArmedFor;

  @override
  void didUpdateWidget(MapLibreBasemap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.styleUrl != widget.styleUrl) {
      _renderer.setStyle(widget.styleUrl);
      _wake();
    }
    // overRenderFactor changes are caught by build's needsCreate comparing
    // _sessionFactor — factor-aware session identity, race-free even against
    // an in-flight _create (see _create's stale-callback guard).
  }

  @override
  void dispose() {
    debugPrint(
      'MLNDISPOSE state=${identityHashCode(this)} textureId=$_textureId',
    );
    _ticker?.dispose();
    _insurancePump?.cancel();
    _diagnosticsTimer?.cancel();
    _settleTimer?.cancel();
    _renderer.dispose();
    _channel.disposeTextures();
    super.dispose();
  }

  /// Ticker: lets the map animate itself (tile fades, transitions) between
  /// camera changes. When a tick presents a new frame the widget rebuilds so
  /// the transform stays true to the new content. When the renderer reports
  /// the map idle the ticker parks — an active Ticker forces the whole app
  /// pipeline to run at display rate even when every tick is a no-op.
  void _onTick(Duration _) {
    if (_renderer.tick() && mounted) setState(() {});
    if (_renderer.canSleep) _park();
  }

  /// Stop requesting frames and fall back to the slow insurance pump. The
  /// pump drives owner-thread tasks (tile expiry refreshes) that would
  /// otherwise freeze while parked, and wakes the ticker if work appears.
  void _park() {
    final ticker = _ticker;
    if (ticker == null || !ticker.isActive) return;
    ticker.stop();
    _parks++;
    _insurancePump ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _renderer.pumpWork()) _wake();
    });
  }

  /// Idempotent: restart the ticker and drop the insurance pump.
  void _wake() {
    _insurancePump?.cancel();
    _insurancePump = null;
    final ticker = _ticker;
    if (ticker != null && !ticker.isActive) ticker.start();
  }

  void _startDiagnosticsPolling() {
    if (widget.onDiagnostics == null || _diagnosticsTimer != null) return;
    _diagnosticsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      widget.onDiagnostics?.call(<String, Object?>{
        ..._renderer.diagnostics(),
        'tickerActive': _ticker?.isActive ?? false,
        'parks': _parks,
        'underRenderPx': _underRenderPxMax,
        'admits': _admits,
        'admissionSkips': _admissionSkips,
      });
      _underRenderPxMax = 0;
    });
  }

  Future<void> _create(Size viewport, double devicePixelRatio) async {
    if (_creating) return;
    // Defense against stale post-frame callbacks: every build during an
    // in-flight create schedules another call, and under jank one can fire
    // after the create lands. Recreating a live same-size, same-factor
    // session tears a working map down into seconds of blank style reload.
    // The factor check also matters mid-flight: if overRenderFactor changes
    // while a create is in progress, that in-flight create must not be
    // treated as satisfying the new factor once it lands — build's
    // needsCreate (keyed on _sessionFactor) will schedule a follow-up create,
    // and this guard must let it through rather than early-returning.
    final existing = _viewportSize;
    if (existing != null &&
        (existing.width - viewport.width).abs() <= 1 &&
        (existing.height - viewport.height).abs() <= 1 &&
        _sessionFactor == widget.overRenderFactor &&
        _sessionScale == widget.renderScale) {
      return;
    }
    _creating = true;
    debugPrint(
      'MLNCREATE start state=${identityHashCode(this)} '
      'viewport=${viewport.width.round()}x${viewport.height.round()} '
      'had=$_textureId',
    );

    // Resize path: the borrowed-texture session cannot be resized in place.
    if (_textureId != null) {
      _renderer.dispose();
      await _channel.disposeTextures();
      _textureId = null;
    }

    final factor = widget.overRenderFactor;
    final renderSize = Size(viewport.width * factor, viewport.height * factor);

    final result = await _channel.createTextures(
      width: renderSize.width.round(),
      height: renderSize.height.round(),
      scale: devicePixelRatio,
    );
    if (!mounted ||
        !result.ok ||
        result.textureId == null ||
        result.backTextureAddress == null) {
      debugPrint(
        'MLNCREATE textures failed mounted=$mounted ok=${result.ok} '
        'diag=${result.diagnostics}',
      );
      widget.onDiagnostics?.call(result.diagnostics);
      // On !mounted the native presenter was still created; without this it
      // sits orphaned at viewport-resolution GPU memory until the next create.
      _channel.disposeTextures();
      // A previously-parked widget's insurance pump would otherwise run
      // forever against a session that no longer exists; nothing else will
      // restart the ticker on this dead path.
      _insurancePump?.cancel();
      _insurancePump = null;
      _creating = false;
      return;
    }

    final created = _renderer.create(
      backTextureAddress: result.backTextureAddress!,
      presenterId: result.textureId!,
      width: renderSize.width.round(),
      height: renderSize.height.round(),
      scale: devicePixelRatio,
      styleUrl: widget.styleUrl,
    );
    if (!created) {
      debugPrint('MLNCREATE renderer failed diag=${_renderer.diagnostics()}');
      widget.onDiagnostics?.call(_renderer.diagnostics());
      // The renderer failed but the presenter exists — don't orphan it.
      _channel.disposeTextures();
      // Same as above: don't leave the insurance pump running against a
      // renderer create that failed.
      _insurancePump?.cancel();
      _insurancePump = null;
      _creating = false;
      return;
    }

    debugPrint(
      'MLNCREATE ok state=${identityHashCode(this)} '
      'textureId=${result.textureId} '
      'viewport=${viewport.width.round()}x${viewport.height.round()} '
      'scale=$devicePixelRatio',
    );
    setState(() {
      _textureId = result.textureId;
      _viewportSize = viewport;
      _renderSize = renderSize;
      _sessionFactor = factor;
      _sessionScale = widget.renderScale;
      // A new session has a new margin; a bias frozen against the old
      // margin must not leak into it.
      _leadBias.reset();
      _prevBiasCamera = null;
      _prevBiasTime = null;
      // A settle timer armed against the old session must not fire into the
      // new one (it would force-admit against a renderer that just reset).
      _settleTimer?.cancel();
      _settleTimer = null;
      _settleArmedFor = null;
      _settleForced = false;
    });
    _ticker ??= createTicker(_onTick);
    _wake();
    _startDiagnosticsPolling();
    _creating = false;
  }

  /// The camera to render: [cropped] shifted ahead of motion so the fixed
  /// over-render margin becomes runway for capped frames. Active whenever a
  /// margin exists; otherwise returns [cropped] itself (same instance — the
  /// caller uses identity to detect bias).
  MapCamera _biasedCamera(MapCamera cropped, Size renderSize) {
    final viewport = cropped.nonRotatedSize;
    final maxBias = Size(
      (renderSize.width - viewport.width) / 2,
      (renderSize.height - viewport.height) / 2,
    );
    final cap = widget.frameCap;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    if (maxBias.isEmpty) {
      _leadBias.reset();
      _prevBiasCamera = cropped;
      _prevBiasTime = now;
      return cropped;
    }
    final prev = _prevBiasCamera;
    final prevTime = _prevBiasTime;
    final elapsed = prevTime == null ? Duration.zero : now - prevTime;
    final center = viewport.center(Offset.zero);
    final travel = prev == null
        ? Offset.zero
        : center - cropped.latLngToScreenOffset(prev.center);
    _prevBiasCamera = cropped;
    _prevBiasTime = now;
    final bias = _leadBias.update(
      travel: travel,
      elapsed: elapsed,
      maxBias: maxBias,
      // Capped: cover one cap interval of staleness with 2x headroom.
      // Uncapped (admission-gated only): a constant — bias saturates its
      // clamp at fling speeds regardless, and at follow speeds it is
      // negligible either way.
      leadTime: cap == null ? const Duration(milliseconds: 33) : cap * 2,
    );
    if (bias == Offset.zero) return cropped;
    return cropped.withPosition(
      center: cropped.screenOffsetToLatLng(center + bias),
    );
  }

  /// One-shot settle: when the camera rests while the rendered frame is
  /// off-target in zoom or bearing (a pinch ended mid-quantum), land one
  /// exact render so the map does not rest blurry. Never periodic — after
  /// the settle render the ticker parks through the unchanged decideSleep
  /// path (spec criterion 4).
  void _manageSettle({
    required bool rendered,
    required MapCamera? shown,
    required MapCamera current,
  }) {
    if (rendered || !settleOffTarget(rendered: shown, current: current)) {
      _settleTimer?.cancel();
      _settleTimer = null;
      _settleArmedFor = null;
      return;
    }
    final armed = _settleArmedFor;
    final sameCamera =
        armed != null &&
        armed.center == current.center &&
        armed.zoom == current.zoom &&
        armed.rotation == current.rotation;
    if (_settleTimer != null && sameCamera) return; // window keeps running
    _settleArmedFor = current;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _settleForced = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutSize = constraints.biggest;
        final devicePixelRatio =
            MediaQuery.devicePixelRatioOf(context) * widget.renderScale;

        // The viewport the session must match: pinned when [fixedViewport]
        // is set, the layout size otherwise. Layout sizes churn every frame
        // while a bottom sheet drags, hence the tolerance.
        final viewport = widget.fixedViewport ?? layoutSize;
        final current = _viewportSize;
        final needsCreate =
            current == null ||
            (current.width - viewport.width).abs() > 1 ||
            (current.height - viewport.height).abs() > 1 ||
            _sessionFactor != widget.overRenderFactor ||
            _sessionScale != widget.renderScale;

        if (needsCreate && viewport.isFinite && !viewport.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _create(viewport, devicePixelRatio);
          });
        }

        final textureId = _textureId;
        final renderSize = _renderSize;

        if (textureId == null || renderSize == null) {
          return const SizedBox.shrink();
        }

        // The part of the layer the texture covers: the whole layer when the
        // viewport is unpinned, the aligned sub-rect when it is pinned — the
        // rest of the layer is clipped offscreen by construction and never
        // rendered.
        final visibleRect = widget.viewportAlignment.inscribe(
          viewport,
          Offset.zero & layoutSize,
        );

        // The same-frame render: by the time this build returns, the front
        // buffer shows [visibleRect]'s view of [camera] (on success). No
        // stamp, no estimate. Under a frame cap the target is lead-biased
        // ahead of motion so capped frames keep the leading edge covered.
        _renderer.frameCap = widget.frameCap;
        final cropped = cropCamera(camera, visibleRect);
        final target = _biasedCamera(cropped, renderSize);
        final biased = !identical(target, cropped);
        // The admission gate: render only when the viewport nears the
        // rendered canvas's runway or crosses a zoom/bearing quantum;
        // otherwise the residual transform places the existing frame, which
        // is pixel-exact under translation. Compared against the UNBIASED
        // current camera — lastRenderedCamera is ground truth for the canvas.
        final admit =
            _settleForced ||
            shouldAdmitRender(
              rendered: _renderer.lastRenderedCamera,
              renderSize: renderSize,
              current: camera,
              visibleRect: visibleRect,
              guardPx: widget.admissionGuardPx,
              zoomQuantum: widget.admissionZoomQuantum,
            );
        // Only count camera-driven gate decisions: a same-camera rebuild
        // (parent rebuild, idle tick) must not inflate admissionSkips, and a
        // tick-driven no-op rebuild must not inflate admits. A settle-forced
        // admission always counts, even though its camera did not move.
        final gatePrev = _gateCamera;
        final cameraChanged =
            gatePrev == null ||
            gatePrev.center != camera.center ||
            gatePrev.zoom != camera.zoom ||
            gatePrev.rotation != camera.rotation;
        if (cameraChanged || _settleForced) {
          if (admit) {
            _admits++;
          } else {
            _admissionSkips++;
          }
        }
        _gateCamera = camera;
        final rendered = admit && _renderer.render(target);
        if (rendered) _settleForced = false;
        final shown = _renderer.lastRenderedCamera;
        _manageSettle(rendered: rendered, shown: shown, current: cropped);

        // A camera jump cleared the renderer's idle latch; make sure the
        // ticker runs to carry the aftermath (tile loads, fades). A
        // same-camera rebuild leaves a parked ticker parked.
        if (!_renderer.canSleep) _wake();

        // On success the texture needs only to be moved onto [visibleRect]
        // (identity when the viewport is unpinned and unenlarged). The
        // renderer draws the camera centered on the [renderSize] canvas, so
        // any over-render margin hangs symmetrically around the center and
        // the placement must pull the texture back by half of it — without
        // this, an enlarged texture sits offset under the markers on every
        // admitted frame while capped frames (placed by the residual
        // formula, which does account for the size) sit right, and the map
        // visibly jumps between the two. On failure the residual places the
        // stale cropped frame in the full layer's frame — the formula
        // already accounts for the size mismatch, no extra translate. First
        // frame before any successful render: draw unplaced rather than
        // hide the map (a hidden map is indistinguishable from a broken
        // renderer). A biased success frame goes through the residual
        // instead — exact for any rendered/current pair, so no placement
        // jump at the bias boundary.
        final placed = Matrix4.identity()
          ..translateByDouble(
            visibleRect.left - (renderSize.width - viewport.width) / 2,
            visibleRect.top - (renderSize.height - viewport.height) / 2,
            0,
            1,
          );
        // The `placed` shortcut assumes a successful render is on screen in
        // this very frame. That is literally true on iOS (the presenter
        // hands the buffer to the frame being rasterized) and false on
        // Android, where eglSwapBuffers queues into a BufferQueue that the
        // engine latches frames later — the shortcut would pin the texture
        // as if current while it still shows an older camera, and the map
        // trails every overlaid marker by the latch latency. There the
        // residual places what is actually on screen: `shown` runs behind
        // by FfiBasemapRenderer.androidPresentLatencyFrames presents.
        final syncPresent = !Platform.isAndroid;
        final transform =
            ((rendered && !biased && syncPresent) || shown == null)
            ? placed
            : widget.applyResidualTransform
            ? residualTransform(
                rendered: shown.withNonRotatedSize(renderSize),
                current: camera,
              )
            : placed;

        // The acceptance instrument for the lead bias: whenever the shown
        // frame is not this build's camera, measure the bared strip.
        if (shown != null && (!rendered || biased || !syncPresent)) {
          final uncovered = underRenderPx(
            rendered: shown,
            renderSize: renderSize,
            current: camera,
            visibleRect: visibleRect,
          );
          if (uncovered > _underRenderPxMax) _underRenderPxMax = uncovered;
        }

        return Transform(
          transform: transform,
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
