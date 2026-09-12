// Ported from Minted by Haplo LLC (MIT) -- see third_party/minted/LICENSE.
// https://github.com/haplollc/Minted
//
// `ArtworkAnalyzer.offsetInward`. This is the one piece of polygon offsetting
// the coin needs, and Minted's README says why it has to be an offset at all:
//
//   "The rim band is an offset of the same polygon. Shrinking the mask and
//    tracing it again gives a second outline that wanders relative to the
//    first, pinching the band to nothing on smooth curves."

import 'dart:math' as math;

import 'contour.dart';

/// Moves a closed ring inward by [distance], along each vertex's angle
/// bisector.
///
/// The bisector, not the edge normal: offsetting edges independently leaves
/// gaps at convex corners and crossings at concave ones. A miter clamp keeps
/// a sharp corner from shooting off to infinity, which is the standard
/// failure of bisector offsetting.
///
/// Which sign of the bisector points inward depends on the ring's winding,
/// and the source is Y-down, which flips the usual test. Rather than reason
/// about it, both are computed and the one that actually shrinks the shape
/// wins -- Minted's own approach, and it cannot be fooled by winding.
List<Vec2> offsetInward(List<Vec2> ring, double distance) {
  if (ring.length < 3 || distance <= 0) return ring;

  final a = _offset(ring, distance, 1.0);
  final b = _offset(ring, distance, -1.0);
  return Contour(a).area < Contour(b).area ? a : b;
}

/// The largest a miter may stretch a corner, as a multiple of [distance].
const double _miterLimit = 2.5;

List<Vec2> _offset(List<Vec2> ring, double distance, double sign) {
  final n = ring.length;
  return <Vec2>[
    for (var i = 0; i < n; i++)
      _offsetVertex(
        ring[(i - 1 + n) % n],
        ring[i],
        ring[(i + 1) % n],
        distance,
        sign,
      ),
  ];
}

Vec2 _offsetVertex(
  Vec2 previous,
  Vec2 current,
  Vec2 next,
  double distance,
  double sign,
) {
  final e1 = (current - previous).normalized;
  final e2 = (next - current).normalized;

  // Edge normals, turned the same way as each other.
  final n1 = Vec2(e1.y * sign, -e1.x * sign);
  final n2 = Vec2(e2.y * sign, -e2.x * sign);

  var bx = n1.x + n2.x;
  var by = n1.y + n2.y;
  var length = math.sqrt(bx * bx + by * by);

  // A straight-through vertex has opposing normals that cancel; fall back to
  // one of them rather than dividing by zero.
  if (length < 1e-6) {
    bx = n1.x;
    by = n1.y;
    length = 1.0;
  }

  // The sharper the corner, the shorter the bisector, and the further the
  // miter has to reach to keep the offset edges at the right distance.
  final miter = math.min(_miterLimit, 1.0 / math.max(0.4, length / 2));
  return Vec2(
    current.x + bx / length * distance * miter,
    current.y + by / length * distance * miter,
  );
}

/// The band between a ring and its inward offset, as contours ready to
/// extrude: the original, then the inset as a hole.
///
/// Returns null when the inset collapses -- on a shape narrower than twice
/// the band width there is no band to draw, and an inverted ring would
/// tessellate into garbage.
List<Contour>? bandInside(List<Vec2> ring, double width) {
  if (ring.length < 3 || width <= 0) return null;

  final outer = Contour(ring);
  final inner = Contour(offsetInward(ring, width));

  // A collapsed or inverted inset has lost area faster than a real offset
  // can; there is nothing sensible to extrude.
  if (inner.area < outer.area * 0.05) return null;
  if (inner.area >= outer.area) return null;

  return <Contour>[outer, inner];
}
