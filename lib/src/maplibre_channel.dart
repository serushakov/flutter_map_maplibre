import 'package:flutter/services.dart';

/// Result of creating a native basemap renderer.
class BasemapCreateResult {
  const BasemapCreateResult({
    required this.ok,
    this.textureId,
    this.error,
    this.diagnostics = const <String, Object?>{},
  });

  final bool ok;
  final int? textureId;
  final String? error;

  /// Platform-reported facts: render timings, frame count, style-load failures.
  final Map<String, Object?> diagnostics;

  @override
  String toString() =>
      'BasemapCreateResult(ok: $ok, textureId: $textureId, error: $error, '
      'diagnostics: $diagnostics)';
}

/// Result of creating the presentation textures (back buffer + ring).
class TexturesCreateResult {
  const TexturesCreateResult({
    required this.ok,
    this.textureId,
    this.backTextureAddress,
    this.error,
    this.diagnostics = const <String, Object?>{},
  });

  final bool ok;
  final int? textureId;

  /// Address of the borrowed MTLTexture the render session attaches to,
  /// passed to mln_metal_borrowed_texture_attach as descriptor.texture.
  final int? backTextureAddress;
  final String? error;
  final Map<String, Object?> diagnostics;
}

/// Method-channel client for the native MapLibre renderer.
///
/// Internal to the package; consumers use `MapLibreBasemap`.
class MapLibreChannel {
  static const MethodChannel channel = MethodChannel(
    'flutter_map_maplibre/probe',
  );

  Future<BasemapCreateResult> create({
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  }) async {
    try {
      final response = await channel.invokeMapMethod<String, Object?>(
        'runMap',
        <String, Object?>{
          'width': width,
          'height': height,
          'scale': scale,
          'styleUrl': styleUrl,
        },
      );
      if (response == null) {
        return const BasemapCreateResult(
          ok: false,
          error: 'null response from native',
        );
      }
      return BasemapCreateResult(
        ok: response['ok'] as bool? ?? false,
        textureId: response['textureId'] as int?,
        error: response['error'] as String?,
        diagnostics:
            (response['diagnostics'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      );
    } on PlatformException catch (e) {
      return BasemapCreateResult(ok: false, error: '${e.code}: ${e.message}');
    }
  }

  /// Pushes the camera to the native renderer, which renders the frame for it
  /// *before* replying — a `true` result means the texture now shows exactly
  /// this camera. That property is what keeps the residual transform honest.
  ///
  /// `false` means the texture is unchanged (failed render, platform error,
  /// or older native code); callers must not treat the camera as rendered.
  ///
  /// [zoom] and [bearing] are in *MapLibre's* units, not `flutter_map`'s — see
  /// `camera_conventions.dart`. They go straight to `mln_map_jump_to`.
  Future<bool> setCamera({
    required double lat,
    required double lng,
    required double zoom,
    required double bearing,
  }) async {
    try {
      final response = await channel.invokeMapMethod<String, Object?>(
        'setCamera',
        <String, Object?>{
          'lat': lat,
          'lng': lng,
          'zoom': zoom,
          'bearing': bearing,
        },
      );
      return response?['rendered'] == true;
    } on PlatformException {
      // A dropped camera push costs one stale frame, nothing more.
      return false;
    }
  }

  /// Swaps the style in place — no renderer teardown, no tile re-download for
  /// sources the two styles share.
  Future<void> setStyle(String styleUrl) async {
    try {
      await channel.invokeMethod<void>('setStyle', <String, Object?>{
        'styleUrl': styleUrl,
      });
    } on PlatformException {
      // Leaves the previous style rendering.
    }
  }

  Future<Map<String, Object?>> diagnostics() async {
    final response = await channel.invokeMapMethod<String, Object?>(
      'mapDiagnostics',
    );
    return response ?? const <String, Object?>{};
  }

  Future<void> dispose() async {
    try {
      await channel.invokeMethod<void>('disposeMap');
    } on PlatformException {
      // Teardown is best-effort.
    }
  }

  Future<TexturesCreateResult> createTextures({
    required int width,
    required int height,
    required double scale,
  }) async {
    try {
      final response = await channel.invokeMapMethod<String, Object?>(
        'createTextures',
        <String, Object?>{'width': width, 'height': height, 'scale': scale},
      );
      if (response == null) {
        return const TexturesCreateResult(ok: false, error: 'null response');
      }
      return TexturesCreateResult(
        ok: response['ok'] as bool? ?? false,
        textureId: response['textureId'] as int?,
        backTextureAddress: response['backTexture'] as int?,
        error: response['error'] as String?,
        diagnostics:
            (response['diagnostics'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      );
    } on PlatformException catch (e) {
      return TexturesCreateResult(ok: false, error: '${e.code}: ${e.message}');
    }
  }

  Future<void> disposeTextures() async {
    try {
      await channel.invokeMethod<void>('disposeTextures');
    } on PlatformException {
      // Teardown is best-effort.
    }
  }
}
