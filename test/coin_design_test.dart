// Checks the ported Minted geometry against the proportions it encodes.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/coin_design.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/contour.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/extruder.dart';

void main() {
  group('silhouette radius', () {
    test('seal scallops between 0.42 and 0.50', () {
      const geometry = CoinGeometry(CoinSilhouette.seal);
      var min = double.infinity, max = -double.infinity;
      for (var i = 0; i < 720; i++) {
        final r = geometry.radiusAt(i / 720 * 2 * math.pi);
        min = math.min(min, r);
        max = math.max(max, r);
      }
      expect(min, closeTo(0.42, 1e-6));
      expect(max, closeTo(0.50, 1e-6));
    });

    test('circle is constant', () {
      const geometry = CoinGeometry(CoinSilhouette.circle);
      for (var i = 0; i < 90; i++) {
        expect(geometry.radiusAt(i / 90 * 2 * math.pi), closeTo(0.48, 1e-9));
      }
    });

    test('silhouette radii match the Swift original', () {
      // The 0..1 square is a design convention, not a clip: the diamond
      // squircle reaches 0.524 on the axes and deliberately overhangs it.
      // These ranges are read off the ported formulas and pin them against
      // drift.
      const expected = <CoinSilhouette, (double, double)>{
        CoinSilhouette.seal: (0.42, 0.50),
        CoinSilhouette.octagon: (0.41, 0.47),
        CoinSilhouette.circle: (0.48, 0.48),
        CoinSilhouette.diamond: (0.46, 0.5238),
        CoinSilhouette.custom: (0.46, 0.46),
      };

      for (final entry in expected.entries) {
        final geometry = CoinGeometry(entry.key);
        var min = double.infinity, max = -double.infinity;
        for (var i = 0; i < 720; i++) {
          final r = geometry.radiusAt(i / 720 * 2 * math.pi);
          min = math.min(min, r);
          max = math.max(max, r);
        }
        expect(min, closeTo(entry.value.$1, 1e-3), reason: entry.key.name);
        expect(max, closeTo(entry.value.$2, 1e-3), reason: entry.key.name);
      }
    });

    test('diamond peaks on the diagonals', () {
      const geometry = CoinGeometry(CoinSilhouette.diamond);
      // The squircle is written about theta = pi/4, so its minimum radius is
      // there and it reaches furthest on the axes.
      expect(geometry.radiusAt(math.pi / 4), closeTo(0.46, 1e-6));
      expect(geometry.radiusAt(0), greaterThan(0.46));
    });
  });

  group('decorative geometry', () {
    const geometry = CoinGeometry(CoinSilhouette.seal);

    test('petals are ten separate ring sectors', () {
      final petals = geometry.petalContours();
      expect(petals, hasLength(10));
      for (final petal in petals) {
        expect(petal.area, greaterThan(0));
      }
    });

    test('rays are twenty-eight ticks between the field radii', () {
      final rays = geometry.rayContours();
      expect(rays, hasLength(28));
      for (final ray in rays) {
        for (final p in ray.points) {
          final r = math.sqrt(
            math.pow(p.x - 0.5, 2) + math.pow(p.y - 0.5, 2),
          );
          expect(r, inInclusiveRange(0.224, 0.293));
        }
      }
    });

    test('beads are forty-four discs just inside the rim', () {
      final beads = geometry.beadContours();
      expect(beads, hasLength(44));
      for (var i = 0; i < beads.length; i++) {
        final theta = i / beads.length * 2 * math.pi;
        final expected = geometry.radiusAt(theta) * 0.90;
        // Centroid of the bead should sit on the 0.90 ring.
        var sx = 0.0, sy = 0.0;
        for (final p in beads[i].points) {
          sx += p.x;
          sy += p.y;
        }
        final n = beads[i].points.length;
        final r = math.sqrt(
          math.pow(sx / n - 0.5, 2) + math.pow(sy / n - 0.5, 2),
        );
        expect(r, closeTo(expected, 1e-3));
      }
    });

    test('lattice bars stay inside the field disc', () {
      final bars = geometry.latticeContours();
      expect(bars.length, greaterThan(8));
      expect(bars.length.isEven, isTrue, reason: 'one vertical per horizontal');
      for (final bar in bars) {
        for (final p in bar.points) {
          final r = math.sqrt(
            math.pow(p.x - 0.5, 2) + math.pow(p.y - 0.5, 2),
          );
          expect(r, lessThanOrEqualTo(0.30));
        }
      }
    });

    test('the rim band is concentric and keeps its width', () {
      final band = geometry.bandContours(CoinMetrics.outerBandWidth);
      expect(band, hasLength(2));
      final outer = band[0].points;
      final inner = band[1].points;
      expect(outer.length, inner.length);

      // Offsetting the original, not re-tracing a shrunk mask: the gap must
      // be the band width at every single sample, including on the scallops.
      for (var i = 0; i < outer.length; i++) {
        final ro = math.sqrt(
          math.pow(outer[i].x - 0.5, 2) + math.pow(outer[i].y - 0.5, 2),
        );
        final ri = math.sqrt(
          math.pow(inner[i].x - 0.5, 2) + math.pow(inner[i].y - 0.5, 2),
        );
        expect(ro - ri, closeTo(CoinMetrics.outerBandWidth, 1e-9));
      }
    });

    test('a rim band extrudes with its inner ring as a hole', () {
      final band = geometry.bandContours(CoinMetrics.outerBandWidth);
      final result = Extruder.fromContours(band);
      expect(result.error, isNull, reason: result.error?.message);
      expect(result.mesh!.holeCount, 1);
    });
  });

  group('slab stacking', () {
    test('every slab front sits proud of the face and its back stays buried',
        () {
      const half = CoinMetrics.baseDepth / 2;
      const rises = <String, double>{
        'field': CoinMetrics.fieldRise,
        'petal': CoinMetrics.petalRise,
        'pattern': CoinMetrics.patternRise,
        'outerBand': CoinMetrics.outerBandRise,
        'art': CoinMetrics.artRise,
        'bead': CoinMetrics.beadRise,
        'innerBand': CoinMetrics.innerBandRise,
        'wire': CoinMetrics.wireRise,
      };

      for (final entry in rises.entries) {
        final centre = CoinMetrics.slabCentreZ(CoinMetrics.slabDepth, entry.value);
        final front = centre + CoinMetrics.slabDepth / 2;
        final back = centre - CoinMetrics.slabDepth / 2;
        expect(front, greaterThan(half), reason: '${entry.key} is not proud');
        expect(back, greaterThan(-half),
            reason: '${entry.key} pokes out the reverse');
      }
    });

    test('the stack orders back to front the way Minted layers it', () {
      double front(double rise) =>
          CoinMetrics.slabCentreZ(CoinMetrics.slabDepth, rise) +
          CoinMetrics.slabDepth / 2;

      // Field sits lowest, the gold wire highest, with the art between.
      expect(front(CoinMetrics.fieldRise), lessThan(front(CoinMetrics.petalRise)));
      expect(front(CoinMetrics.petalRise), lessThan(front(CoinMetrics.patternRise)));
      expect(front(CoinMetrics.patternRise), lessThan(front(CoinMetrics.artRise)));
      expect(front(CoinMetrics.artRise), lessThan(front(CoinMetrics.wireRise)));
    });
  });

  group('normalization', () {
    test('normalizeContours fits the longest side to exactly 1', () {
      final wide = <Contour>[
        Contour(<Vec2>[
          const Vec2(10, 40),
          const Vec2(210, 40),
          const Vec2(210, 90),
          const Vec2(10, 90),
        ]),
      ];
      final fitted = normalizeContours(wide);
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final p in fitted.single.points) {
        minX = math.min(minX, p.x);
        maxX = math.max(maxX, p.x);
        minY = math.min(minY, p.y);
        maxY = math.max(maxY, p.y);
      }
      expect(maxX - minX, closeTo(1.0, 1e-9));
      // Aspect ratio preserved, and centred on the square.
      expect(maxY - minY, closeTo(0.25, 1e-9));
      expect((minY + maxY) / 2, closeTo(0.5, 1e-9));
    });

    test('centreContours places art at the requested fraction', () {
      final art = <Contour>[
        Contour(<Vec2>[
          const Vec2(0, 0),
          const Vec2(100, 0),
          const Vec2(100, 100),
          const Vec2(0, 100),
        ]),
      ];
      final placed = centreContours(art, CoinMetrics.artScale);
      var minX = double.infinity, maxX = -double.infinity;
      for (final p in placed.single.points) {
        minX = math.min(minX, p.x);
        maxX = math.max(maxX, p.x);
      }
      expect(maxX - minX, closeTo(CoinMetrics.artScale, 1e-9));
      expect((minX + maxX) / 2, closeTo(0.5, 1e-9));
    });
  });
}
