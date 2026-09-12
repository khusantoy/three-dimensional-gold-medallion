// Ported from Minted by Haplo LLC (MIT) -- see third_party/minted/LICENSE.
// https://github.com/haplollc/Minted
//
// The decorative geometry below follows `CoinDesign+Paths.swift` and the coin
// proportions in `CoinScene.swift`. The constants are theirs and are kept
// exactly: they are tuned values, not arbitrary ones.

import 'dart:math' as math;

import 'contour.dart';

/// The coin's outline.
///
/// Minted's insight is that the coin body is *not* the artwork. The artwork
/// sits raised in the middle of a struck blank whose outline is one of these.
/// Handing the artwork in as [CoinSilhouette.custom] is the other route.
enum CoinSilhouette {
  /// Gentle eight-lobe wax-seal scallop. Minted's default.
  seal,

  /// Soft-cornered octagon.
  octagon,

  circle,

  /// Rounded diamond (a squircle on point).
  diamond,

  /// An arbitrary outline, supplied separately as contours.
  custom;

  String get label => switch (this) {
    CoinSilhouette.seal => 'Seal',
    CoinSilhouette.octagon => 'Octagon',
    CoinSilhouette.circle => 'Circle',
    CoinSilhouette.diamond => 'Diamond',
    CoinSilhouette.custom => 'Custom (your SVG)',
  };
}

/// The engraved backdrop behind the centre art.
enum CoinEngraving {
  /// Rosette ring sectors, the gold face showing through the gaps. The
  /// signature cloisonne look, and Minted's default.
  petals,

  /// Radiating sunburst wedges over a field disc, like a commemorative medal.
  rays,

  /// A fine grate of crossing bars, enamel showing through the cells.
  lattice,

  /// Bare gold face, letting the art carry the coin.
  plain;

  String get label => switch (this) {
    CoinEngraving.petals => 'Petals',
    CoinEngraving.rays => 'Rays',
    CoinEngraving.lattice => 'Lattice',
    CoinEngraving.plain => 'Plain',
  };
}

/// Coin proportions, in coin-diameter units: the coin is 1.0 wide.
///
/// Taken from `CoinScene.swift`. Every slab is 0.03 deep and is positioned by
/// a `rise` that sits its front proud of the face while its back stays buried
/// inside the body, so nothing pokes out of the coin's reverse.
class CoinMetrics {
  const CoinMetrics._();

  static const double baseDepth = 0.10;
  static const double slabDepth = 0.03;
  static const double artScale = 0.50;
  static const double wireWidth = 0.012;
  static const double fieldRadius = 0.30;
  static const double textRadius = 0.378;
  static const double capHeight = 0.054;

  /// Rim band widths, wider band first, so the lip reads as a rounded roll of
  /// metal. Minted notes that a chamfer cannot be used here: on a polyline
  /// path `SCNShape.chamferRadius` silently yields empty geometry, and the
  /// stacked bands are the fix. Our own extruder has the same constraint for
  /// a different reason -- we have no bevel yet -- so the bands carry over.
  static const double outerBandWidth = 0.052;
  static const double innerBandWidth = 0.030;

  static const double outerBandRise = 0.012;
  static const double innerBandRise = 0.022;

  static const double petalRise = 0.006;
  static const double fieldRise = 0.005;
  static const double patternRise = 0.010;
  static const double artRise = 0.012;
  static const double wireRise = 0.020;
  static const double beadRise = 0.013;

  /// Where a slab's front lands, given its own depth and rise.
  ///
  /// This is `node.position.z = baseDepth / 2 - depth / 2 + rise` from
  /// `CoinScene.shapeNode`.
  static double slabCentreZ(double depth, double rise) =>
      baseDepth / 2 - depth / 2 + rise;
}

/// The decorative geometry, all in the normalized 0..1 y-down square, exactly
/// as Minted authors it. The extruder flips Y and recentres on the way into
/// model space, so these stay in the source convention.
class CoinGeometry {
  const CoinGeometry(this.silhouette);

  final CoinSilhouette silhouette;

