import 'package:flutter/services.dart';

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
/// Cold-path only: texture lifecycle (`createTextures`/`disposeTextures`).
/// The hot path — camera pushes and per-frame rendering — goes over
/// dart:ffi instead; see `FfiBasemapRenderer`.
class MapLibreChannel {
  static const MethodChannel channel = MethodChannel(
    'flutter_map_maplibre/probe',
  );

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

  Future<void> disposeTextures({required int textureId}) async {
    try {
      await channel.invokeMethod<void>('disposeTextures', <String, Object?>{
        'textureId': textureId,
      });
    } on PlatformException {
      // Teardown is best-effort.
    }
  }
}
