import 'dart:math' as math;

import 'package:path_parsing/path_parsing.dart';

import 'contour.dart';

/// Turns SVG path data into flat closed contours.
///
/// The full `d` grammar is handled by `package:path_parsing`, which normalizes
/// every command -- relative forms, the S/T shorthands, and elliptical arcs --
/// down to `moveTo` / `lineTo` / `cubicTo` / `close`. Only cubic flattening is
/// ours to do.
class SvgFlattener implements PathProxy {
  SvgFlattener({this.tolerance = 0.12});

  /// Maximum deviation, in source units, between a flattened chord and the
  /// true curve. Smaller means more points on the silhouette rim.
  final double tolerance;

  final List<Contour> _contours = <Contour>[];
  List<Vec2> _current = <Vec2>[];
  Vec2 _pen = const Vec2(0, 0);
  Vec2 _subpathStart = const Vec2(0, 0);

  /// Parses [pathData] and returns every closed contour it describes.
  ///
  /// Open subpaths are closed implicitly: an unclosed outline would otherwise
  /// fail tessellation, and a silently missing shape is exactly what section
  /// 3.5 of the brief forbids.
  static List<Contour> flatten(String pathData, {double tolerance = 0.12}) {
    final proxy = SvgFlattener(tolerance: tolerance);
    writeSvgPathDataToPath(pathData, proxy);
    proxy._flushSubpath();
    return proxy._contours;
  }

  @override
  void moveTo(double x, double y) {
    _flushSubpath();
    _pen = Vec2(x, y);
    _subpathStart = _pen;
    _current = <Vec2>[_pen];
  }

  @override
  void lineTo(double x, double y) {
    _pen = Vec2(x, y);
    _appendPoint(_pen);
  }

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    final p0 = _pen;
    final p1 = Vec2(x1, y1);
    final p2 = Vec2(x2, y2);
    final p3 = Vec2(x3, y3);
    // Segment count from the control polygon's length: longer, more curved
    // spans get proportionally more chords for the same chord-height error.
    final polygonLength =
        (p1 - p0).length + (p2 - p1).length + (p3 - p2).length;
    final segments = polygonLength <= 0
        ? 1
        : math.max(
            1,
            math.min(64, math.sqrt(polygonLength / tolerance).ceil()),
          );
    for (var i = 1; i <= segments; i++) {
      final t = i / segments;
      _appendPoint(_evaluateCubic(p0, p1, p2, p3, t));
    }
    _pen = p3;
  }

  @override
  void close() {
    _pen = _subpathStart;
    _flushSubpath();
  }

  static Vec2 _evaluateCubic(Vec2 p0, Vec2 p1, Vec2 p2, Vec2 p3, double t) {
    final u = 1.0 - t;
    final a = u * u * u;
    final b = 3 * u * u * t;
    final c = 3 * u * t * t;
    final d = t * t * t;
    return Vec2(
      a * p0.x + b * p1.x + c * p2.x + d * p3.x,
      a * p0.y + b * p1.y + c * p2.y + d * p3.y,
    );
  }

  void _appendPoint(Vec2 p) {
    if (_current.isEmpty) {
      _current.add(p);
      return;
    }
    // Drop points that land on top of their predecessor; a zero-length edge
    // gives ear clipping a degenerate triangle to reason about.
    final last = _current.last;
    if ((p - last).length > 1e-9) _current.add(p);
  }

  void _flushSubpath() {
    if (_current.length < 3) {
      _current = <Vec2>[];
      return;
    }
    // An explicit `Z` leaves the start point duplicated at the end; closure is
    // implicit in a Contour, so trim it.
    final points = List<Vec2>.of(_current);
    if ((points.first - points.last).length < 1e-9) points.removeLast();
    if (points.length >= 3) _contours.add(Contour(points));
    _current = <Vec2>[];
  }
}

/// Pulls every `d` attribute out of an SVG document, in document order.
///
/// Deliberately minimal: it reads `<path d="...">` and nothing else. Shapes
/// authored as `<circle>`, `<rect>`, or `<polygon>` are not paths and are
/// reported as such rather than silently skipped.
class SvgDocument {
  const SvgDocument._(this.pathData, this.skippedShapeTags);

  final List<String> pathData;

  /// Non-path drawable tags that were seen and ignored, so the caller can say
  /// so instead of rendering a partial shape.
  final List<String> skippedShapeTags;

  static final RegExp _pathTag = RegExp(r'<path\b[^>]*>', dotAll: true);
  static final RegExp _dAttribute = RegExp(
    '''d\\s*=\\s*(?:"([^"]*)"|'([^']*)')''',
    dotAll: true,
  );
  static final RegExp _otherShapes = RegExp(
    r'<(circle|rect|ellipse|polygon|polyline|line|text)\b',
  );

  static SvgDocument parse(String source) {
    final data = <String>[];
    for (final tag in _pathTag.allMatches(source)) {
      final d = _dAttribute.firstMatch(tag.group(0)!);
      if (d == null) continue;
      final value = (d.group(1) ?? d.group(2) ?? '').trim();
      if (value.isNotEmpty) data.add(value);
    }
    final skipped = <String>{
      for (final m in _otherShapes.allMatches(source)) m.group(1)!,
    };
    return SvgDocument._(data, skipped.toList()..sort());
  }

  /// All paths joined into one `d` string, which is how a multi-path glyph
  /// (an outline plus its counters) becomes a single silhouette.
  String get combinedPathData => pathData.join(' ');
}
