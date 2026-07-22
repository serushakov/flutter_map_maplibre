import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map_maplibre/src/probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(TextureProbe.channel, null);
  });

  test('parses a successful probe response', () async {
    late MethodCall received;
    messenger.setMockMethodCallHandler(TextureProbe.channel, (call) async {
      received = call;
      return <String, Object?>{
        'ok': true,
        'textureId': 7,
        'diagnostics': <String, Object?>{'usageRenderTarget': true},
      };
    });

    final result = await TextureProbe().run(width: 64, height: 32);

    expect(received.method, 'runProbe');
    expect(received.arguments, <String, Object?>{'width': 64, 'height': 32});
    expect(result.ok, isTrue);
    expect(result.textureId, 7);
    expect(result.error, isNull);
    expect(result.diagnostics['usageRenderTarget'], isTrue);
  });

  test('parses a failed probe response', () async {
    messenger.setMockMethodCallHandler(TextureProbe.channel, (call) async {
      return <String, Object?>{
        'ok': false,
        'error': 'eglCreateWindowSurface returned EGL_NO_SURFACE',
        'diagnostics': <String, Object?>{
          'eglSurfaceCreated': false,
          'eglErrorAfterCreateWindowSurface': 12291,
        },
      };
    });

    final result = await TextureProbe().run(width: 64, height: 32);

    expect(result.ok, isFalse);
    expect(result.textureId, isNull);
    expect(result.error, 'eglCreateWindowSurface returned EGL_NO_SURFACE');
    expect(result.diagnostics['eglSurfaceCreated'], isFalse);
    expect(result.diagnostics['eglErrorAfterCreateWindowSurface'], 12291);
  });

  test('surfaces a PlatformException as a failed result', () async {
    messenger.setMockMethodCallHandler(TextureProbe.channel, (call) async {
      throw PlatformException(code: 'PROBE_THREW', message: 'boom');
    });

    final result = await TextureProbe().run(width: 64, height: 32);

    expect(result.ok, isFalse);
    expect(result.error, contains('boom'));
  });
}
