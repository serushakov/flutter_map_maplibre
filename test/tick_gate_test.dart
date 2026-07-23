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

  test('sleep: idle since the last jump with clear flags may park', () {
    expect(
      decideSleep(
        idleSinceLastJump: true,
        updateAvailable: false,
        needsRepaint: false,
      ),
      isTrue,
    );
  });

  test('sleep: clear flags alone are not enough — tiles for a new camera '
      'can be loading with no repaint requested', () {
    expect(
      decideSleep(
        idleSinceLastJump: false,
        updateAvailable: false,
        needsRepaint: false,
      ),
      isFalse,
    );
  });

  test('sleep: a pending update vetoes the park even after idle', () {
    expect(
      decideSleep(
        idleSinceLastJump: true,
        updateAvailable: true,
        needsRepaint: false,
      ),
      isFalse,
    );
  });

  test('sleep: a repaint request vetoes the park even after idle', () {
    expect(
      decideSleep(
        idleSinceLastJump: true,
        updateAvailable: false,
        needsRepaint: true,
      ),
      isFalse,
    );
  });
}
