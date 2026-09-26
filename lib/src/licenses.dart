import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _assetDir = 'packages/flutter_map_maplibre/licenses';

bool _registered = false;

/// Adds the notices of the natively linked MapLibre stack to Flutter's
/// [LicenseRegistry], so they appear on the app's licenses page
/// (`showLicensePage` / `LicensePage`).
///
/// Flutter collects the LICENSE file of every Dart package on its own, but
/// not the licenses of native code a plugin links. This plugin links
/// maplibre-native-ffi and MapLibre Native — and their bundled third-party
/// libraries — statically into the host app, and their BSD-style licenses
/// require binary redistributions to reproduce the notices. Call this once
/// at startup, on every platform where the plugin is built into the app,
/// whether or not a map is ever shown.
///
/// Cheap: registration is synchronous and the texts are only read from the
/// asset bundle when the licenses page asks for them. Repeated calls are
/// no-ops.
void registerMaplibreLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(_entries);
}

Stream<LicenseEntry> _entries() async* {
  final ffi = await rootBundle.loadString(
    '$_assetDir/maplibre-native-ffi.LICENSE',
  );
  yield LicenseEntryWithLineBreaks(const ['maplibre-native-ffi'], ffi);
  final core = await rootBundle.loadString(
    '$_assetDir/maplibre-native.LICENSES.core.md',
  );
  for (final notice in parseLicensesMarkdown(core)) {
    yield LicenseEntryWithLineBreaks([notice.name], notice.text);
  }
}

/// Splits MapLibre Native's `LICENSES.core.md` into one notice per bundled
/// component: each section is a `### [name](url) by ...` heading followed
/// by the license in a fenced code block.
@visibleForTesting
List<({String name, String text})> parseLicensesMarkdown(String markdown) {
  final heading = RegExp(r'^### \[([^\]]+)\]', multiLine: true);
  final matches = heading.allMatches(markdown).toList();
  final notices = <({String name, String text})>[];
  for (var i = 0; i < matches.length; i++) {
    final end = i + 1 < matches.length ? matches[i + 1].start : markdown.length;
    final section = markdown.substring(matches[i].end, end);
    final open = section.indexOf('```');
    if (open < 0) continue;
    final bodyStart = section.indexOf('\n', open) + 1;
    final close = section.indexOf('```', bodyStart);
    if (bodyStart == 0 || close < 0) continue;
    notices.add((
      name: matches[i].group(1)!,
      text: section.substring(bodyStart, close).trim(),
    ));
  }
  return notices;
}
