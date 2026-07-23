import 'package:flutter_map_maplibre/src/basemap_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('idle map skips: no update, no repaint, nothing rendered', () {
    expect(
      decideTick(
        updateAvailable: false,
        needsRepaint: false,
        renderedSinceLastTick: false,
      ),
      TickDecision.skipIdle,
    );
  });

  test('a camera render this frame suppresses the tick render', () {
    expect(
      decideTick(
        updateAvailable: true,
        needsRepaint: true,
        renderedSinceLastTick: true,
      ),
      TickDecision.skipRenderedThisFrame,
    );
  });

  test('a pending update with no camera render this frame renders', () {
    expect(
      decideTick(
        updateAvailable: true,
        needsRepaint: false,
        renderedSinceLastTick: false,
      ),
      TickDecision.render,
    );
  });

  test('needs_repaint alone (mid-animation) renders', () {
    expect(
      decideTick(
        updateAvailable: false,
        needsRepaint: true,
        renderedSinceLastTick: false,
      ),
      TickDecision.render,
    );
  });
}
