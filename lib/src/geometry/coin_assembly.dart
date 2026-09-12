// Ported from Minted by Haplo LLC (MIT) -- see third_party/minted/LICENSE.
// https://github.com/haplollc/Minted
//
// This is `CoinScene.makeScene`'s geometry half: the order the slabs stack in,
// the depth each one gets, and the rise that sits its front proud of the face
// while its back stays buried in the body.

import 'coin_design.dart';
import 'contour.dart';
import 'extruder.dart';

/// One extruded slab of the coin, with where it sits and what it is made of.
class CoinSlab {
  const CoinSlab({
    required this.name,
    required this.mesh,
    required this.surface,
    required this.centreZ,
  });

  final String name;
  final MedallionMesh mesh;
  final CoinSurface surface;

  /// Model-space Z of the slab's centre. The extruder builds each slab
  /// centred on the origin, so the renderer only has to translate.
  final double centreZ;
}

/// Everything needed to mint one coin.
///
/// Minted's `CoinDesign`. The artwork is the *centre art* by default and the
/// coin body is a struck blank; passing [CoinSilhouette.custom] makes the
/// artwork the coin's own outline instead.
class CoinDesign {
  const CoinDesign({
    required this.artContours,
    this.silhouette = CoinSilhouette.seal,
    this.engraving = CoinEngraving.petals,
    this.showBeads = true,
    this.showRim = true,
  });

  /// The centre art, in whatever coordinate space; it is normalized on the
  /// way in.
  final List<Contour> artContours;

  final CoinSilhouette silhouette;
  final CoinEngraving engraving;
  final bool showBeads;
  final bool showRim;
}

/// The assembled coin, or the reason it could not be assembled.
class CoinAssembly {
  const CoinAssembly._(this.slabs, this.error);

  final List<CoinSlab> slabs;
  final MedallionError? error;

  bool get isSuccess => error == null;

  int get triangleCount =>
      slabs.fold(0, (sum, slab) => sum + slab.mesh.triangleCount);

  int get vertexCount =>
      slabs.fold(0, (sum, slab) => sum + slab.mesh.vertexCount);

  /// Builds the slab stack.
  ///
  /// The order is Minted's, back to front: body, rim bands, engraving
  /// backdrop, art enamel, gold wire, beads. Each slab is 0.03 deep except
  /// the body, which is 0.10.
  static CoinAssembly build(CoinDesign design) {
    final geometry = CoinGeometry(design.silhouette);
    final slabs = <CoinSlab>[];

    // The silhouette. A custom outline is the artwork itself, refitted to the
    // normalized square; otherwise it comes from the polar radius function.
    final List<Contour> silhouette;
    if (design.silhouette == CoinSilhouette.custom) {
      if (design.artContours.isEmpty) {
        return const CoinAssembly._(<CoinSlab>[], MedallionError(
          MedallionErrorKind.emptyPath,
          'A custom silhouette needs artwork to take its outline from.',
        ));
      }
      silhouette = normalizeContours(design.artContours);
    } else {
      silhouette = <Contour>[geometry.silhouetteContour()];
    }

    // 1. The coin body: solid gold, orange-peel on the reverse. Our extruder
    //    emits one mesh for the whole solid rather than SceneKit's five
    //    material slots, so the reverse is not separately shaded yet.
    final body = _extrude(silhouette, CoinMetrics.baseDepth);
    if (body.error != null) {
      return CoinAssembly._(const <CoinSlab>[], body.error);
    }
    slabs.add(CoinSlab(
      name: 'body',
      mesh: body.mesh!,
      surface: CoinSurface.gold,
      centreZ: 0,
    ));

    // 2. The rim: two stacked gold bands, wider then narrower, so the lip
    //    reads as a rounded roll of metal. Minted notes a chamfer cannot be
    //    used on a polyline path -- it silently yields empty geometry -- and
    //    the stacked bands are the fix.
    if (design.showRim && design.silhouette != CoinSilhouette.custom) {
      _add(slabs, 'rim-outer',
          geometry.bandContours(CoinMetrics.outerBandWidth),
          CoinSurface.gold, CoinMetrics.outerBandRise);
      _add(slabs, 'rim-inner',
          geometry.bandContours(CoinMetrics.innerBandWidth),
          CoinSurface.gold, CoinMetrics.innerBandRise);
    }

    // 3. The engraved backdrop behind the art.
    switch (design.engraving) {
      case CoinEngraving.petals:
        _add(slabs, 'petals', geometry.petalContours(),
            CoinSurface.enamel, CoinMetrics.petalRise);
      case CoinEngraving.rays:
        _add(slabs, 'field', <Contour>[geometry.innerDiscContour()],
            CoinSurface.enamel, CoinMetrics.fieldRise);
        _add(slabs, 'rays', geometry.rayContours(),
            CoinSurface.gold, CoinMetrics.patternRise);
      case CoinEngraving.lattice:
        _add(slabs, 'field', <Contour>[geometry.innerDiscContour()],
            CoinSurface.enamel, CoinMetrics.fieldRise);
        _add(slabs, 'lattice', geometry.latticeContours(),
            CoinSurface.gold, CoinMetrics.patternRise);
      case CoinEngraving.plain:
        break; // bare gold face, letting the art carry the coin
    }

    // 4. The art as enamel, placed mid-face at half the coin's width.
    //    A custom silhouette already *is* the art, so it is not repeated.
    if (design.silhouette != CoinSilhouette.custom &&
        design.artContours.isNotEmpty) {
      final placed = centreContours(
        normalizeContours(design.artContours),
        CoinMetrics.artScale,
      );
      _add(slabs, 'art', placed, CoinSurface.enamel, CoinMetrics.artRise);
    }

    // 5. Minted beads inside the rim.
    if (design.showBeads) {
      _add(slabs, 'beads', geometry.beadContours(),
          CoinSurface.gold, CoinMetrics.beadRise);
    }

    return CoinAssembly._(slabs, null);
  }

  static MedallionResult _extrude(List<Contour> contours, double depth) =>
      Extruder.fromContours(
        contours,
        options: ExtrudeOptions(depth: depth, radius: 0.5),
      );

  /// Extrudes one decorative layer and stacks it.
  ///
  /// A decoration that fails to tessellate is dropped rather than sinking the
  /// whole coin: unlike the body, losing the beads is not losing the medallion.
  static void _add(
    List<CoinSlab> slabs,
    String name,
    List<Contour> contours,
    CoinSurface surface,
    double rise,
  ) {
    if (contours.isEmpty) return;
    // Decorations are authored in the same normalized square as the
    // silhouette, so they must not be re-normalized to their own bounds --
    // that would blow a bead up to coin size. They are extruded in place.
    final result = Extruder.fromContoursInPlace(
      contours,
      depth: CoinMetrics.slabDepth,
      radius: 0.5,
    );
    if (result.mesh == null) return;
    slabs.add(CoinSlab(
      name: name,
      mesh: result.mesh!,
      surface: surface,
      centreZ: CoinMetrics.slabCentreZ(CoinMetrics.slabDepth, rise),
    ));
  }
}
