import 'package:flutter/services.dart';

/// Outcome of a single texture probe run.
///
/// [diagnostics] carries the platform-specific facts the probe exists to
/// establish — they are the point of the probe, not decoration.
class ProbeResult {
  const ProbeResult({
    required this.ok,
    this.textureId,
    this.error,
    this.diagnostics = const <String, Object?>{},
  });

  final bool ok;
  final int? textureId;
  final String? error;
  final Map<String, Object?> diagnostics;

  @override
  String toString() =>
      'ProbeResult(ok: $ok, textureId: $textureId, error: $error, '
      'diagnostics: $diagnostics)';
}

/// Allocates a Flutter-registered texture, has native clear it via the
/// platform GPU API, and reports what happened.
class TextureProbe {
  static const MethodChannel channel = MethodChannel(
    'flutter_map_maplibre/probe',
  );

  Future<ProbeResult> run({required int width, required int height}) async {
    try {
      final response = await channel.invokeMapMethod<String, Object?>(
        'runProbe',
        <String, Object?>{'width': width, 'height': height},
      );

      if (response == null) {
        return const ProbeResult(ok: false, error: 'null response from native');
      }

      return ProbeResult(
        ok: response['ok'] as bool? ?? false,
        textureId: response['textureId'] as int?,
        error: response['error'] as String?,
        diagnostics:
            (response['diagnostics'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      );
    } on PlatformException catch (e) {
      return ProbeResult(ok: false, error: '${e.code}: ${e.message}');
    }
  }

  /// Spike: render a real MapLibre map into a Flutter texture.
  Future<ProbeResult> runMap({
    required int width,
    required int height,
    double scale = 2.0,
    String? styleUrl,
  }) async {
    try {
      final response = await channel.invokeMapMethod<String, Object?>(
        'runMap',
        <String, Object?>{
          'width': width,
          'height': height,
          'scale': scale,
          'styleUrl': ?styleUrl,
        },
      );
      if (response == null) {
        return const ProbeResult(ok: false, error: 'null response from native');
      }
      return ProbeResult(
        ok: response['ok'] as bool? ?? false,
        textureId: response['textureId'] as int?,
        error: response['error'] as String?,
        diagnostics:
            (response['diagnostics'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      );
    } on PlatformException catch (e) {
      return ProbeResult(ok: false, error: '${e.code}: ${e.message}');
    }
  }

  /// Live diagnostics from a running map probe (frame count, load errors).
  Future<Map<String, Object?>> mapDiagnostics() async {
    final response = await channel.invokeMapMethod<String, Object?>(
      'mapDiagnostics',
    );
    return response ?? const <String, Object?>{};
  }
}
