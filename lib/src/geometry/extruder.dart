import 'dart:math' as math;
import 'dart:typed_data';

import 'contour.dart';
import 'earcut.dart';
import 'svg_flattener.dart';

/// How the silhouette is turned into a solid.
class ExtrudeOptions {
  const ExtrudeOptions({
    this.depth = 0.16,
    this.radius = 1.0,
    this.curveTolerance = 0.12,
    this.smoothingAngle = 0.6,
    this.minContourArea = 1e-6,
  });

  /// Total thickness of the coin, front face to back face.
  final double depth;

  /// The silhouette is scaled so its longest side spans `2 * radius`.
  final double radius;

  /// Flattening error for curves, in source units.
  final double curveTolerance;

  /// Rim normals are averaged across corners sharper than this (radians).
  /// Below it the corner is left hard, so a star keeps its edges while a
  /// circle keeps a continuous sweep of reflection.
  final double smoothingAngle;

  /// Contours with less area than this (after normalization) are dropped as
  /// numerical dust rather than being fed to the triangulator.
  final double minContourArea;
}

/// One outer shell with the holes that belong to it.
class _Region {
  _Region(this.outer);

  final Contour outer;
  final List<Contour> holes = <Contour>[];
}

/// Silhouette to solid.
///
/// Front cap at `+z`, back cap at `-z`, and a rim wall joining them along
/// every contour. Front faces wind counter-clockwise in model space, which is
/// what flutter_scene expects (clockwise geometry is invisible from outside
/// and shows only its inside -- silent failure trap #13).
class Extruder {
  /// Builds a solid from SVG path data.
  static MedallionResult fromSvgPathData(
    String pathData, {
    ExtrudeOptions options = const ExtrudeOptions(),
  }) {
    if (pathData.trim().isEmpty) {
      return const MedallionResult.failure(
        MedallionError(MedallionErrorKind.emptyPath, 'The path data is empty.'),
      );
    }

    List<Contour> contours;
    try {
      contours = SvgFlattener.flatten(
        pathData,
        tolerance: options.curveTolerance,
      );
    } on Object catch (e) {
      return MedallionResult.failure(
        MedallionError(
          MedallionErrorKind.unparseablePath,
          'The path data could not be parsed: $e',
        ),
      );
    }

    if (contours.isEmpty) {
      return const MedallionResult.failure(
        MedallionError(
          MedallionErrorKind.emptyPath,
          'No closed contour was found. A medallion needs at least one '
          'closed outline; open strokes and zero-width lines have no area '
          'to extrude.',
        ),
      );
    }

    return fromContours(contours, options: options);
  }

  /// Builds a solid from already-flattened contours, in SVG coordinates
  /// (Y pointing down).
  static MedallionResult fromContours(
    List<Contour> contours, {
    ExtrudeOptions options = const ExtrudeOptions(),
  }) {
    final bounds = _boundsOf(contours);
    if (bounds.width <= 0 && bounds.height <= 0) {
      return const MedallionResult.failure(
        MedallionError(
          MedallionErrorKind.degenerateContours,
          'Every contour collapsed to a point.',
        ),
      );
    }

    // SVG is Y-down and origin-top-left; the scene is Y-up and origin-centre.
    // Flipping Y also flips every contour's handedness, which is why winding
    // is fixed up afterwards rather than trusted from the source.
    final longestSide = math.max(bounds.width, bounds.height);
    final scale = longestSide == 0 ? 1.0 : (options.radius * 2) / longestSide;
    final cx = (bounds.minX + bounds.maxX) / 2;
    final cy = (bounds.minY + bounds.maxY) / 2;

    final normalized = _mapToModelSpace(
      contours,
      (p) => Vec2((p.x - cx) * scale, -(p.y - cy) * scale),
      options.minContourArea,
    );

    if (normalized.isEmpty) {
      return MedallionResult.failure(
        MedallionError(
          MedallionErrorKind.degenerateContours,
          'All ${contours.length} contour(s) had an area below '
          '${options.minContourArea}. Hair-thin spires and zero-width '
          'strokes have no surface to extrude.',
        ),
      );
    }

    return _assemble(
      normalized,
      bounds,
      depth: options.depth,
      radius: options.radius,
      smoothingAngle: options.smoothingAngle,
    );
  }

