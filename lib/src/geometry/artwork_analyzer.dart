// Ported from Minted by Haplo LLC (MIT) -- see third_party/minted/LICENSE.
// https://github.com/haplollc/Minted
//
// This is the relief half of `ArtworkAnalyzer.swift`: finding the gold painted
// into a pin's artwork, and turning it into the maps that make that gold stand
// proud of the face instead of lying flat on it.
//
// Minted's own summary of why it matters: "Gold becomes relief, not print. The
// detected gold is baked into a normal map, so painted frames and filigree
// stand proud and catch light like metal."
//
// Pure Dart: no Flutter, no GPU. It takes RGBA bytes and returns RGBA bytes,
// which is what lets it run on a background isolate.

import 'dart:math' as math;
import 'dart:typed_data';

/// The maps baked from one pin's artwork.
class ArtworkRelief {
  const ArtworkRelief({
    required this.normalMap,
    required this.metallicRoughnessMap,
    required this.side,
    required this.goldPixelCount,
  });

  /// Tangent-space normals, RGBA8. Feed as [TextureContent.normal].
  final Uint8List normalMap;

  /// glTF packing: B is metallic, G is roughness. Feed as
  /// [TextureContent.data] -- passing it as colour would gamma-decode linear
  /// data and read too smooth at distance.
  final Uint8List metallicRoughnessMap;

  final int side;

  /// How much of the artwork was read as gold, for diagnostics.
  final int goldPixelCount;

  double get goldFraction => goldPixelCount / (side * side);
}

/// Finds the gold in a pin's artwork and bakes it into relief.
class ArtworkAnalyzer {
  const ArtworkAnalyzer._();

  /// How hard the baked relief pushes. Minted's `strength` in `normalMap`.
  static const double reliefStrength = 2.4;

  /// Roughness written into the map's green channel where the art is gold.
  /// Metal reads wrong at the face's matte 0.55.
  static const double goldRoughness = 0.30;

  /// Roughness everywhere else: Minted's `faceMaterial.roughness = 0.55`.
  static const double baseRoughness = 0.55;

  /// Bakes the normal and metallic-roughness maps for one square RGBA image.
  ///
  /// [pixels] is RGBA8, [side] pixels square.
  static ArtworkRelief analyze(Uint8List pixels, int side) {
    final gold = _goldMask(pixels, side);
    final normalMap = _normalMap(gold, side);
    final metallicRoughness = _metallicRoughnessMap(gold, side);

    var count = 0;
    for (final isGold in gold) {
      if (isGold) count++;
    }

    return ArtworkRelief(
      normalMap: normalMap,
      metallicRoughnessMap: metallicRoughness,
      side: side,
      goldPixelCount: count,
    );
  }

  /// Gold in the artwork: warm, and either glossy or blown out.
  ///
  /// The warmth test alone also catches skin, sand, and terracotta. What
  /// separates painted metal from those is that metal has *local* contrast --
  /// it carries a highlight and a shadow within a few pixels -- or is simply
  /// blown out. Hence the second pass against a blurred copy of the luminance.
  static List<bool> _goldMask(Uint8List pixels, int side) {
    final count = side * side;
    final mask = List<bool>.filled(count, false);
    final luminance = Float32List(count);

    for (var i = 0; i < count; i++) {
      final r = pixels[i * 4].toDouble();
      final g = pixels[i * 4 + 1].toDouble();
      final b = pixels[i * 4 + 2].toDouble();
      final a = pixels[i * 4 + 3];
      luminance[i] = 0.299 * r + 0.587 * g + 0.114 * b;
      // Transparent pixels are outside the pin; they have no gold on them.
      mask[i] = a > 127 &&
          r > b + 28 &&
          g > b * 0.82 &&
          g > r * 0.52 &&
          r > 120;
    }

    final blurred = boxBlur(luminance, side, 4);
    for (var i = 0; i < count; i++) {
      final local = (luminance[i] - blurred[i]).abs();
      mask[i] = mask[i] && (local > 9 || luminance[i] > 225);
    }
    return closed(mask, side, side, 2);
  }

