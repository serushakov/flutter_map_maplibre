import 'dart:ffi';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../maplibre_channel.dart';
import 'mln_library.dart';

typedef _PresentNative = Double Function(Int64);
typedef _FillNative = Int32 Function(Int64, Double, Double, Double);

/// Device probe (spec, risk 2): drives the TexturePresenter from the Dart UI
/// thread with a solid-color hue sweep — no MapLibre involved. A smooth sweep
/// on screen proves fmm_debug_fill/fmm_present resolve via dlsym and that
/// textureFrameAvailable fired from the UI thread reaches the engine at the
/// full frame rate. Temporary; deleted with the spike.
class FfiPresentProbe extends StatefulWidget {
  const FfiPresentProbe({super.key});

  @override
  State<FfiPresentProbe> createState() => _FfiPresentProbeState();
}

class _FfiPresentProbeState extends State<FfiPresentProbe>
    with SingleTickerProviderStateMixin {
  final _channel = MapLibreChannel();
  int? _textureId;
  Ticker? _ticker;
  int _frame = 0;
  double _lastBlitMs = -1;

  late final _present = mlnLibrary
      .lookupFunction<_PresentNative, double Function(int)>('fmm_present');
  late final _fill = mlnLibrary
      .lookupFunction<_FillNative, int Function(int, double, double, double)>(
        'fmm_debug_fill',
      );

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    final result = await _channel.createTextures(
      width: 200,
      height: 200,
      scale: 2.0,
    );
    if (!mounted || !result.ok) {
      debugPrint('MLNFFIPROBE createTextures failed: ${result.error}');
      return;
    }
    setState(() => _textureId = result.textureId);
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration _) {
    final id = _textureId;
    if (id == null) return;
    _frame++;
    // Slow hue sweep: ~4s per cycle at 120Hz. Stalls or freezes mean the
    // UI-thread textureFrameAvailable is not reaching the engine.
    final hue = (_frame % 480) / 480.0;
    final color = HSVColor.fromAHSV(1, hue * 360, 1, 1).toColor();
    final filled = _fill(id, color.r, color.g, color.b);
    if (filled != 0) {
      debugPrint('MLNFFIPROBE fill failed: $filled');
      return;
    }
    _lastBlitMs = _present(id);
    if (_frame % 120 == 0) {
      debugPrint('MLNFFIPROBE frame=$_frame blitMs=$_lastBlitMs');
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    final id = _textureId;
    if (id != null) _channel.disposeTextures(textureId: id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _textureId;
    if (textureId == null) return const SizedBox.shrink();
    return SizedBox(
      width: 200,
      height: 200,
      child: Texture(textureId: textureId),
    );
  }
}