  /// Extrudes a silhouette and hands back its three faces separately.
  ///
  /// Use this when the front needs a different material from the rim and the
  /// reverse -- artwork on the face, metal everywhere else.
  static MedallionPartsResult partsFromContoursInPlace(
    List<Contour> contours, {
    required double depth,
    double radius = 0.5,
    double smoothingAngle = 0.6,
  }) {
    final side = radius * 2;
    final placed = _mapToModelSpace(
      contours,
      (p) => Vec2((p.x - 0.5) * side, -(p.y - 0.5) * side),
      1e-9,
    );
    if (placed.isEmpty) {
      return const MedallionPartsResult.failure(
        MedallionError(
          MedallionErrorKind.degenerateContours,
          'Every contour collapsed below the minimum area.',
        ),
      );
    }
    return _assembleParts(
      placed,
      _boundsOf(contours),
      depth: depth,
      radius: radius,
      smoothingAngle: smoothingAngle,
    );
  }

  /// Caps, walls, and winding, shared by both entry points.
  static MedallionResult _assemble(
    List<Contour> placed,
    Rect2 sourceBounds, {
    required double depth,
    required double radius,
    required double smoothingAngle,
  }) {
    final builder = _MeshBuilder();
    final outcome = _fill(
      builder,
      placed,
      depth: depth,
      radius: radius,
      smoothingAngle: smoothingAngle,
    );
    if (outcome.error != null) return MedallionResult.failure(outcome.error!);

    return MedallionResult.success(
      builder.build(
        contourCount: placed.length,
        holeCount: outcome.holeCount,
        sourceBounds: sourceBounds,
      ),
    );
  }

  /// Triangulates every region into [builder]. The one place caps, walls and
  /// winding are decided, so the whole-solid and split-parts paths cannot
  /// drift apart.
  static ({MedallionError? error, int holeCount}) _fill(
    _MeshBuilder builder,
    List<Contour> placed, {
    required double depth,
    required double radius,
    required double smoothingAngle,
  }) {
    final regions = _groupIntoRegions(placed);
    final half = depth / 2;
    var holeCount = 0;

    for (final region in regions) {
      holeCount += region.holes.length;

      // Caps. The outer ring is forced counter-clockwise and holes clockwise
      // so the triangulator sees a consistent orientation regardless of how
      // the artwork was authored.
      final outer = region.outer.isClockwise
          ? region.outer.reversed
          : region.outer;
      final holes = <Contour>[
        for (final h in region.holes) h.isClockwise ? h : h.reversed,
      ];

      final flat = Earcut.flatten(
        outer.points,
        holes.map((h) => h.points).toList(),
      );
      final triangles = Earcut.triangulate(
        outer.points,
        holes.map((h) => h.points).toList(),
      );

      if (triangles == null) {
        return (
          error: MedallionError(
            MedallionErrorKind.triangulationFailed,
            'Ear clipping could not consume a contour of ${flat.length} '
            'points with ${holes.length} hole(s). The outline is most likely '
            'self-intersecting, which has no well-defined inside to fill.',
          ),
          holeCount: holeCount,
        );
      }

      builder.addCaps(flat, triangles, half, radius);

      // Rim walls, one per ring. Both use the same outward rule because the
      // outer ring is counter-clockwise and holes are clockwise, so "to the
      // right of the edge" is away from the solid in both cases.
      builder.addWall(outer.points, half, smoothingAngle);
      for (final hole in holes) {
        builder.addWall(hole.points, half, smoothingAngle);
      }
    }

    if (builder.isEmpty) {
      return (
        error: const MedallionError(
          MedallionErrorKind.triangulationFailed,
          'The silhouette produced no triangles.',
        ),
        holeCount: holeCount,
      );
    }
    return (error: null, holeCount: holeCount);
  }