  /// Height-field to tangent-space normals, by central difference.
  ///
  /// The mask is blurred first so the relief has shoulders: a hard 0/1 step
  /// differentiates to a one-pixel spike that reads as an outline, not as a
  /// raised edge catching light.
  static Uint8List _normalMap(List<bool> mask, int side) {
    final height = boxBlur(
      Float32List.fromList(<double>[for (final m in mask) m ? 1.0 : 0.0]),
      side,
      2,
    );

    final out = Uint8List(side * side * 4);
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final i = y * side + x;
        final left = height[y * side + math.max(x - 1, 0)];
        final right = height[y * side + math.min(x + 1, side - 1)];
        final up = height[math.max(y - 1, 0) * side + x];
        final down = height[math.min(y + 1, side - 1) * side + x];

        var nx = -(right - left) / 2 * reliefStrength;
        var ny = -(down - up) / 2 * reliefStrength;
        var nz = 1.0;
        final length = math.max(math.sqrt(nx * nx + ny * ny + nz * nz), 1e-6);
        nx /= length;
        ny /= length;
        nz /= length;

        out[i * 4] = ((nx * 0.5 + 0.5) * 255).round().clamp(0, 255);
        out[i * 4 + 1] = ((ny * 0.5 + 0.5) * 255).round().clamp(0, 255);
        out[i * 4 + 2] = ((nz * 0.5 + 0.5) * 255).round().clamp(0, 255);
        out[i * 4 + 3] = 255;
      }
    }
    return out;
  }

  /// The glTF metallic-roughness packing: B metallic, G roughness.
  ///
  /// Minted feeds SceneKit a bare grayscale metalness map and a scalar
  /// roughness. glTF has one texture for both, so the roughness rides along in
  /// green -- and gold gets a lower roughness than the painted face, because
  /// metal that is as matte as enamel does not read as metal.
  static Uint8List _metallicRoughnessMap(List<bool> mask, int side) {
    final out = Uint8List(side * side * 4);
    final goldValue = (goldRoughness * 255).round();
    final baseValue = (baseRoughness * 255).round();

    for (var i = 0; i < mask.length; i++) {
      final isGold = mask[i];
      out[i * 4] = 0;
      out[i * 4 + 1] = isGold ? goldValue : baseValue;
      out[i * 4 + 2] = isGold ? 255 : 0;
      out[i * 4 + 3] = 255;
    }
    return out;
  }

  // --- pixel helpers -----------------------------------------------------

  /// Separable box blur, clamped at the edges.
  static Float32List boxBlur(Float32List values, int side, int radius) {
    final temporary = Float32List(values.length);
    final out = Float32List(values.length);

    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        var total = 0.0;
        var samples = 0;
        for (var offset = -radius; offset <= radius; offset++) {
          final sx = x + offset;
          if (sx < 0 || sx >= side) continue;
          total += values[y * side + sx];
          samples++;
        }
        temporary[y * side + x] = total / math.max(samples, 1);
      }
    }
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        var total = 0.0;
        var samples = 0;
        for (var offset = -radius; offset <= radius; offset++) {
          final sy = y + offset;
          if (sy < 0 || sy >= side) continue;
          total += temporary[sy * side + x];
          samples++;
        }
        out[y * side + x] = total / math.max(samples, 1);
      }
    }
    return out;
  }

  /// Four-neighbour dilation, [radius] times.
  static List<bool> dilated(List<bool> mask, int width, int height, int radius) {
    if (radius <= 0) return mask;
    var out = List<bool>.of(mask);
    for (var pass = 0; pass < radius; pass++) {
      final next = List<bool>.of(out);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = y * width + x;
          if (out[i]) continue;
          if ((x > 0 && out[i - 1]) ||
              (x < width - 1 && out[i + 1]) ||
              (y > 0 && out[i - width]) ||
              (y < height - 1 && out[i + width])) {
            next[i] = true;
          }
        }
      }
      out = next;
    }
    return out;
  }

  /// Four-neighbour erosion, [radius] times. The border counts as empty, so a
  /// mask touching the edge erodes inward from it.
  static List<bool> eroded(List<bool> mask, int width, int height, int radius) {
    if (radius <= 0) return mask;
    var out = List<bool>.of(mask);
    for (var pass = 0; pass < radius; pass++) {
      final next = List<bool>.of(out);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = y * width + x;
          if (!out[i]) continue;
          if (x == 0 ||
              x == width - 1 ||
              y == 0 ||
              y == height - 1 ||
              !out[i - 1] ||
              !out[i + 1] ||
              !out[i - width] ||
              !out[i + width]) {
            next[i] = false;
          }
        }
      }
      out = next;
    }
    return out;
  }

  /// Dilate then erode: bridges pinholes without growing the shape.
  static List<bool> closed(List<bool> mask, int width, int height, int radius) =>
      eroded(dilated(mask, width, height, radius), width, height, radius);

  /// Erode then dilate: drops specks and hair-thin spires.
  static List<bool> opened(List<bool> mask, int width, int height, int radius) =>
      dilated(eroded(mask, width, height, radius), width, height, radius);
}
