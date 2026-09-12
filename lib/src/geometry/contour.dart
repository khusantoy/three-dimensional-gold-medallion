import 'dart:math' as math;
import 'dart:typed_data';

/// A point in the flat 2D plane the silhouette is authored in.
///
/// Deliberately not `Offset`: Layer A must build without Flutter so it can be
/// exercised by `dart test` with no widget binding and no GPU.
class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);

  double get length => math.sqrt(x * x + y * y);

  /// Unit vector, or (0, 0) when this is degenerate.
  Vec2 get normalized {
    final l = length;
    return l == 0 ? const Vec2(0, 0) : Vec2(x / l, y / l);
  }

  @override
  String toString() =>
      'Vec2(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}

/// A single closed loop of points, already flattened (no curves left).
///
/// The first point is never repeated at the end; closure is implicit.
class Contour {
  Contour(this.points);

  final List<Vec2> points;

  /// Twice the signed area. Positive means counter-clockwise in a Y-up frame.
  double get signedArea2 {
    var sum = 0.0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      sum += a.x * b.y - b.x * a.y;
    }
    return sum;
  }

  double get area => signedArea2.abs() * 0.5;

  bool get isClockwise => signedArea2 < 0;

  /// Winding-independent containment test for a point strictly inside.
  ///
  /// Ray casting to +X. Used to work out which contours are holes inside
  /// which outer shells.
  bool containsPoint(Vec2 p) {
    var inside = false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      final a = points[i];
      final b = points[j];
      if ((a.y > p.y) != (b.y > p.y) &&
          p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
        inside = !inside;
      }
    }
    return inside;
  }

  Contour get reversed => Contour(points.reversed.toList());
}

/// The three faces of an extruded solid, each of which can take its own
/// material.
enum MedallionPart {
  /// The +Z cap, which carries the artwork.
  front,

  /// The -Z cap, the coin's reverse.
  back,

  /// The rim wall joining the two caps.
  side,
}

/// The four surfaces a coin is made of.
///
/// A material *role*, not a material: Layer A names the role, Layer B decides
/// what it looks like. Minted's rule is that the metal -- front face included
/// -- is always one gold, and colour appears only in the enamel cells between
/// the metal, the way a hard-enamel pin works.
enum CoinSurface { gold, orangePeelGold, enamel, engravedGold }

/// Why a given silhouette could not be turned into a solid.
///
/// Section 3.5 of the brief: a shape that fails to tessellate renders as
/// *nothing at all*, so the geometry layer never returns an empty mesh
/// silently. Every failure names the reason.
enum MedallionErrorKind {
  /// The path data parsed to nothing usable.
  emptyPath,

  /// The `d` string could not be parsed at all.
  unparseablePath,

  /// Every contour collapsed below the minimum area.
  degenerateContours,

  /// Ear clipping could not consume the polygon (usually self-intersection).
  triangulationFailed,
}

/// The explicit failure half of [MedallionResult].
class MedallionError {
  const MedallionError(this.kind, this.message);

  final MedallionErrorKind kind;
  final String message;

  @override
  String toString() => 'MedallionError(${kind.name}): $message';
}

/// Either a built mesh or an explanation of why one could not be built.
class MedallionResult {
  const MedallionResult.success(MedallionMesh this.mesh) : error = null;
  const MedallionResult.failure(MedallionError this.error) : mesh = null;

  final MedallionMesh? mesh;
  final MedallionError? error;

  bool get isSuccess => mesh != null;
}

/// A solid split into its separately-materialed faces, or why it failed.
class MedallionPartsResult {
  const MedallionPartsResult.success(Map<MedallionPart, MedallionMesh> this.parts)
      : error = null;
  const MedallionPartsResult.failure(MedallionError this.error) : parts = null;

  final Map<MedallionPart, MedallionMesh>? parts;
  final MedallionError? error;

  bool get isSuccess => parts != null;
}

/// The plain data struct that is the entire boundary between Layer A and
/// Layer B. Nothing here knows that flutter_scene exists.
class MedallionMesh {
  const MedallionMesh({
    required this.positions,
    required this.normals,
    required this.texCoords,
    required this.indices,
    required this.contourCount,
    required this.holeCount,
    required this.sourceBounds,
  });

  /// Three floats per vertex.
  final Float32List positions;

  /// Three floats per vertex, unit length.
  final Float32List normals;

  /// Two floats per vertex.
  final Float32List texCoords;

  /// Triangle list, counter-clockwise when seen from outside.
  final Uint32List indices;

  /// Diagnostics, surfaced in the example page so a failed shape is legible.
  final int contourCount;
  final int holeCount;
  final Rect2 sourceBounds;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;
}

/// Axis-aligned bounds in the source SVG's own coordinate space.
class Rect2 {
  const Rect2(this.minX, this.minY, this.maxX, this.maxY);

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  double get width => maxX - minX;
  double get height => maxY - minY;

  @override
  String toString() =>
      '${width.toStringAsFixed(1)} x ${height.toStringAsFixed(1)}';
}
