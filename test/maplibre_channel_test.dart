import 'package:flutter/services.dart';
import 'package:flutter_map_maplibre/src/maplibre_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MapLibreChannel();

  void mockSetCamera(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MapLibreChannel.channel, (call) async {
          return handler(call);
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MapLibreChannel.channel, null);
  });

  test(
    'setCamera resolves true when native reports the frame rendered',
    () async {
      mockSetCamera((call) => <String, Object?>{'rendered': true});
      expect(
        await channel.setCamera(lat: 59, lng: 24, zoom: 12, bearing: 0),
        isTrue,
      );
    },
  );

  test(
    'setCamera resolves false when native reports a failed render',
    () async {
      mockSetCamera((call) => <String, Object?>{'rendered': false});
      expect(
        await channel.setCamera(lat: 59, lng: 24, zoom: 12, bearing: 0),
        isFalse,
      );
    },
  );

  test(
    'setCamera resolves false on a null reply (older native code)',
    () async {
      mockSetCamera((call) => null);
      expect(
        await channel.setCamera(lat: 59, lng: 24, zoom: 12, bearing: 0),
        isFalse,
      );
    },
  );

  test(
    'setCamera resolves false instead of throwing on a platform error',
    () async {
      mockSetCamera((call) => throw PlatformException(code: 'boom'));
      expect(
        await channel.setCamera(lat: 59, lng: 24, zoom: 12, bearing: 0),
        isFalse,
      );
    },
  );
}