  /// Extrudes contours that are already in the normalized 0..1 y-down square,
  /// without refitting them to their own bounds.
  ///
  /// This is the difference between a silhouette and a decoration. A
  /// silhouette owns the frame and is scaled to fill it. A bead, a petal, or
  /// a lattice bar is *positioned* in a frame it shares with everything else
  /// on the coin; re-normalizing one to its own bounding box would blow a
  /// single bead up to the size of the whole medallion.
  ///
  /// The mapping is Minted's `CoinScene.shapeNode` transform: the unit square
  /// becomes a centred, Y-up square of side `2 * radius`.
  static MedallionResult fromContoursInPlace(
    List<Contour> contours, {
    required double depth,
    double radius = 0.5,
    double smoothingAngle = 0.6,
    double minContourArea = 1e-9,
  }) {
    if (contours.isEmpty) {
      return const MedallionResult.failure(
        MedallionError(MedallionErrorKind.emptyPath, 'No contours supplied.'),
      );
    }
    final side = radius * 2;
    final placed = _mapToModelSpace(
      contours,
      (p) => Vec2((p.x - 0.5) * side, -(p.y - 0.5) * side),
      minContourArea,
    );
    if (placed.isEmpty) {
      return const MedallionResult.failure(
        MedallionError(
          MedallionErrorKind.degenerateContours,
          'Every contour collapsed below the minimum area.',
        ),
      );
    }
    return _assemble(
      placed,
      _boundsOf(contours),
      depth: depth,
      radius: radius,
      smoothingAngle: smoothingAngle,
    );
  }

  static List<Contour> _mapToModelSpace(
    List<Contour> contours,
    Vec2 Function(Vec2) transform,
    double minArea,
  ) {
    final mapped = <Contour>[];
    for (final contour in contours) {
      final candidate = Contour(<Vec2>[
        for (final p in contour.points) transform(p),
      ]);
      if (candidate.area >= minArea) mapped.add(candidate);
    }
    return mapped;
  }

  static MedallionPartsResult _assembleParts(
    List<Contour> placed,
    Rect2 sourceBounds, {
    required double depth,
    required double radius,
    required double smoothingAngle,
  }) {
    final builder = _MeshBuilder();
    final outcome = _fill(
      builder,
      placed,
      depth: depth,
      radius: radius,
      smoothingAngle: smoothingAngle,
    );
    if (outcome.error != null) {
      return MedallionPartsResult.failure(outcome.error!);
    }
    return MedallionPartsResult.success(
      builder.buildParts(
        contourCount: placed.length,
        holeCount: outcome.holeCount,
        sourceBounds: sourceBounds,
      ),
    );
  }

  static Rect2 _boundsOf(List<Contour> contours) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final c in contours) {
      for (final p in c.points) {
        if (p.x < minX) minX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x;
        if (p.y > maxY) maxY = p.y;
      }
    }
    if (minX > maxX) return const Rect2(0, 0, 0, 0);
    return Rect2(minX, minY, maxX, maxY);
  }

  /// Works out which contours are holes in which shells by nesting depth.
  ///
  /// A contour enclosed by an even number of others is solid; an odd number
  /// makes it a hole. That is the even-odd fill rule, and it is what makes
  /// the letter "O" a ring and the letter "B" two holes, without trusting
  /// the source's winding.
  static List<_Region> _groupIntoRegions(List<Contour> contours) {
    final depths = List<int>.filled(contours.length, 0);
    final parents = List<int>.filled(contours.length, -1);

    for (var i = 0; i < contours.length; i++) {
      final probe = _interiorProbe(contours[i]);
      var smallestEnclosingArea = double.infinity;
      for (var j = 0; j < contours.length; j++) {
        if (i == j) continue;
        if (!contours[j].containsPoint(probe)) continue;
        depths[i]++;
        // The immediate parent is the smallest contour that still encloses it.
        if (contours[j].area < smallestEnclosingArea) {
          smallestEnclosingArea = contours[j].area;
          parents[i] = j;
        }
      }
    }

    final regions = <int, _Region>{};
    for (var i = 0; i < contours.length; i++) {
      if (depths[i].isEven) regions[i] = _Region(contours[i]);
    }
    for (var i = 0; i < contours.length; i++) {
      if (depths[i].isEven) continue;
      final parent = parents[i];
      // A hole whose parent is itself a hole belongs to no shell we drew.
      final region = regions[parent];
      if (region != null) region.holes.add(contours[i]);
    }
    return regions.values.toList();
  }

  /// A point that is inside the contour, used for the nesting test.
  ///
  /// The centroid of an L-shape or a crescent can fall outside it, so the
  /// midpoint of a short diagonal is tried until one lands inside.
  static Vec2 _interiorProbe(Contour contour) {
    final pts = contour.points;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 2) % pts.length];
      final mid = Vec2((a.x + b.x) / 2, (a.y + b.y) / 2);
      if (contour.containsPoint(mid)) return mid;
    }
    // Degenerate fallback: the average of the vertices.
    var sx = 0.0;
    var sy = 0.0;
    for (final p in pts) {
      sx += p.x;
      sy += p.y;
    }
    return Vec2(sx / pts.length, sy / pts.length);
  }
}