  /// Polar radius of the silhouette at an angle, so decorations follow the
  /// coin's actual edge instead of assuming a circle.
  ///
  /// Minted treats a custom outline as roughly round and parks decorations at
  /// a safe radius rather than trying to follow an arbitrary shape.
  double radiusAt(double theta) => switch (silhouette) {
    CoinSilhouette.seal => 0.46 + 0.04 * math.cos(8 * theta),
    CoinSilhouette.octagon => 0.44 + 0.03 * math.cos(8 * theta + math.pi),
    CoinSilhouette.circle => 0.48,
    CoinSilhouette.diamond => _diamondRadius(theta),
    CoinSilhouette.custom => 0.46,
  };

  static double _diamondRadius(double theta) {
    final c = math.cos(theta - math.pi / 4).abs();
    final s = math.sin(theta - math.pi / 4).abs();
    return 0.46 /
        math.pow(math.pow(c, 3.2) + math.pow(s, 3.2), 1 / 3.2).toDouble();
  }

  /// The silhouette outline, sampled the way Minted samples it.
  Contour silhouetteContour({int steps = 240}) {
    final points = <Vec2>[];
    for (var i = 0; i < steps; i++) {
      final theta = i / steps * 2 * math.pi;
      final r = radiusAt(theta);
      points.add(Vec2(0.5 + r * math.cos(theta), 0.5 + r * math.sin(theta)));
    }
    return Contour(points);
  }

  /// A concentric band just inside the silhouette, [width] wide.
  ///
  /// Minted strokes the silhouette path to get this. We have no stroke-to-path
  /// in Dart, but for a polar silhouette the band is exact in polar form:
  /// outer at `radius(theta)`, inner at `radius(theta) - width`. That is also
  /// precisely what Minted's README argues for -- offsetting the original
  /// rather than re-tracing a shrunk mask, which would wander relative to the
  /// first outline and pinch the band to nothing on smooth curves.
  List<Contour> bandContours(double width, {int steps = 240}) {
    final outer = <Vec2>[];
    final inner = <Vec2>[];
    for (var i = 0; i < steps; i++) {
      final theta = i / steps * 2 * math.pi;
      final r = radiusAt(theta);
      final cos = math.cos(theta);
      final sin = math.sin(theta);
      outer.add(Vec2(0.5 + r * cos, 0.5 + r * sin));
      final ri = math.max(r - width, 0.0);
      inner.add(Vec2(0.5 + ri * cos, 0.5 + ri * sin));
    }
    // The inner ring is returned as a separate contour; nesting analysis in
    // the extruder turns it into a hole.
    return <Contour>[Contour(outer), Contour(inner)];
  }

  /// Rosette petals behind the art: ring sectors with the gold face showing
  /// through the gaps, so the backdrop is drawn by the metal as much as by
  /// the enamel.
  List<Contour> petalContours({
    double inner = 0.19,
    double outer = 0.30,
    int count = 10,
    double gap = 0.22,
    int arcSteps = 12,
  }) {
    final contours = <Contour>[];
    for (var i = 0; i < count; i++) {
      final start = (i + gap / 2) / count * 2 * math.pi;
      final end = (i + 1 - gap / 2) / count * 2 * math.pi;
      final points = <Vec2>[
        ..._arc(inner, start, end, arcSteps),
        ..._arc(outer, end, start, arcSteps),
      ];
      contours.add(Contour(points));
    }
    return contours;
  }

  /// The inner disc the art sits on.
  Contour innerDiscContour({
    double radius = CoinMetrics.fieldRadius,
    int steps = 96,
  }) => Contour(_arc(radius, 0, 2 * math.pi, steps, includeEnd: false));

  /// A ring of small minted beads tracing the silhouette, just inside the rim.
  List<Contour> beadContours({
    int count = 44,
    double bead = 0.011,
    int steps = 12,
  }) {
    final contours = <Contour>[];
    for (var i = 0; i < count; i++) {
      final theta = i / count * 2 * math.pi;
      final r = radiusAt(theta) * 0.90;
      final cx = 0.5 + r * math.cos(theta);
      final cy = 0.5 + r * math.sin(theta);
      contours.add(
        Contour(<Vec2>[
          for (var s = 0; s < steps; s++)
            Vec2(
              cx + bead * math.cos(s / steps * 2 * math.pi),
              cy + bead * math.sin(s / steps * 2 * math.pi),
            ),
        ]),
      );
    }
    return contours;
  }

