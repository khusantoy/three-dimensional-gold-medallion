// The relief bake, checked without a GPU: it is pure byte-in, byte-out.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/artwork_analyzer.dart';

/// An RGBA image builder for fixtures.
Uint8List image(int side, List<int> Function(int x, int y) colour) {
  final out = Uint8List(side * side * 4);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final c = colour(x, y);
      final i = (y * side + x) * 4;
      out[i] = c[0];
      out[i + 1] = c[1];
      out[i + 2] = c[2];
      out[i + 3] = c.length > 3 ? c[3] : 255;
    }
  }
  return out;
}

/// Decodes one pixel of a normal map back to a unit vector.
(double, double, double) normalAt(Uint8List map, int side, int x, int y) {
  final i = (y * side + x) * 4;
  return (
    map[i] / 255 * 2 - 1,
    map[i + 1] / 255 * 2 - 1,
    map[i + 2] / 255 * 2 - 1,
  );
}

void main() {
  group('gold detection', () {
    test('a warm, contrasty stripe is read as gold', () {
      const side = 64;
      // A gold band down the middle of a blue field. The band alternates
      // brightness so it has the local contrast real painted metal has.
      final pixels = image(side, (x, y) {
        if (x > 24 && x < 40) {
          final bright = (x + y) % 4 < 2;
          return bright
              ? <int>[230, 190, 90]
              : <int>[150, 115, 50];
        }
        return <int>[30, 50, 140];
      });

      final relief = ArtworkAnalyzer.analyze(pixels, side);
      expect(relief.goldFraction, greaterThan(0.10));
      expect(relief.goldFraction, lessThan(0.40));
    });

    test('a flat blue field has no gold in it at all', () {
      const side = 64;
      final relief = ArtworkAnalyzer.analyze(
        image(side, (_, _) => <int>[30, 50, 140]),
        side,
      );
      expect(relief.goldPixelCount, 0);
    });

    test('flat warm paint is not gold: metal has local contrast', () {
      const side = 64;
      // Warm enough to pass the colour test, but perfectly even, so the
      // second pass against the blurred luminance rejects it. Terracotta and
      // skin fail here, which is the point.
      final relief = ArtworkAnalyzer.analyze(
        image(side, (_, _) => <int>[190, 140, 90]),
        side,
      );
      expect(relief.goldPixelCount, 0);
    });

    test('blown-out highlights count as gold even without local contrast', () {
      const side = 64;
      final relief = ArtworkAnalyzer.analyze(
        image(side, (x, _) => x < 32 ? <int>[250, 240, 200] : <int>[30, 50, 140]),
        side,
      );
      expect(relief.goldPixelCount, greaterThan(0));
    });

    test('transparent pixels are outside the pin and carry no gold', () {
      const side = 64;
      final relief = ArtworkAnalyzer.analyze(
        image(side, (x, y) {
          final bright = (x + y) % 4 < 2;
          final c = bright ? <int>[230, 190, 90] : <int>[150, 115, 50];
          return <int>[c[0], c[1], c[2], 0]; // fully transparent
        }),
        side,
      );
      expect(relief.goldPixelCount, 0);
    });
  });

  group('normal map', () {
    test('is flat where the artwork has no gold', () {
      const side = 32;
      final relief = ArtworkAnalyzer.analyze(
        image(side, (_, _) => <int>[30, 50, 140]),
        side,
      );
      final (nx, ny, nz) = normalAt(relief.normalMap, side, 16, 16);
      expect(nx, closeTo(0, 0.02));
      expect(ny, closeTo(0, 0.02));
      expect(nz, closeTo(1, 0.02));
    });

    test('tilts outward on both sides of a raised edge', () {
      const side = 64;
      // Left half gold, right half not: the seam is a cliff the relief has
      // to slope down.
      final pixels = image(side, (x, y) {
        if (x < 32) {
          return (x + y) % 4 < 2 ? <int>[230, 190, 90] : <int>[150, 115, 50];
        }
        return <int>[30, 50, 140];
      });
      final relief = ArtworkAnalyzer.analyze(pixels, side);

      // At the seam the height falls as x rises, so nx = -(right-left)/2 is
      // positive: the surface tilts back toward the gold.
      final (seamX, _, _) = normalAt(relief.normalMap, side, 32, 32);
      expect(seamX, greaterThan(0.05), reason: 'the edge is not raised');

      // Deep inside the flat gold there is no slope left.
      final (flatX, flatY, flatZ) = normalAt(relief.normalMap, side, 10, 32);
      expect(flatX.abs(), lessThan(0.35));
      expect(flatZ, greaterThan(0.85));
      expect(flatY.abs(), lessThan(0.35));
    });

    test('every normal it writes is a unit vector', () {
      const side = 48;
      final relief = ArtworkAnalyzer.analyze(
        image(side, (x, y) => (x ~/ 6 + y ~/ 6).isEven
            ? <int>[240, 200, 100]
            : <int>[40, 40, 120]),
        side,
      );
      for (var y = 0; y < side; y++) {
        for (var x = 0; x < side; x++) {
          final (nx, ny, nz) = normalAt(relief.normalMap, side, x, y);
          expect(
            math.sqrt(nx * nx + ny * ny + nz * nz),
            closeTo(1.0, 0.01),
            reason: 'normal at $x,$y is not normalised',
          );
          expect(nz, greaterThan(0), reason: 'relief points into the surface');
        }
      }
    });
  });

  group('metallic-roughness map', () {
    test('follows the glTF packing: B metallic, G roughness', () {
      const side = 64;
      final pixels = image(side, (x, y) {
        if (x < 32) {
          return (x + y) % 4 < 2 ? <int>[230, 190, 90] : <int>[150, 115, 50];
        }
        return <int>[30, 50, 140];
      });
      final relief = ArtworkAnalyzer.analyze(pixels, side);
      final map = relief.metallicRoughnessMap;

      int metallic(int x, int y) => map[((y * side + x) * 4) + 2];
      int roughness(int x, int y) => map[((y * side + x) * 4) + 1];

      expect(metallic(10, 32), 255, reason: 'gold is not metal');
      expect(metallic(55, 32), 0, reason: 'the blue field is metal');

      // Gold is glossier than the painted face, or it does not read as metal.
      expect(roughness(10, 32), lessThan(roughness(55, 32)));
      expect(
        roughness(55, 32),
        (ArtworkAnalyzer.baseRoughness * 255).round(),
      );
    });

    test('leaves the red channel alone, as glTF expects', () {
      const side = 32;
      final relief = ArtworkAnalyzer.analyze(
        image(side, (_, _) => <int>[240, 200, 100]),
        side,
      );
      for (var i = 0; i < side * side; i++) {
        expect(relief.metallicRoughnessMap[i * 4], 0);
        expect(relief.metallicRoughnessMap[i * 4 + 3], 255);
      }
    });
  });

  group('morphology', () {
    test('closing bridges a pinhole without growing the shape', () {
      const side = 9;
      final mask = List<bool>.filled(side * side, false);
      for (var y = 2; y <= 6; y++) {
        for (var x = 2; x <= 6; x++) {
          mask[y * side + x] = true;
        }
      }
      mask[4 * side + 4] = false; // one pixel punched out

      final closed = ArtworkAnalyzer.closed(mask, side, side, 1);
      expect(closed[4 * side + 4], isTrue, reason: 'pinhole not bridged');
      expect(closed[0], isFalse, reason: 'the shape grew');
    });

    test('opening removes a one-pixel spur', () {
      const side = 9;
      final mask = List<bool>.filled(side * side, false);
      for (var y = 3; y <= 5; y++) {
        for (var x = 3; x <= 5; x++) {
          mask[y * side + x] = true;
        }
      }
      mask[4 * side + 7] = true; // a detached speck

      final opened = ArtworkAnalyzer.opened(mask, side, side, 1);
      expect(opened[4 * side + 7], isFalse, reason: 'speck survived');
    });

    test('box blur preserves the mean of a constant field', () {
      final values = Float32List.fromList(List<double>.filled(64 * 64, 0.7));
      final blurred = ArtworkAnalyzer.boxBlur(values, 64, 4);
      for (final v in blurred) {
        expect(v, closeTo(0.7, 1e-5));
      }
    });
  });
}