/// Accumulates interleaved-free attribute arrays.
class _MeshBuilder {
  final List<double> _positions = <double>[];
  final List<double> _normals = <double>[];
  final List<double> _texCoords = <double>[];
  final List<int> _indices = <int>[];

  /// Which part each triangle belongs to, parallel to `_indices / 3`.
  final List<MedallionPart> _triangleParts = <MedallionPart>[];

  bool get isEmpty => _indices.isEmpty;

  int get _vertexCount => _positions.length ~/ 3;

  int _addVertex(
    double x, double y, double z,
    double nx, double ny, double nz,
    double u, double v,
  ) {
    _positions..add(x)..add(y)..add(z);
    _normals..add(nx)..add(ny)..add(nz);
    _texCoords..add(u)..add(v);
    return _vertexCount - 1;
  }

  /// Emits the front cap (normal +Z) and the back cap (normal -Z) from one
  /// triangulation, reversing the winding on the back so both face outward.
  void addCaps(
    List<Vec2> flat,
    List<int> triangles,
    double half,
    double radius,
  ) {
    final uvScale = radius == 0 ? 1.0 : 1 / (radius * 2);
    final frontBase = _vertexCount;
    for (final p in flat) {
      _addVertex(
        p.x, p.y, half,
        0, 0, 1,
        p.x * uvScale + 0.5, 0.5 - p.y * uvScale,
      );
    }
    final backBase = _vertexCount;
    for (final p in flat) {
      _addVertex(
        p.x, p.y, -half,
        0, 0, -1,
        0.5 - p.x * uvScale, 0.5 - p.y * uvScale,
      );
    }

    // The triangulator works in the XY plane with Y up, so its output already
    // winds counter-clockwise seen from +Z: correct for the front cap as-is,
    // reversed for the back.
    for (var i = 0; i < triangles.length; i += 3) {
      final a = triangles[i];
      final b = triangles[i + 1];
      final c = triangles[i + 2];
      _indices
        ..add(frontBase + a)
        ..add(frontBase + b)
        ..add(frontBase + c)
        ..add(backBase + c)
        ..add(backBase + b)
        ..add(backBase + a);
      _triangleParts..add(MedallionPart.front)..add(MedallionPart.back);
    }
  }

