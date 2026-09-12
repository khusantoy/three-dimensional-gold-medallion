// The triangulation below is a Dart implementation of the earcut algorithm,
// following the structure of mapbox/earcut (ISC licensed). Its license is
// vendored at third_party/earcut/LICENSE.
//
//   https://github.com/mapbox/earcut

import 'contour.dart';

/// A node in the doubly-linked polygon ring that ear clipping consumes.
class _Node {
  _Node(this.i, this.x, this.y);

  /// Index into the caller's flat vertex list.
  final int i;
  final double x;
  final double y;

  late _Node prev;
  late _Node next;

  /// Set when this node has been clipped out of the ring.
  bool removed = false;
}

/// Ear-clipping polygon triangulation with hole support.
///
/// `flutter_scene`'s `ExtrudeGeometry` caps with `addFanCap`, whose doc states
/// "End caps assume a convex profile" -- a fan over a heart, a star, or any
/// letter produces garbage. Coin silhouettes are almost never convex, so the
/// triangulation is ours.
///
/// The shape is the classic earcut: holes are spliced into the outer ring by a
/// bridge edge, then the single ring is clipped ear by ear. Self-intersection
/// is handled the same way earcut handles it -- first by curing local
/// intersections, then by splitting the polygon at a visible diagonal -- and
/// if both fail the caller is told, rather than handed a partial mesh.
class Earcut {
  /// Triangulates [outer] with [holes] cut out of it.
  ///
  /// Vertices are addressed by index into a flat list laid out as
  /// `outer + holes[0] + holes[1] + ...`, which is exactly how
  /// [flatten] arranges them.
  ///
  /// Returns triangle indices wound counter-clockwise, or null when the
  /// polygon could not be consumed.
  static List<int>? triangulate(List<Vec2> outer, List<List<Vec2>> holes) {
    if (outer.length < 3) return null;

    var outerNode = _buildRing(outer, 0, counterClockwise: true);
    if (outerNode == null) return null;

    var offset = outer.length;
    final holeRings = <_Node>[];
    for (final hole in holes) {
      if (hole.length < 3) {
        offset += hole.length;
        continue;
      }
      // Holes wind opposite to the shell so the spliced ring stays simple.
      final ring = _buildRing(hole, offset, counterClockwise: false);
      if (ring != null) holeRings.add(ring);
      offset += hole.length;
    }

    if (holeRings.isNotEmpty) {
      outerNode = _eliminateHoles(outerNode, holeRings);
      if (outerNode == null) return null;
    }

    final triangles = <int>[];
    final ok = _earcutLinked(outerNode, triangles, 0);
    if (!ok || triangles.isEmpty) return null;
    return triangles;
  }

  /// Lays [outer] and [holes] out as one flat vertex list, matching the
  /// indices [triangulate] returns.
  static List<Vec2> flatten(List<Vec2> outer, List<List<Vec2>> holes) => <Vec2>[
    ...outer,
    for (final hole in holes) ...hole,
  ];

  // --- ring construction -------------------------------------------------

  static _Node? _buildRing(
    List<Vec2> points,
    int indexOffset, {
    required bool counterClockwise,
  }) {
    final isCcw = Contour(points).signedArea2 > 0;
    _Node? last;
    if (isCcw == counterClockwise) {
      for (var i = 0; i < points.length; i++) {
        last = _insert(indexOffset + i, points[i], last);
      }
    } else {
      for (var i = points.length - 1; i >= 0; i--) {
        last = _insert(indexOffset + i, points[i], last);
      }
    }
    if (last == null) return null;
    // A ring whose first and last points coincide would give a zero-length
    // edge that never forms a valid ear.
    if (_equals(last, last.next)) {
      _remove(last);
      last = last.next;
    }
    return _filterPoints(last, null);
  }

  static _Node _insert(int i, Vec2 p, _Node? last) {
    final node = _Node(i, p.x, p.y);
    if (last == null) {
      node.prev = node;
      node.next = node;
    } else {
      node.next = last.next;
      node.prev = last;
      last.next.prev = node;
      last.next = node;
    }
    return node;
  }

  static void _remove(_Node node) {
    node.next.prev = node.prev;
    node.prev.next = node.next;
    node.removed = true;
  }

  /// Drops collinear and duplicate points, which are the usual source of
  /// zero-area ears that stall the clip.
  static _Node? _filterPoints(_Node? start, _Node? end) {
    if (start == null) return null;
    final stop = end ?? start;
    var node = start;
    bool again;
    do {
      again = false;
      if (_equals(node, node.next) ||
          _area(node.prev, node, node.next) == 0) {
        _remove(node);
        node = node.prev;
        if (identical(node, node.next)) return null;
        again = true;
      } else {
        node = node.next;
      }
    } while (again || !identical(node, stop));
    return node;
  }

  // --- the clip ----------------------------------------------------------

