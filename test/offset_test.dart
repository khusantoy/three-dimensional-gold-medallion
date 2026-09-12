// Polygon offsetting, the one piece the rim band needs.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/contour.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/extruder.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/offset.dart';

List<Vec2> square(double half) => <Vec2>[
  Vec2(-half, -half),
  Vec2(half, -half),
  Vec2(half, half),
  Vec2(-half, half),
];

List<Vec2> circle(double radius, int steps) => <Vec2>[
  for (var i = 0; i < steps; i++)
    Vec2(
      radius * math.cos(i / steps * 2 * math.pi),
      radius * math.sin(i / steps * 2 * math.pi),
    ),
];

void main() {
  group('offsetInward', () {
    test('shrinks a square by exactly the offset on every side', () {
      final inset = offsetInward(square(1.0), 0.2);
      for (final p in inset) {
        expect(p.x.abs(), closeTo(0.8, 1e-9));
        expect(p.y.abs(), closeTo(0.8, 1e-9));
      }
    });

    test('shrinks whichever way the ring is wound', () {
      final clockwise = square(1.0).reversed.toList();
      final inset = offsetInward(clockwise, 0.2);
      expect(Contour(inset).area, closeTo(0.8 * 2 * 0.8 * 2, 1e-9));
    });

    test('keeps a circle concentric', () {
      final inset = offsetInward(circle(1.0, 64), 0.15);
      for (final p in inset) {
        // A polygon inscribed in the circle offsets to slightly inside the
        // true offset circle; the point is that every vertex agrees.
        expect(math.sqrt(p.x * p.x + p.y * p.y), closeTo(0.85, 0.01));
      }
    });

    test('does not shoot a sharp corner off to infinity', () {
      // A narrow spike: an unclamped miter would send its tip far outside
      // the original shape.
      final spike = <Vec2>[
        const Vec2(0, 10),
        const Vec2(1, 0),
        const Vec2(-1, 0),
      ];
      final inset = offsetInward(spike, 0.3);
      for (final p in inset) {
        expect(p.x.abs(), lessThan(3), reason: 'miter ran away');
        expect(p.y.abs(), lessThan(12), reason: 'miter ran away');
      }
    });

    test('a zero offset changes nothing', () {
      final ring = square(1.0);
      expect(identical(offsetInward(ring, 0), ring), isTrue);
    });
  });

  group('bandInside', () {
    test('returns the ring and its inset, the inset being smaller', () {
      final band = bandInside(square(1.0), 0.2)!;
      expect(band, hasLength(2));
      expect(band[1].area, lessThan(band[0].area));
    });

    test('extrudes with the inset as a hole', () {
      // Normalised into the 0..1 square the in-place extruder expects.
      final ring = <Vec2>[
        for (final p in circle(0.45, 48)) Vec2(p.x + 0.5, p.y + 0.5),
      ];
      final band = bandInside(ring, 0.06)!;
      final result = Extruder.fromContoursInPlace(band, depth: 0.03);

      expect(result.error, isNull, reason: result.error?.message);
      expect(result.mesh!.holeCount, 1, reason: 'the band is solid, not a ring');
    });

    test('refuses a shape too narrow to carry the band', () {
      // A sliver 0.1 wide cannot hold a 0.2 band: the inset would invert.
      final sliver = <Vec2>[
        const Vec2(0, 0),
        const Vec2(2, 0),
        const Vec2(2, 0.1),
        const Vec2(0, 0.1),
      ];
      expect(bandInside(sliver, 0.2), isNull);
    });

    test('refuses a degenerate ring rather than emitting garbage', () {
      expect(bandInside(<Vec2>[const Vec2(0, 0), const Vec2(1, 1)], 0.1), isNull);
      expect(bandInside(square(1.0), 0), isNull);
    });
  });
}