  /// Emits the rim wall along one closed ring.
  ///
  /// The outward direction is "to the right of the edge", which points away
  /// from the solid for a counter-clockwise shell and into the void for a
  /// clockwise hole.
  void addWall(List<Vec2> points, double half, double smoothingAngle) {
    final n = points.length;
    if (n < 3) return;

    // Outward normal of each edge i -> i+1.
    final edgeNormals = List<Vec2>.generate(n, (i) {
      final d = points[(i + 1) % n] - points[i];
      return Vec2(d.y, -d.x).normalized;
    });

    final edgeLengths = List<double>.generate(
      n,
      (i) => (points[(i + 1) % n] - points[i]).length,
    );
    final perimeter = edgeLengths.fold<double>(0, (a, b) => a + b);
    final cosLimit = math.cos(smoothingAngle);

    // Per-vertex normals, split at corners sharper than the smoothing angle
    // so a star stays crisp and a circle stays continuous.
    final incoming = List<Vec2>.filled(n, const Vec2(0, 0));
    final outgoing = List<Vec2>.filled(n, const Vec2(0, 0));
    for (var i = 0; i < n; i++) {
      final nIn = edgeNormals[(i - 1 + n) % n];
      final nOut = edgeNormals[i];
      final dot = nIn.x * nOut.x + nIn.y * nOut.y;
      if (dot >= cosLimit) {
        final averaged = (nIn + nOut).normalized;
        final safe = averaged.length == 0 ? nOut : averaged;
        incoming[i] = safe;
        outgoing[i] = safe;
      } else {
        incoming[i] = nIn;
        outgoing[i] = nOut;
      }
    }

    var travelled = 0.0;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      if (edgeLengths[i] <= 0) continue;

      final a = points[i];
      final b = points[j];
      final na = outgoing[i];
      final nb = incoming[j];

      final u0 = perimeter == 0 ? 0.0 : travelled / perimeter;
      travelled += edgeLengths[i];
      final u1 = perimeter == 0 ? 1.0 : travelled / perimeter;

      final fa = _addVertex(a.x, a.y, half, na.x, na.y, 0, u0, 1);
      final ba = _addVertex(a.x, a.y, -half, na.x, na.y, 0, u0, 0);
      final bb = _addVertex(b.x, b.y, -half, nb.x, nb.y, 0, u1, 0);
      final fb = _addVertex(b.x, b.y, half, nb.x, nb.y, 0, u1, 1);

      _indices
        ..add(fa)..add(ba)..add(bb)
        ..add(fa)..add(bb)..add(fb);
      _triangleParts..add(MedallionPart.side)..add(MedallionPart.side);
    }
  }

  /// Splits the solid into its front cap, back cap, and rim wall.
  ///
  /// SceneKit's `SCNShape` hands out five material slots -- front, back, side,
  /// and two chamfers -- which is how Minted paints artwork onto a coin's face
  /// while keeping its rim and reverse real metal. We have no chamfers, so
  /// there are three.
  Map<MedallionPart, MedallionMesh> buildParts({
    required int contourCount,
    required int holeCount,
    required Rect2 sourceBounds,
  }) {
    final result = <MedallionPart, MedallionMesh>{};

    for (final part in MedallionPart.values) {
      // Indices are global to the whole solid, so a part's vertices have to be
      // gathered and renumbered or they would point outside its own arrays.
      final remap = <int, int>{};
      final positions = <double>[];
      final normals = <double>[];
      final texCoords = <double>[];
      final indices = <int>[];

      for (var t = 0; t < _triangleParts.length; t++) {
        if (_triangleParts[t] != part) continue;
        for (var k = 0; k < 3; k++) {
          final original = _indices[t * 3 + k];
          final mapped = remap.putIfAbsent(original, () {
            positions
              ..add(_positions[original * 3])
              ..add(_positions[original * 3 + 1])
              ..add(_positions[original * 3 + 2]);
            normals
              ..add(_normals[original * 3])
              ..add(_normals[original * 3 + 1])
              ..add(_normals[original * 3 + 2]);
            texCoords
              ..add(_texCoords[original * 2])
              ..add(_texCoords[original * 2 + 1]);
            return positions.length ~/ 3 - 1;
          });
          indices.add(mapped);
        }
      }

      if (indices.isEmpty) continue;
      result[part] = MedallionMesh(
        positions: Float32List.fromList(positions),
        normals: Float32List.fromList(normals),
        texCoords: Float32List.fromList(texCoords),
        indices: Uint32List.fromList(indices),
        contourCount: contourCount,
        holeCount: holeCount,
        sourceBounds: sourceBounds,
      );
    }
    return result;
  }

  MedallionMesh build({
    required int contourCount,
    required int holeCount,
    required Rect2 sourceBounds,
  }) {
    return MedallionMesh(
      positions: Float32List.fromList(_positions),
      normals: Float32List.fromList(_normals),
      texCoords: Float32List.fromList(_texCoords),
      indices: Uint32List.fromList(_indices),
      contourCount: contourCount,
      holeCount: holeCount,
      sourceBounds: sourceBounds,
    );
  }
}
