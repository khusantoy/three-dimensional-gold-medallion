// Every generated pin must survive the full geometry path. A traced outline
// that fails to tessellate renders as nothing at all, and there is no way to
// see that without a device, so it is caught here.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/contour.dart';
import 'package:three_dimensional_gold_medallion/src/pins/pin_outlines.g.dart';
import 'package:three_dimensional_gold_medallion/src/pins/pin_view.dart';

void main() {
  test('the collection is not empty', () {
    expect(kPinOutlines, isNotEmpty);
  });

  group('every pin', () {
    for (final pin in kPinOutlines) {
      group(pin.slug, () {
        test('has its artwork on disk, under the size budget', () {
          final file = File(pin.assetPath);
          expect(file.existsSync(), isTrue, reason: '${pin.assetPath} missing');
          expect(
            file.lengthSync(),
            lessThanOrEqualTo(100 * 1024),
            reason: '${pin.assetPath} is over 100 KB',
          );
        });

        test('extrudes into a face, a reverse and a rim', () {
          final geometry = PinGeometry.build(pin.pathData);
          expect(geometry, isNotNull, reason: 'outline failed to tessellate');

          final parts = geometry!.parts;
          expect(parts.keys, containsAll(MedallionPart.values));
          for (final entry in parts.entries) {
            final mesh = entry.value;
            expect(mesh.triangleCount, greaterThan(0), reason: entry.key.name);
            expect(mesh.normals.length, mesh.positions.length);
            for (final i in mesh.indices) {
              expect(i, lessThan(mesh.vertexCount), reason: entry.key.name);
            }
          }
        });

        test('keeps the artwork square in the frame the texture samples', () {
          // The outline is normalised by the image frame, not its own bounding
          // box. If that ever changes, the art slides out from under the
          // silhouette, so the extent is pinned here.
          final geometry = PinGeometry.build(pin.pathData)!;
          final front = geometry.parts[MedallionPart.front]!;

          var maxAbs = 0.0;
          for (var v = 0; v < front.vertexCount; v++) {
            final x = front.positions[v * 3].abs();
            final y = front.positions[v * 3 + 1].abs();
            if (x > maxAbs) maxAbs = x;
            if (y > maxAbs) maxAbs = y;
          }
          // The coin spans [-0.5, 0.5]; a traced pin touches at least one edge.
          expect(maxAbs, lessThanOrEqualTo(0.5 + 1e-6));
          expect(maxAbs, greaterThan(0.45));
        });

        test('face UVs cover the texture without spilling past it', () {
          final geometry = PinGeometry.build(pin.pathData)!;
          final front = geometry.parts[MedallionPart.front]!;

          var minU = double.infinity, maxU = -double.infinity;
          var minV = double.infinity, maxV = -double.infinity;
          for (var v = 0; v < front.vertexCount; v++) {
            final u = front.texCoords[v * 2];
            final w = front.texCoords[v * 2 + 1];
            if (u < minU) minU = u;
            if (u > maxU) maxU = u;
            if (w < minV) minV = w;
            if (w > maxV) maxV = w;
          }
          // UVs must stay inside the image: anything past it samples the
          // clamped edge and smears a pixel row down the face.
          expect(minU, greaterThanOrEqualTo(-1e-6));
          expect(maxU, lessThanOrEqualTo(1 + 1e-6));
          expect(minV, greaterThanOrEqualTo(-1e-6));
          expect(maxV, lessThanOrEqualTo(1 + 1e-6));

          // Only the *longer* axis is expected to fill the frame. A tall
          // narrow pin (the television tower is an arch) genuinely occupies
          // half the width, and squeezing its art out to the edges is the
          // exact bug Minted warns about: texture coordinates follow the pin,
          // not its bounding box.
          final longest = math.max(maxU - minU, maxV - minV);
          expect(longest, greaterThan(0.9));
        });

        test('the face and the reverse point opposite ways', () {
          final geometry = PinGeometry.build(pin.pathData)!;
          final front = geometry.parts[MedallionPart.front]!;
          final back = geometry.parts[MedallionPart.back]!;

          for (var v = 0; v < front.vertexCount; v++) {
            expect(front.normals[v * 3 + 2], closeTo(1.0, 1e-6));
          }
          for (var v = 0; v < back.vertexCount; v++) {
            expect(back.normals[v * 3 + 2], closeTo(-1.0, 1e-6));
          }
        });
      });
    }
  });

  group('the rim band', () {
    test('is built for every pin in the collection', () {
      // Two of these outlines are concave enough that the widest band
      // self-intersects when offset; the width backs off until it does not.
      for (final pin in kPinOutlines) {
        final geometry = PinGeometry.build(pin.pathData)!;
        expect(geometry.rimBand, isNotNull,
            reason: '${pin.slug} carries no rim band');
        expect(geometry.rimBand!.holeCount, 1,
            reason: '${pin.slug}: the band is solid, not a ring');
      }
    });

    test('a pin with no usable band still builds, just without one', () {
      // The band is decoration: losing it must not lose the pin. A sliver
      // too narrow for even the smallest width exercises the fallback.
      final sliver = PinGeometry.build(
        'M0.40 0.02 L0.60 0.02 L0.60 0.98 L0.40 0.98 Z',
      );
      expect(sliver, isNotNull, reason: 'the pin itself failed to build');
      expect(sliver!.parts.keys, containsAll(MedallionPart.values));
    });

    test('stands proud of the face without breaking the reverse', () {
      const halfBody = PinMetrics.thickness / 2;
      final front = PinMetrics.rimBandCentreZ + PinMetrics.rimBandDepth / 2;
      final back = PinMetrics.rimBandCentreZ - PinMetrics.rimBandDepth / 2;

      expect(front, greaterThan(halfBody), reason: 'the band is not raised');
      expect(front - halfBody, closeTo(PinMetrics.rimBandRise, 1e-9));
      expect(back, greaterThan(-halfBody),
          reason: 'the band pokes out the back of the pin');
    });

    test('hugs the outline rather than floating inside it', () {
      final pin = kPinOutlines.first;
      final geometry = PinGeometry.build(pin.pathData)!;
      final band = geometry.rimBand!;
      final front = geometry.parts[MedallionPart.front]!;

      double extentOf(MedallionMesh mesh) {
        var maxAbs = 0.0;
        for (var v = 0; v < mesh.vertexCount; v++) {
          final x = mesh.positions[v * 3].abs();
          final y = mesh.positions[v * 3 + 1].abs();
          if (x > maxAbs) maxAbs = x;
          if (y > maxAbs) maxAbs = y;
        }
        return maxAbs;
      }

      // The band's outer edge is the silhouette itself.
      expect(extentOf(band), closeTo(extentOf(front), 1e-6));
    });
  });

  test('the pin is thin, the way a real pin is', () {
    final geometry = PinGeometry.build(kPinOutlines.first.pathData)!;
    final side = geometry.parts[MedallionPart.side]!;

    var minZ = double.infinity, maxZ = -double.infinity;
    for (var v = 0; v < side.vertexCount; v++) {
      final z = side.positions[v * 3 + 2];
      if (z < minZ) minZ = z;
      if (z > maxZ) maxZ = z;
    }
    expect(maxZ - minZ, closeTo(PinMetrics.thickness, 1e-6));
  });
}
