import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_map_maplibre/src/licenses.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLicensesMarkdown', () {
    test('splits the shipped LICENSES.core.md into one notice per section', () {
      final markdown = File(
        'licenses/maplibre-native.LICENSES.core.md',
      ).readAsStringSync();
      final sections = RegExp(
        r'^### ',
        multiLine: true,
      ).allMatches(markdown).length;

      final notices = parseLicensesMarkdown(markdown);

      expect(notices, hasLength(sections));
      expect(notices.first.name, 'Maplibre Native');
      expect(notices.first.text, startsWith('BSD 2-Clause License'));
      expect(notices.map((n) => n.name), contains('RapidJSON'));
      for (final notice in notices) {
        expect(notice.text, isNotEmpty, reason: notice.name);
        expect(notice.text, isNot(contains('```')), reason: notice.name);
      }
    });

    test('keeps the text between the fences and drops the markup', () {
      const markdown = '''
### [alpha](https://example.com/a) by A

```
Copyright (c) A

line two
```

---

### [beta](https://example.com/b)

```
Copyright (c) B
```
''';

      final notices = parseLicensesMarkdown(markdown);

      expect(notices.map((n) => n.name), ['alpha', 'beta']);
      expect(notices.first.text, 'Copyright (c) A\n\nline two');
      expect(notices.last.text, 'Copyright (c) B');
    });
  });

  test('registers every notice with the LicenseRegistry', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // In a host app the assets live under packages/flutter_map_maplibre/;
    // here the package is the root, so serve that key space from disk.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final key = utf8.decode(message!.buffer.asUint8List());
          const prefix = 'packages/flutter_map_maplibre/';
          if (!key.startsWith(prefix)) return null;
          final bytes = File(key.substring(prefix.length)).readAsBytesSync();
          return ByteData.sublistView(bytes);
        });

    registerMaplibreLicenses();
    registerMaplibreLicenses(); // a second call must not duplicate

    final entries = await LicenseRegistry.licenses.toList();
    final packages = entries.expand((e) => e.packages).toList();

    expect(packages.where((p) => p == 'maplibre-native-ffi'), hasLength(1));
    expect(packages, contains('Maplibre Native'));
    expect(packages, contains('Boost C++ Libraries'));
  });
}
