import 'dart:ui';

import 'package:flutter_map_maplibre/src/lead_bias.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const maxBias = Size(100, 150);
  const lead = Duration(milliseconds: 30);
  const frame = Duration(milliseconds: 16);

  /// Feed [n] frames of constant [travel] per 16ms frame.
  void feed(LeadBias bias, Offset travel, int n) {
    for (var i = 0; i < n; i++) {
      bias.update(
        travel: travel,
        elapsed: frame,
        maxBias: maxBias,
        leadTime: lead,
      );
    }
  }

  test('constant velocity converges: applied = velocity × leadTime', () {
    final bias = LeadBias();
    // 30px per 16ms = 1875 px/s east; 40 frames = 640ms >> 100ms EMA tau.
    feed(bias, const Offset(30, 0), 40);
    expect(bias.velocity.dx, closeTo(1875, 20));
    expect(bias.applied.dx, closeTo(1875 * 0.030, 1.5));
    expect(bias.applied.dy, closeTo(0, 1e-9));
  });

  test('clamped to safetyFactor × maxBias per axis', () {
    final bias = LeadBias();
    // 6250 px/s → desired 187.5px, far beyond the 100px margin.
    feed(bias, const Offset(100, 0), 40);
    expect(bias.applied.dx, closeTo(85, 1)); // 0.85 × 100
  });

  test('freeze on zero travel: applied and velocity untouched', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    final appliedBefore = bias.applied;
    final velocityBefore = bias.velocity;
    feed(bias, Offset.zero, 10);
    expect(bias.applied, appliedBefore);
    expect(bias.velocity, velocityBefore);
  });

  test('freeze on zero elapsed', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    final before = bias.applied;
    bias.update(
      travel: const Offset(30, 0),
      elapsed: Duration.zero,
      maxBias: maxBias,
      leadTime: lead,
    );
    expect(bias.applied, before);
  });

  test('hysteresis: sub-quantum desired change leaves applied untouched', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    final before = bias.applied;
    // One slightly faster frame: EMA moves desired well under the 8px
    // quantum, so applied must not move at all.
    bias.update(
      travel: const Offset(31, 0),
      elapsed: frame,
      maxBias: maxBias,
      leadTime: lead,
    );
    expect(bias.applied, before);
  });

  test('reversal flips the bias within the time constant', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    feed(bias, const Offset(-30, 0), 40);
    expect(bias.applied.dx, closeTo(-1875 * 0.030, 1.5));
  });

  test('reset zeroes everything', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    bias.reset();
    expect(bias.applied, Offset.zero);
    expect(bias.velocity, Offset.zero);
  });
}
