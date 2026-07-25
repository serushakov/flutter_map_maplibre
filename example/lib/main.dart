import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:latlong2/latlong.dart';

void main() => runApp(const ExampleApp());

const _tallinn = LatLng(59.437, 24.7536);
// OpenFreeMap: full-planet OSM vector tiles, open infrastructure, no API key.
const _light = 'https://tiles.openfreemap.org/styles/liberty';
const _darkStyle = 'https://tiles.openfreemap.org/styles/dark';

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: MapPage());
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with SingleTickerProviderStateMixin {
  final _mapController = MapController();
  Map<String, Object?> _diagnostics = const {};
  bool _dark = false;
  Ticker? _ticker;

  /// Android display-latency compensation, in frames. Cycled live so the
  /// right depth can be found by feel: the setting where the marker locks to
  /// the map during a pan is the true BufferQueue latch latency.
  int _latencyFrames = FfiBasemapRenderer.androidPresentLatencyFrames;

  void _cycleLatencyFrames() {
    setState(() {
      _latencyFrames = (_latencyFrames + 1) % 4;
      FfiBasemapRenderer.androidPresentLatencyFrames = _latencyFrames;
    });
  }

  /// Render-resolution ladder: fraction of native dpr the map renders at.
  /// Cycling recreates the session (brief style reload) — fine for a knob.
  static const _renderScales = [1.0, 0.85, 0.7, 0.55];
  int _renderScaleIndex = 0;

  void _cycleRenderScale() {
    setState(() {
      _renderScaleIndex = (_renderScaleIndex + 1) % _renderScales.length;
    });
  }

  /// Drives pan, zoom and rotation at once — the condition the residual
  /// transform exists for.
  void _toggleAutoPan() {
    if (_ticker != null) {
      _ticker!.dispose();
      setState(() => _ticker = null);
      return;
    }
    final ticker = createTicker((elapsed) {
      final t = elapsed.inMilliseconds / 1000.0;
      _mapController.moveAndRotate(
        LatLng(
          _tallinn.latitude + 0.012 * math.sin(t * 1.1),
          _tallinn.longitude + 0.022 * math.cos(t * 0.9),
        ),
        13.0 + 0.6 * math.sin(t * 0.7),
        18.0 * math.sin(t * 0.5),
      );
    })..start();
    setState(() => _ticker = ticker);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = _diagnostics.entries
        .map((e) => '${e.key}: ${e.value}')
        .join('   ');

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(initialCenter: _tallinn, initialZoom: 13),
            children: [
              MapLibreBasemap(
                styleUrl: _dark ? _darkStyle : _light,
                // Margin so the lead bias can keep the leading edge covered
                // during flicks: on Android the placed frame is one present
                // old (BufferQueue latch), which bares a velocity x 8.3ms
                // strip without it.
                overRenderFactor: 1.1,
                renderScale: _renderScales[_renderScaleIndex],
                onDiagnostics: (d) {
                  if (mounted) setState(() => _diagnostics = d);
                },
              ),
              MarkerLayer(
                markers: const [
                  Marker(
                    point: _tallinn,
                    width: 20,
                    height: 20,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(0xFFFF2D55),
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                          BorderSide(color: Colors.white, width: 3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'theme',
                      onPressed: () => setState(() => _dark = !_dark),
                      child: Icon(_dark ? Icons.light_mode : Icons.dark_mode),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'pan',
                      onPressed: _toggleAutoPan,
                      child: Icon(
                        _ticker == null ? Icons.play_arrow : Icons.pause,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'latency',
                      onPressed: _cycleLatencyFrames,
                      child: Text('$_latencyFrames'),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'scale',
                      onPressed: _cycleRenderScale,
                      child: Text(
                        '${(_renderScales[_renderScaleIndex] * 100).round()}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (stats.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 24,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    stats,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
