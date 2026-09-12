// Layer A is pure Dart: no widget binding, no GPU, no flutter_scene.
import 'package:flutter_test/flutter_test.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/contour.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/earcut.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/extruder.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/svg_flattener.dart';

/// Twice the signed area of a triangle in the XY plane. Positive is
/// counter-clockwise seen from +Z.
double signedArea2(List<double> p, int a, int b, int c) {
  final ax = p[a * 3], ay = p[a * 3 + 1];
  final bx = p[b * 3], by = p[b * 3 + 1];
  final cx = p[c * 3], cy = p[c * 3 + 1];
  return (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
}

void main() {
  group('SvgFlattener', () {
    test('parses a closed triangle into one contour', () {
      final contours = SvgFlattener.flatten('M 0 0 L 10 0 L 5 10 Z');
      expect(contours, hasLength(1));
      expect(contours.single.points, hasLength(3));
    });

    test('handles relative commands and shorthands', () {
      final contours = SvgFlattener.flatten('m 0 0 h 10 v 10 h -10 z');
      expect(contours, hasLength(1));
      expect(contours.single.area, closeTo(100, 1e-6));
    });

    test('flattens an elliptical arc into chords', () {
      // path_parsing converts A into cubics; we only flatten them.
      final contours = SvgFlattener.flatten(
        'M 10 0 A 10 10 0 1 0 -10 0 A 10 10 0 1 0 10 0 Z',
      );
      expect(contours, hasLength(1));
      // A circle of radius 10 has area ~314.
      expect(contours.single.area, closeTo(314.16, 2.0));
    });

    test('closes an open contour rather than dropping it', () {
      // No Z. An unclosed outline would otherwise vanish silently.
      final contours = SvgFlattener.flatten('M 0 0 L 10 0 L 5 10');
      expect(contours, hasLength(1));
      expect(contours.single.area, closeTo(50, 1e-6));
    });

    test('separates subpaths into separate contours', () {
      final contours = SvgFlattener.flatten(
        'M 0 0 L 10 0 L 5 10 Z M 20 0 L 30 0 L 25 10 Z',
      );
      expect(contours, hasLength(2));
    });
  });

  group('Earcut', () {
    test('triangulates a convex square counter-clockwise', () {
      final square = <Vec2>[
        const Vec2(0, 0),
        const Vec2(1, 0),
        const Vec2(1, 1),
        const Vec2(0, 1),
      ];
      final tris = Earcut.triangulate(square, const [])!;
      expect(tris, hasLength(6)); // two triangles

      // Every emitted triangle must wind counter-clockwise in the XY plane,
      // because the cap builder relies on that to face +Z.
      final flat = Earcut.flatten(square, const []);
      for (var i = 0; i < tris.length; i += 3) {
        final a = flat[tris[i]], b = flat[tris[i + 1]], c = flat[tris[i + 2]];
        final area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);
        expect(area, greaterThan(0), reason: 'triangle $i wound clockwise');
      }
    });

    test('triangulates a concave shape without spanning the notch', () {
      // An arrowhead: the notch at the bottom is concave, so a triangle fan
      // from any single vertex would cover area outside the polygon.
      final arrow = <Vec2>[
        const Vec2(0, 4),
        const Vec2(2, 0),
        const Vec2(0, 1),
        const Vec2(-2, 0),
      ];
      final tris = Earcut.triangulate(arrow, const [])!;
      expect(tris, hasLength(6));

      final flat = Earcut.flatten(arrow, const []);
      var total = 0.0;
      for (var i = 0; i < tris.length; i += 3) {
        final a = flat[tris[i]], b = flat[tris[i + 1]], c = flat[tris[i + 2]];
        total +=
            ((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)).abs() / 2;
      }
      // Triangle area must equal polygon area: no overlap, no coverage of
      // the concave notch.
      expect(total, closeTo(Contour(arrow).area, 1e-9));
    });

    test('cuts a hole out of a ring', () {
      final outer = <Vec2>[
        const Vec2(-2, -2),
        const Vec2(2, -2),
        const Vec2(2, 2),
        const Vec2(-2, 2),
      ];
      final hole = <Vec2>[
        const Vec2(-1, -1),
        const Vec2(-1, 1),
        const Vec2(1, 1),
        const Vec2(1, -1),
      ];
      final tris = Earcut.triangulate(outer, [hole])!;
      final flat = Earcut.flatten(outer, [hole]);

      var total = 0.0;
      for (var i = 0; i < tris.length; i += 3) {
        final a = flat[tris[i]], b = flat[tris[i + 1]], c = flat[tris[i + 2]];
        total +=
            ((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)).abs() / 2;
      }
      // 4x4 outer minus 2x2 hole.
      expect(total, closeTo(16 - 4, 1e-9));
    });

    test('returns null for a degenerate ring', () {
      expect(
        Earcut.triangulate(
          <Vec2>[const Vec2(0, 0), const Vec2(1, 1), const Vec2(2, 2)],
          const [],
        ),
        isNull,
      );
    });
  });

  group('Extruder', () {
    test('a concave heart produces a watertight-looking solid', () {
      const heart =
          'M 50 90 C 20 65, 5 45, 5 30 C 5 15, 18 5, 32 5 C 41 5, 47 10, 50 16 '
          'C 53 10, 59 5, 68 5 C 82 5, 95 15, 95 30 C 95 45, 80 65, 50 90 Z';
      final result = Extruder.fromSvgPathData(heart);
      expect(result.error, isNull, reason: result.error?.message);

      final mesh = result.mesh!;
      expect(mesh.triangleCount, greaterThan(50));
      expect(mesh.contourCount, 1);
      expect(mesh.holeCount, 0);
      expect(mesh.normals.length, mesh.positions.length);
      expect(mesh.texCoords.length ~/ 2, mesh.vertexCount);

      // Every index must be in range: out-of-range indices are silent
      // failure trap #14 and produce triangles stretching to the origin.
      for (final i in mesh.indices) {
        expect(i, lessThan(mesh.vertexCount));
      }

      // Every normal must be unit length, or the lighting is wrong.
      for (var v = 0; v < mesh.vertexCount; v++) {
        final nx = mesh.normals[v * 3];
        final ny = mesh.normals[v * 3 + 1];
        final nz = mesh.normals[v * 3 + 2];
        expect(nx * nx + ny * ny + nz * nz, closeTo(1.0, 1e-4));
      }
    });

    test('front and back caps face opposite ways', () {
      final result = Extruder.fromSvgPathData('M 0 0 L 10 0 L 5 10 Z');
      final mesh = result.mesh!;

      var frontFacing = 0;
      var backFacing = 0;
      for (var v = 0; v < mesh.vertexCount; v++) {
        final nz = mesh.normals[v * 3 + 2];
        if (nz > 0.99) frontFacing++;
        if (nz < -0.99) backFacing++;
      }
      expect(frontFacing, greaterThan(0));
      expect(frontFacing, backFacing);
    });

    test('cap triangles wind counter-clockwise seen from outside', () {
      final result = Extruder.fromSvgPathData('M 0 0 L 10 0 L 5 10 Z');
      final mesh = result.mesh!;
      final positions = mesh.positions.toList();

      var checkedFront = 0;
      var checkedBack = 0;
      for (var t = 0; t < mesh.triangleCount; t++) {
        final a = mesh.indices[t * 3];
        final b = mesh.indices[t * 3 + 1];
        final c = mesh.indices[t * 3 + 2];
        final nz = mesh.normals[a * 3 + 2];
        if (nz > 0.99) {
          // Facing +Z, so CCW in XY.
          expect(signedArea2(positions, a, b, c), greaterThan(0));
          checkedFront++;
        } else if (nz < -0.99) {
          // Facing -Z, so CW in XY (CCW when viewed from behind).
          expect(signedArea2(positions, a, b, c), lessThan(0));
          checkedBack++;
        }
      }
      expect(checkedFront, greaterThan(0));
      expect(checkedBack, greaterThan(0));
    });

    test('the letter O keeps its counter as a hole', () {
      // Two concentric circles; the inner one must become a hole, not a
      // second disc stacked on the first.
      const ring =
          'M 50 5 A 45 45 0 1 0 50 95 A 45 45 0 1 0 50 5 Z '
          'M 50 25 A 25 25 0 1 1 50 75 A 25 25 0 1 1 50 25 Z';
      final result = Extruder.fromSvgPathData(ring);
      expect(result.error, isNull, reason: result.error?.message);

      final mesh = result.mesh!;
      expect(mesh.contourCount, 2);
      expect(mesh.holeCount, 1, reason: 'the counter must be a hole');
    });

    test('reports an explicit error for empty path data', () {
      final result = Extruder.fromSvgPathData('   ');
      expect(result.isSuccess, isFalse);
      expect(result.error!.kind, MedallionErrorKind.emptyPath);
    });

    test('reports an explicit error for a zero-area outline', () {
      // A straight line back and forth: no enclosed area anywhere.
      final result = Extruder.fromSvgPathData('M 0 0 L 10 0 L 20 0 Z');
      expect(result.isSuccess, isFalse);
      expect(result.error!.kind, MedallionErrorKind.degenerateContours);
      expect(result.error!.message, contains('area'));
    });

    test('never returns an empty mesh silently', () {
      for (final bad in <String>[
        '',
        '   ',
        'M 0 0',
        'M 0 0 L 1 1',
        'M 0 0 L 10 0 L 20 0 Z',
      ]) {
        final result = Extruder.fromSvgPathData(bad);
        if (result.isSuccess) {
          expect(result.mesh!.triangleCount, greaterThan(0),
              reason: 'succeeded with no triangles for "$bad"');
        } else {
          expect(result.error!.message, isNotEmpty);
        }
      }
    });

    test('normalizes to the requested radius', () {
      final result = Extruder.fromSvgPathData(
        'M 0 0 L 100 0 L 100 100 L 0 100 Z',
        options: const ExtrudeOptions(radius: 2.0, depth: 0.5),
      );
      final mesh = result.mesh!;

      var maxX = 0.0;
      var maxZ = 0.0;
      for (var v = 0; v < mesh.vertexCount; v++) {
        maxX = maxX > mesh.positions[v * 3].abs()
            ? maxX
            : mesh.positions[v * 3].abs();
        maxZ = maxZ > mesh.positions[v * 3 + 2].abs()
            ? maxZ
            : mesh.positions[v * 3 + 2].abs();
      }
      expect(maxX, closeTo(2.0, 1e-6));
      expect(maxZ, closeTo(0.25, 1e-6));
    });

    test('a symmetric bowtie is reported, not silently emptied', () {
      // The two lobes have equal and opposite signed area, so the outline
      // encloses nothing. It must fail with a reason, never return an
      // empty mesh.
      final result = Extruder.fromSvgPathData(
        'M 0 0 L 10 10 L 10 0 L 0 10 Z',
      );
      expect(result.isSuccess, isFalse);
      expect(result.error!.kind, MedallionErrorKind.degenerateContours);
      expect(result.error!.message, isNotEmpty);
    });

    test('an asymmetric self-intersecting path still yields triangles', () {
      // Lobes of different sizes, so there is net area. Earcut resolves it
      // by curing local intersections or splitting; either way the contract
      // is triangles or an explanation, never silence.
      final result = Extruder.fromSvgPathData(
        'M 0 0 L 30 20 L 30 0 L 0 6 Z',
      );
      if (result.isSuccess) {
        expect(result.mesh!.triangleCount, greaterThan(0));
        for (final i in result.mesh!.indices) {
          expect(i, lessThan(result.mesh!.vertexCount));
        }
      } else {
        expect(result.error!.message, isNotEmpty);
      }
    });
  });

  group('SvgDocument', () {
    test('extracts every path d attribute', () {
      const svg = '''
<svg viewBox="0 0 10 10">
  <path d="M 0 0 L 10 0 L 5 10 Z" fill="#fff"/>
  <path d='M 2 2 L 4 2 L 3 4 Z'/>
</svg>''';
      final doc = SvgDocument.parse(svg);
      expect(doc.pathData, hasLength(2));
      expect(doc.combinedPathData, contains('M 0 0'));
      expect(doc.combinedPathData, contains('M 2 2'));
    });

    test('reports non-path shapes instead of silently skipping them', () {
      const svg = '<svg><circle cx="5" cy="5" r="4"/><rect width="2"/></svg>';
      final doc = SvgDocument.parse(svg);
      expect(doc.pathData, isEmpty);
      expect(doc.skippedShapeTags, containsAll(<String>['circle', 'rect']));
    });
  });
}