  /// Short sunburst ticks around the field's edge, clear in the middle.
  List<Contour> rayContours({
    double inner = 0.225,
    double outer = 0.292,
    int count = 28,
  }) {
    final contours = <Contour>[];
    for (var i = 0; i < count; i++) {
      final mid = i / count * 2 * math.pi;
      final half = math.pi / count * 0.30;
      contours.add(
        Contour(<Vec2>[
          _polar(inner, mid - half),
          _polar(outer, mid - half),
          _polar(outer, mid + half),
          _polar(inner, mid + half),
        ]),
      );
    }
    return contours;
  }

  /// A fine grate of crossing bars clipped to the inner disc, so enamel shows
  /// through the cells the way it does on a classic enamel pin.
  ///
  /// Minted draws overlapping rectangles and lets Core Graphics' winding rule
  /// merge them. We have no path booleans, so the bars are emitted as separate
  /// contours; where two cross, the overlap is drawn twice at the same depth,
  /// which is invisible on an opaque slab.
  List<Contour> latticeContours({
    double radius = 0.295,
    double bar = 0.005,
    double spacing = 0.082,
  }) {
    final contours = <Contour>[];
    var offset = -radius + spacing;
    while (offset < radius - 0.01) {
      final half = math.sqrt(radius * radius - offset * offset);
      // Vertical bar at x = 0.5 + offset.
      contours.add(
        _rect(0.5 + offset - bar, 0.5 - half, 2 * bar, 2 * half),
      );
      // Horizontal bar at y = 0.5 + offset.
      contours.add(
        _rect(0.5 - half, 0.5 + offset - bar, 2 * half, 2 * bar),
      );
      offset += spacing;
    }
    return contours;
  }

  // --- helpers -----------------------------------------------------------

  static Vec2 _polar(double r, double theta) =>
      Vec2(0.5 + r * math.cos(theta), 0.5 + r * math.sin(theta));

  /// Samples an arc from [start] to [end] at [radius], in whichever direction
  /// the angles imply.
  static List<Vec2> _arc(
    double radius,
    double start,
    double end,
    int steps, {
    bool includeEnd = true,
  }) {
    final last = includeEnd ? steps : steps - 1;
    return <Vec2>[
      for (var i = 0; i <= last; i++)
        _polar(radius, start + (end - start) * (i / steps)),
    ];
  }

  static Contour _rect(double x, double y, double w, double h) => Contour(
    <Vec2>[Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h)],
  );
}

/// Refits contours into the normalized 0..1 y-down square, centred, preserving
/// aspect ratio: the longest side of the bounding box spans exactly 1.
///
/// This is `SVGPath.normalized` / `fitting`. Minted normalizes on the way in
/// so every downstream constant can be written in coin-diameter units.
List<Contour> normalizeContours(List<Contour> contours) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final c in contours) {
    for (final p in c.points) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
  }
  final width = maxX - minX;
  final height = maxY - minY;
  if (width <= 0 && height <= 0) return contours;

  final scale = 1 / math.max(width, height);
  final midX = (minX + maxX) / 2;
  final midY = (minY + maxY) / 2;
  return <Contour>[
    for (final c in contours)
      Contour(<Vec2>[
        for (final p in c.points)
          Vec2(0.5 + (p.x - midX) * scale, 0.5 + (p.y - midY) * scale),
      ]),
  ];
}

/// Places art mid-face at [scale] of the coin's width.
///
/// This is `CoinScene.centered`. The art is fitted by its longest side, so a
/// tall glyph and a wide one occupy the same visual weight.
List<Contour> centreContours(List<Contour> contours, double scale) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final c in contours) {
    for (final p in c.points) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
  }
  final width = maxX - minX;
  final height = maxY - minY;
  if (width <= 0 || height <= 0) return contours;

  final fit = scale / math.max(width, height);
  final midX = (minX + maxX) / 2;
  final midY = (minY + maxY) / 2;
  return <Contour>[
    for (final c in contours)
      Contour(<Vec2>[
        for (final p in c.points)
          Vec2(0.5 + (p.x - midX) * fit, 0.5 + (p.y - midY) * fit),
      ]),
  ];
}
