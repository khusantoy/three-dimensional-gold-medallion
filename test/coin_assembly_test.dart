// The coin is a stack of slabs, not one extrusion. These checks pin the
// stacking order, the surfaces, and the fact that a decoration failing never
// takes the whole medallion with it.
import 'package:flutter_test/flutter_test.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/coin_assembly.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/coin_design.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/contour.dart';
import 'package:three_dimensional_gold_medallion/src/geometry/svg_flattener.dart';

import 'fixtures/shapes.dart';

List<Contour> artOf(String name) => SvgFlattener.flatten(
  TestShape.all.firstWhere((s) => s.name == name).pathData,
);

void main() {
  group('assembly', () {
    test('a default seal coin stacks body, rim, petals, art and beads', () {
      final assembly = CoinAssembly.build(CoinDesign(artContours: artOf('Heart')));
      expect(assembly.error, isNull, reason: assembly.error?.message);

      final names = assembly.slabs.map((s) => s.name).toList();
      expect(names.first, 'body');
      expect(names, containsAll(<String>['rim-outer', 'rim-inner', 'petals', 'art', 'beads']));
    });

    test('slabs stack front to back in the order they are added', () {
      final assembly = CoinAssembly.build(CoinDesign(artContours: artOf('Star')));
      final byName = <String, double>{
        for (final slab in assembly.slabs) slab.name: slab.centreZ,
      };
      expect(byName['body'], 0);
      expect(byName['petals']!, lessThan(byName['art']!));
      expect(byName['rim-outer']!, lessThan(byName['rim-inner']!));
    });

    test('the body is gold and the art is enamel', () {
      final assembly = CoinAssembly.build(CoinDesign(artContours: artOf('Heart')));
      final body = assembly.slabs.firstWhere((s) => s.name == 'body');
      final art = assembly.slabs.firstWhere((s) => s.name == 'art');
      expect(body.surface, CoinSurface.gold);
      expect(art.surface, CoinSurface.enamel);
    });

    test('every engraving builds and adds its own layers', () {
      for (final engraving in CoinEngraving.values) {
        final assembly = CoinAssembly.build(
          CoinDesign(artContours: artOf('Heart'), engraving: engraving),
        );
        expect(assembly.error, isNull, reason: engraving.name);
        final names = assembly.slabs.map((s) => s.name).toSet();
        switch (engraving) {
          case CoinEngraving.petals:
            expect(names, contains('petals'));
          case CoinEngraving.rays:
            expect(names, containsAll(<String>['field', 'rays']));
          case CoinEngraving.lattice:
            expect(names, containsAll(<String>['field', 'lattice']));
          case CoinEngraving.plain:
            expect(names, isNot(contains('petals')));
        }
      }
    });

    test('every silhouette mints with every sample shape as art', () {
      for (final silhouette in CoinSilhouette.values) {
        for (final shape in TestShape.all) {
          final assembly = CoinAssembly.build(
            CoinDesign(
              artContours: SvgFlattener.flatten(shape.pathData),
              silhouette: silhouette,
            ),
          );
          expect(assembly.error, isNull,
              reason: '${silhouette.name} + ${shape.name}: '
                  '${assembly.error?.message}');
          expect(assembly.triangleCount, greaterThan(0));
        }
      }
    });

    test('a custom silhouette uses the art as the outline and does not '
        'also place it as centre art', () {
      final assembly = CoinAssembly.build(
        CoinDesign(
          artContours: artOf('Ring'),
          silhouette: CoinSilhouette.custom,
        ),
      );
      expect(assembly.error, isNull, reason: assembly.error?.message);
      final names = assembly.slabs.map((s) => s.name).toSet();
      expect(names, contains('body'));
      expect(names, isNot(contains('art')));
      // Rim bands follow the polar radius function, which a custom outline
      // has no meaningful version of, so they are skipped.
      expect(names, isNot(contains('rim-outer')));
    });

    test('a custom silhouette with no art is refused with a reason', () {
      final assembly = CoinAssembly.build(
        const CoinDesign(
          artContours: <Contour>[],
          silhouette: CoinSilhouette.custom,
        ),
      );
      expect(assembly.isSuccess, isFalse);
      expect(assembly.error!.kind, MedallionErrorKind.emptyPath);
    });

    test('every slab mesh is well formed', () {
      final assembly = CoinAssembly.build(
        CoinDesign(artContours: artOf('Letter B'), engraving: CoinEngraving.lattice),
      );
      for (final slab in assembly.slabs) {
        final mesh = slab.mesh;
        expect(mesh.triangleCount, greaterThan(0), reason: slab.name);
        expect(mesh.normals.length, mesh.positions.length, reason: slab.name);
        for (final i in mesh.indices) {
          expect(i, lessThan(mesh.vertexCount), reason: slab.name);
        }
      }
    });

    test('decorations stay at their authored size, not blown up to the coin',
        () {
      // The bug this guards: re-normalizing a decoration to its own bounds
      // would scale a single 0.011-radius bead to fill the whole medallion.
      final assembly = CoinAssembly.build(CoinDesign(artContours: artOf('Heart')));
      final beads = assembly.slabs.firstWhere((s) => s.name == 'beads').mesh;

      var maxAbs = 0.0;
      for (var v = 0; v < beads.vertexCount; v++) {
        final x = beads.positions[v * 3].abs();
        final y = beads.positions[v * 3 + 1].abs();
        if (x > maxAbs) maxAbs = x;
        if (y > maxAbs) maxAbs = y;
      }
      // The bead ring sits at radius(theta) * 0.90, so under half the coin.
      expect(maxAbs, lessThan(0.5));
      expect(maxAbs, greaterThan(0.3));
    });

    test('the art is placed at half the coin width', () {
      final assembly = CoinAssembly.build(CoinDesign(artContours: artOf('Cross')));
      final art = assembly.slabs.firstWhere((s) => s.name == 'art').mesh;

      var minX = double.infinity, maxX = -double.infinity;
      for (var v = 0; v < art.vertexCount; v++) {
        final x = art.positions[v * 3];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
      // artScale 0.50 of a coin of diameter 1.0, and the cross is square.
      expect(maxX - minX, closeTo(CoinMetrics.artScale, 1e-6));
    });
  });
}