  static bool _earcutLinked(_Node? ear, List<int> triangles, int pass) {
    var node = ear;
    if (node == null) return true;

    var stop = node;
    while (!identical(node!.prev, node.next)) {
      final prev = node.prev;
      final next = node.next;

      if (_isEar(node)) {
        triangles..add(prev.i)..add(node.i)..add(next.i);
        _remove(node);
        // Skip the next vertex too: it cannot have become an ear by the
        // removal of its neighbour's neighbour.
        node = next.next;
        stop = next.next;
        continue;
      }

      node = next;

      if (identical(node, stop)) {
        // A full lap with no ear found means the ring is not simple.
        // Three escalating recoveries, cheapest first.
        switch (pass) {
          case 0:
            // Collinear or duplicate points can mask every ear.
            final filtered = _filterPoints(node, null);
            if (filtered == null) return true;
            return _earcutLinked(filtered, triangles, 1);
          case 1:
            // Clip off crossing edge pairs to recover a simple ring.
            final filtered = _filterPoints(node, null);
            if (filtered == null) return true;
            return _earcutLinked(
              _cureLocalIntersections(filtered, triangles),
              triangles,
              2,
            );
          case 2:
            // Cut the ring in two along an interior diagonal.
            return _splitEarcut(node, triangles);
          default:
            return false;
        }
      }
    }
    return true;
  }

  static bool _isEar(_Node ear) {
    final a = ear.prev;
    final b = ear;
    final c = ear.next;

    // A reflex corner is never an ear.
    if (_area(a, b, c) >= 0) return false;

    var node = c.next;
    while (!identical(node, a)) {
      if (_pointInTriangle(a, b, c, node) &&
          _area(node.prev, node, node.next) >= 0) {
        return false;
      }
      node = node.next;
    }
    return true;
  }

  /// Clips off pairs of edges that cross, which turns a mildly
  /// self-intersecting ring back into a simple one.
  static _Node _cureLocalIntersections(_Node start, List<int> triangles) {
    var node = start;
    do {
      final a = node.prev;
      final b = node.next.next;
      if (!_equals(a, b) &&
          _intersects(a, node, node.next, b) &&
          _locallyInside(a, b) &&
          _locallyInside(b, a)) {
        triangles..add(a.i)..add(node.i)..add(b.i);
        _remove(node);
        _remove(node.next);
        node = b;
        start = b;
      }
      node = node.next;
    } while (!identical(node, start));
    return _filterPoints(node, null) ?? node;
  }

  /// Last resort: cut the ring in two along a diagonal that stays inside it,
  /// then clip each half.
  static bool _splitEarcut(_Node start, List<int> triangles) {
    var a = start;
    do {
      var b = a.next.next;
      while (!identical(b, a.prev)) {
        if (a.i != b.i && _isValidDiagonal(a, b)) {
          var c = _splitPolygon(a, b);
          final left = _filterPoints(a, a.next);
          final right = _filterPoints(c, c.next);
          return _earcutLinked(left, triangles, 0) &&
              _earcutLinked(right, triangles, 0);
        }
        b = b.next;
      }
      a = a.next;
    } while (!identical(a, start));
    return false;
  }

  // --- hole elimination --------------------------------------------------

  static _Node? _eliminateHoles(_Node outerNode, List<_Node> holes) {
    // Rightmost-first, so each bridge is cast into a ring that still contains
    // every hole to its left.
    final queue = holes.map(_leftmost).toList()
      ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));

    var outer = outerNode;
    for (final hole in queue) {
      final bridge = _findHoleBridge(hole, outer);
      if (bridge == null) return null;
      final spliced = _splitPolygon(bridge, hole);
      // Collinear points around both sides of the cut are dropped, and the
      // ring is re-entered at the bridge: `outer` may itself have just been
      // filtered away.
      _filterPoints(spliced, spliced.next);
      outer = _filterPoints(bridge, bridge.next) ?? bridge;
    }
    return outer;
  }

  static _Node _leftmost(_Node start) {
    var node = start;
    var best = start;
    do {
      if (node.x < best.x || (node.x == best.x && node.y < best.y)) {
        best = node;
      }
      node = node.next;
    } while (!identical(node, start));
    return best;
  }

  /// Finds a point on the outer ring that the hole's leftmost point can see,
  /// by casting a ray to -X and then walking candidates in the resulting
  /// sector.
  static _Node? _findHoleBridge(_Node hole, _Node outerNode) {
    var node = outerNode;
    final hx = hole.x;
    final hy = hole.y;
    var qx = -double.infinity;
    _Node? bridge;

    do {
      final next = node.next;
      if (hy <= node.y && hy >= next.y && next.y != node.y) {
        final x =
            node.x + (hy - node.y) * (next.x - node.x) / (next.y - node.y);
        if (x <= hx && x > qx) {
          qx = x;
          bridge = node.x < next.x ? node : next;
          if (x == hx) return bridge; // The hole touches the shell exactly.
        }
      }
      node = next;
    } while (!identical(node, outerNode));

    if (bridge == null) return null;

    // Among vertices inside the ray's sector, take the one with the smallest
    // angle to the ray, breaking ties toward the ring's interior.
    final stop = bridge;
    final mx = bridge.x;
    final my = bridge.y;
    var tanMin = double.infinity;
    node = bridge;

    do {
      if (hx >= node.x &&
          node.x >= mx &&
          hx != node.x &&
          _pointInTriangleRaw(
            hy < my ? hx : qx, hy,
            mx, my,
            hy < my ? qx : hx, hy,
            node.x, node.y,
          )) {
        final tan = (hy - node.y).abs() / (hx - node.x);
        if (_locallyInside(node, hole) &&
            (tan < tanMin ||
                (tan == tanMin &&
                    (node.x > bridge!.x ||
                        (node.x == bridge.x &&
                            _sectorContainsSector(bridge, node)))))) {
          bridge = node;
          tanMin = tan;
        }
      }
      node = node.next;
    } while (!identical(node, stop));

    return bridge;
  }

  static bool _sectorContainsSector(_Node m, _Node p) =>
      _area(m.prev, m, p.prev) < 0 && _area(p.next, m, m.next) < 0;

  /// Links [a] and [b] with a bridge, splitting one ring into two (or, when
  /// they are on different rings, joining two into one).
  static _Node _splitPolygon(_Node a, _Node b) {
    final a2 = _Node(a.i, a.x, a.y);
    final b2 = _Node(b.i, b.x, b.y);
    final an = a.next;
    final bp = b.prev;

    a.next = b;
    b.prev = a;

    a2.next = an;
    an.prev = a2;

    b2.next = a2;
    a2.prev = b2;

    bp.next = b2;
    b2.prev = bp;

    return b2;
  }

  // --- predicates --------------------------------------------------------

  /// Twice the signed area of the triangle; negative is counter-clockwise
  /// under this module's convention.
  static double _area(_Node p, _Node q, _Node r) =>
      (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);

  static bool _equals(_Node a, _Node b) => a.x == b.x && a.y == b.y;

  static bool _pointInTriangle(_Node a, _Node b, _Node c, _Node p) =>
      _pointInTriangleRaw(a.x, a.y, b.x, b.y, c.x, c.y, p.x, p.y);

  static bool _pointInTriangleRaw(
    double ax, double ay,
    double bx, double by,
    double cx, double cy,
    double px, double py,
  ) =>
      (cx - px) * (ay - py) >= (ax - px) * (cy - py) &&
      (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
      (bx - px) * (cy - py) >= (cx - px) * (by - py);

  static bool _isValidDiagonal(_Node a, _Node b) =>
      a.next.i != b.i &&
      a.prev.i != b.i &&
      !_intersectsPolygon(a, b) &&
      ((_locallyInside(a, b) &&
              _locallyInside(b, a) &&
              _middleInside(a, b)) &&
          (_area(a.prev, a, b.prev) != 0 || _area(a, b.prev, b) != 0));

  static bool _intersects(_Node p1, _Node q1, _Node p2, _Node q2) {
    final o1 = _sign(_area(p1, q1, p2));
    final o2 = _sign(_area(p1, q1, q2));
    final o3 = _sign(_area(p2, q2, p1));
    final o4 = _sign(_area(p2, q2, q1));
    if (o1 != o2 && o3 != o4) return true;
    if (o1 == 0 && _onSegment(p1, p2, q1)) return true;
    if (o2 == 0 && _onSegment(p1, q2, q1)) return true;
    if (o3 == 0 && _onSegment(p2, p1, q2)) return true;
    if (o4 == 0 && _onSegment(p2, q1, q2)) return true;
    return false;
  }

  static bool _intersectsPolygon(_Node a, _Node b) {
    var node = a;
    do {
      if (node.i != a.i &&
          node.next.i != a.i &&
          node.i != b.i &&
          node.next.i != b.i &&
          _intersects(node, node.next, a, b)) {
        return true;
      }
      node = node.next;
    } while (!identical(node, a));
    return false;
  }

  static bool _locallyInside(_Node a, _Node b) => _area(a.prev, a, a.next) < 0
      ? _area(a, b, a.next) >= 0 && _area(a, a.prev, b) >= 0
      : _area(a, b, a.prev) < 0 || _area(a, a.next, b) < 0;

  static bool _middleInside(_Node a, _Node b) {
    var node = a;
    var inside = false;
    final px = (a.x + b.x) / 2;
    final py = (a.y + b.y) / 2;
    do {
      if (((node.y > py) != (node.next.y > py)) &&
          node.next.y != node.y &&
          px <
              (node.next.x - node.x) *
                      (py - node.y) /
                      (node.next.y - node.y) +
                  node.x) {
        inside = !inside;
      }
      node = node.next;
    } while (!identical(node, a));
    return inside;
  }

  static int _sign(double v) => v > 0 ? 1 : (v < 0 ? -1 : 0);

  static bool _onSegment(_Node p, _Node q, _Node r) =>
      q.x <= (p.x > r.x ? p.x : r.x) &&
      q.x >= (p.x < r.x ? p.x : r.x) &&
      q.y <= (p.y > r.y ? p.y : r.y) &&
      q.y >= (p.y < r.y ? p.y : r.y);
}
