// Ported from Minted by Haplo LLC (MIT) -- see third_party/minted/LICENSE.
// https://github.com/haplollc/Minted
//
// The artwork route, from `ArtworkCoin.makeScene`: the pin art becomes the
// coin's face, and its rim and reverse stay real metal.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../geometry/artwork_analyzer.dart';
import '../geometry/contour.dart';
import '../geometry/extruder.dart';
import '../geometry/offset.dart';
import '../geometry/svg_flattener.dart';
import '../render/gold_material.dart';
import 'pin_outlines.g.dart';

/// Proportions for an artwork pin, from `ArtworkCoin`.
class PinMetrics {
  const PinMetrics._();

  /// "Pins are thin." Body thickness in coin-diameter units.
  static const double thickness = 0.055;

  /// The artwork face is already a lit render, so the environment is turned
  /// down from the vector route's 1.5.
  static const double environmentIntensity = 0.85;

  /// `faceMaterial.roughness.contents = 0.55`.
  static const double faceRoughness = 0.55;

  /// `faceMaterial.normal.intensity = 0.55`. How far the baked relief is
  /// allowed to tilt the face's normals.
  static const double reliefIntensity = 0.55;

  /// Rim band widths to try, widest first.
  ///
  /// Minted measures this per pin and clamps to 0.018...0.030. We try a
  /// preferred width and back off, because offsetting a ring along its angle
  /// bisectors makes the boundary cross itself where the shape is more
  /// concave than the offset is wide -- and a self-intersecting ring has no
  /// well-defined inside, so it fails to tessellate and would render as
  /// nothing at all.
  ///
  /// Backing off until it works is the same escalating-retreat idiom Minted
  /// uses for outline smoothing: "the radius backs off until it stops eating
  /// real art."
  static const List<double> rimBandWidths = <double>[0.024, 0.018, 0.013, 0.009];

  /// How far the band's front sits proud of the face. `ArtworkCoin` uses
  /// `0.005 + index * 0.006`, and there is one band.
  static const double rimBandRise = 0.005;

  static const double rimBandDepth = 0.03;

  /// `node.position.z = thickness / 2 - depth / 2 + rise`.
  static double get rimBandCentreZ =>
      thickness / 2 - rimBandDepth / 2 + rimBandRise;
}

/// One pin's geometry, built once and reused across rebuilds.
class PinGeometry {
  const PinGeometry(this.parts, this.rimBand);

  final Map<MedallionPart, MedallionMesh> parts;

  /// A raised gold band hugging the outline, or null when the pin is too
  /// narrow to carry one.
  final MedallionMesh? rimBand;

  int get triangleCount =>
      parts.values.fold(0, (sum, mesh) => sum + mesh.triangleCount) +
      (rimBand?.triangleCount ?? 0);

  /// Extrudes a traced outline into a face, a reverse, and a rim.
  ///
  /// The outline is already normalised into the same 0..1 square the texture
  /// is sampled from, so it goes in unscaled: re-fitting it here would slide
  /// the artwork out from under its own silhouette.
  static PinGeometry? build(String pathData) {
    final contours = SvgFlattener.flatten(pathData, tolerance: 0.004);
    if (contours.isEmpty) return null;

    final result = Extruder.partsFromContoursInPlace(
      contours,
      depth: PinMetrics.thickness,
      radius: 0.5,
    );
    if (result.parts == null) return null;

    // A real band of metal standing on the face, following the outline. The
    // artwork paints its own border, but a painted border is flat: this is
    // what catches a moving highlight along the edge.
    final outline = _longestContour(contours);
    final band = outline == null ? null : _buildRimBand(outline);

    return PinGeometry(result.parts!, band);
  }

  /// The widest rim band this outline can actually carry.
  ///
  /// Returns null when even the narrowest fails; the pin is then simply
  /// rendered without one, which is a band missing rather than a pin missing.
  static MedallionMesh? _buildRimBand(Contour outline) {
    for (final width in PinMetrics.rimBandWidths) {
      final ring = bandInside(outline.points, width);
      if (ring == null) continue;
      final mesh = Extruder.fromContoursInPlace(
        ring,
        depth: PinMetrics.rimBandDepth,
        radius: 0.5,
      ).mesh;
      if (mesh != null) return mesh;
    }
    return null;
  }

  /// The silhouette proper, when a trace produced more than one loop.
  static Contour? _longestContour(List<Contour> contours) {
    Contour? best;
    for (final contour in contours) {
      if (best == null || contour.area > best.area) best = contour;
    }
    return best;
  }
}

/// A landmark pin, alive: idles in a slow spin, drag to turn, flick to send.
class PinView extends StatefulWidget {
  const PinView({
    super.key,
    required this.pin,
    required this.geometry,
    this.goldSrgb = CoinPalette.roseGoldSrgb,
    this.showBackdrop = true,
  });

  final PinOutline pin;
  final PinGeometry geometry;
  final List<double> goldSrgb;
  final bool showBackdrop;

  @override
  State<PinView> createState() => _PinViewState();
}

class _PinViewState extends State<PinView> {
  final Scene _scene = Scene();

  Node? _coin;
  Node? _cameraNode;
  final List<Node> _partNodes = <Node>[];

  EnvironmentMap? _environment;
  Texture2D? _faceTexture;
  Texture2D? _reliefTexture;
  Texture2D? _metallicRoughnessTexture;

  /// How much of the artwork was read as painted gold, for the caller.
  double goldFraction = 0.0;

  bool _ready = false;
  String? _failure;

  /// Rotation about the pin's own vertical axis. Unbounded: it spins.
  double _yaw = 0.0;

  /// Tip toward or away from the viewer. Clamped, so the pin never rolls past
  /// edge-on and leaves the viewer with no idea which way is up.
  double _pitch = 0.0;

  double _yawVelocity = 0.0;
  double _pitchVelocity = 0.0;
  bool _dragging = false;

  /// The camera is rebuilt when the view's aspect ratio changes, so a
  /// rotation or a resize cannot crop the pin.
  double _aspect = 1.0;

  static const double _idleRate = 2 * math.pi / CoinRig.idlePeriodSeconds;

  /// Just under a quarter turn each way.
  static const double _pitchLimit = math.pi / 2 * 0.94;

  /// Radians per logical pixel of drag. Minted's value, applied to both axes.
  static const double _dragSensitivity = 0.012;

  @override
  void initState() {
    super.initState();
    _yawVelocity = _idleRate;
    _boot();
  }

  Future<void> _boot() async {
    try {
      await Scene.initializeStaticResources();
      if (!mounted) return;

      _buildRig();

      _environment = EnvironmentMap.studio();
      _scene.environment = _environment;
      _scene.environmentIntensity = PinMetrics.environmentIntensity;

      await _loadFace();
      _buildPin();

      if (mounted) setState(() => _ready = true);
    } on Object catch (e, stack) {
      debugPrint('PinView failed to initialize: $e\n$stack');
      if (mounted) setState(() => _failure = '$e');
    }
  }

  void _buildRig() {
    // A slight fixed tilt gives the pin depth even in still renders; the child
    // spins so the tilt never wobbles.
    final tilt = Node(name: 'tilt')
      ..localTransform = vm.Matrix4.rotationX(CoinRig.tiltRadians);
    _scene.add(tilt);

    final coin = Node(name: 'pin');
    tilt.add(coin);
    _coin = coin;

    final camera = Node(name: 'camera')
      ..addComponent(
        CameraComponent(
          projection: PerspectiveProjection(
            fovRadiansY: CoinRig.fieldOfViewDegrees * vm.degrees2Radians,
            near: 0.1,
          ),
          activateOnMount: true,
        ),
      );
    _scene.add(camera);
    _cameraNode = camera;
    _placeCamera();

    for (final light in CoinRig.lights()) {
      final node = Node(name: 'light-${light.name}')
        ..addComponent(
          DirectionalLightComponent.aimed(light.toLight(), light.direction),
        );
      if (light.ridesCamera) {
        _cameraNode!.add(node);
      } else {
        _scene.add(node);
      }
    }
  }

  /// Puts the camera far enough back that the pin fits the current view.
  ///
  /// A NodeCamera looks along its node's +Z; SceneKit's looks along -Z. Aim it
  /// explicitly rather than translating and hoping.
  void _placeCamera() {
    _cameraNode?.lookAtFrom(
      vm.Vector3(0, 0, CoinRig.distanceFor(_aspect)),
      vm.Vector3.zero(),
    );
  }

  /// The pin's pose, rebuilt from scratch each time.
  ///
  /// Yaw is applied first so it stays the pin's own spin, then pitch tips that
  /// spinning pin toward the viewer. Assigning a fresh matrix matters:
  /// mutating the one a getter returns never moves the node, and throws in
  /// debug.
  void _applyPose() {
    _coin?.localTransform =
        vm.Matrix4.rotationX(_pitch) * vm.Matrix4.rotationY(_yaw);
  }

  /// Loads the artwork and bakes its relief.
  ///
  /// Three maps come off one image: the artwork itself as base colour, a
  /// normal map so the gold painted into it stands proud, and a
  /// metallic-roughness map so that same gold shades as metal rather than as
  /// paint. Minted's point exactly: gold becomes relief, not print.
  Future<void> _loadFace() async {
    // Texture2D.fromAsset/fromImage build a mip chain; gpuTextureFromAsset
    // does not, and a mipless texture sparkles badly as the pin turns away.
    final image = await imageFromAsset(widget.pin.assetPath);
    try {
      _faceTexture = await Texture2D.fromImage(image);

      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null || image.width != image.height) return;

      // The analysis is a handful of full-image passes. Off the UI thread, or
      // selecting a pin drops frames.
      final relief = await compute(
        _analyzeArtwork,
        (raw.buffer.asUint8List(), image.width),
      );

      goldFraction = relief.goldFraction;
      _reliefTexture = Texture2D.fromPixels(
        relief.normalMap,
        relief.side,
        relief.side,
        // Passing a normal map as colour gamma-decodes it: normals flatten
        // and skew with distance, and only with distance.
        content: TextureContent.normal,
      );
      _metallicRoughnessTexture = Texture2D.fromPixels(
        relief.metallicRoughnessMap,
        relief.side,
        relief.side,
        content: TextureContent.data,
      );
    } finally {
      image.dispose();
    }
  }

  void _buildPin() {
    final coin = _coin;
    if (coin == null) return;

    for (final node in _partNodes) {
      coin.remove(node);
    }
    _partNodes.clear();

    final band = widget.geometry.rimBand;
    if (band != null) {
      final geometry = MeshGeometry.fromArrays(
        positions: band.positions,
        normals: band.normals,
        texCoords: band.texCoords,
        indices: band.indices,
      );
      final node = Node(
        name: 'rim-band',
        mesh: Mesh(
          geometry,
          CoinPalette(gold: widget.goldSrgb).materialFor(CoinSurface.gold),
        ),
      )..localTransform = vm.Matrix4.translation(
          vm.Vector3(0, 0, PinMetrics.rimBandCentreZ),
        );
      coin.add(node);
      _partNodes.add(node);
    }

    widget.geometry.parts.forEach((part, mesh) {
      final geometry = MeshGeometry.fromArrays(
        positions: mesh.positions,
        normals: mesh.normals,
        texCoords: mesh.texCoords,
        indices: mesh.indices,
      );
      final node = Node(
        name: part.name,
        mesh: Mesh(geometry, _materialFor(part)),
      );
      coin.add(node);
      _partNodes.add(node);
    });
  }

  PhysicallyBasedMaterial _materialFor(MedallionPart part) {
    final palette = CoinPalette(gold: widget.goldSrgb);

    switch (part) {
      case MedallionPart.front:
        final material = PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(1, 1, 1, 1);

        final face = _faceTexture;
        if (face != null) material.baseColorTexture = face;

        final relief = _reliefTexture;
        if (relief != null) {
          material
            ..normalTexture = relief
            ..normalScale = PinMetrics.reliefIntensity;
        }

        final metallicRoughness = _metallicRoughnessTexture;
        if (metallicRoughness != null) {
          // glTF packs both in one texture: B metallic, G roughness. The
          // factors multiply it, so they stay at 1 and the map decides which
          // pixels are metal and how rough each one is.
          material
            ..metallicRoughnessTexture = metallicRoughness
            ..metallicFactor = 1.0
            ..roughnessFactor = 1.0;
        } else {
          // No relief baked: the face is a flat painted surface, and claiming
          // it is metal without a map to say where would shade the whole pin
          // as one sheet of gold.
          material
            ..metallicFactor = 0.0
            ..roughnessFactor = PinMetrics.faceRoughness;
        }
        return material;

      case MedallionPart.back:
        // The reverse, die-struck. The orange-peel normal map is not built
        // yet, so only its roughness differs.
        return palette.materialFor(CoinSurface.orangePeelGold);

      case MedallionPart.side:
        return palette.materialFor(CoinSurface.gold);
    }
  }

  @override
  void didUpdateWidget(PinView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (oldWidget.pin.slug != widget.pin.slug) {
      _yaw = 0;
      _pitch = 0;
      _loadFace().then((_) {
        if (mounted) _buildPin();
      });
    } else if (!identical(oldWidget.goldSrgb, widget.goldSrgb)) {
      _buildPin();
    }
  }

  void _onTick(Duration elapsed, double deltaSeconds) {
    if (_coin == null || _dragging) return;

    // Ease a flick back down to the idle rate, the way Minted's momentum
    // action eases out and then hands back to the idle spin.
    final settle = 1 - math.exp(-deltaSeconds / 0.9);

    _yawVelocity += (_idleRate - _yawVelocity) * settle;
    _yaw += _yawVelocity * deltaSeconds;

    // Pitch has no idle motion to return to, so it simply runs down. Once it
    // is spent the pin keeps whatever tilt the viewer left it at.
    _pitchVelocity += (0.0 - _pitchVelocity) * settle;
    _pitch = (_pitch + _pitchVelocity * deltaSeconds)
        .clamp(-_pitchLimit, _pitchLimit);
    if (_pitch.abs() >= _pitchLimit) _pitchVelocity = 0.0;

    _applyPose();
  }

  @override
  Widget build(BuildContext context) {
    // Outermost, so the view's shape is tracked even while the engine is
    // still starting: the camera is then already right the frame it becomes
    // ready. Moving the camera node dirties no widget, so doing it during
    // layout is safe.
    return LayoutBuilder(
      builder: (context, constraints) {
        final aspect = constraints.maxHeight <= 0
            ? 1.0
            : constraints.maxWidth / constraints.maxHeight;
        if ((aspect - _aspect).abs() > 1e-3) {
          _aspect = aspect;
          _placeCamera();
        }
        return _buildContent();
      },
    );
  }

  Widget _buildContent() {
    if (_failure != null) {
      return _PinMessage(
        title: 'The 3D view could not start',
        detail: '$_failure',
      );
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());

    // A plain pan, not a horizontal-only drag: the pin turns whichever way
    // the finger goes.
    final Widget view = GestureDetector(
      onPanStart: (_) {
        _dragging = true;
        _yawVelocity = 0.0;
        _pitchVelocity = 0.0;
      },
      onPanUpdate: (details) {
        _yaw += details.delta.dx * _dragSensitivity;
        // Dragging down tips the pin's top toward the viewer.
        _pitch = (_pitch - details.delta.dy * _dragSensitivity)
            .clamp(-_pitchLimit, _pitchLimit);
        _applyPose();
      },
      onPanEnd: (details) {
        _dragging = false;
        final velocity = details.velocity.pixelsPerSecond;
        _yawVelocity = velocity.dx * 0.0022;
        _pitchVelocity = -velocity.dy * 0.0022;
      },
      // Double tap puts a pin that has been turned every which way back the
      // way it came.
      onDoubleTap: () {
        _pitch = 0.0;
        _pitchVelocity = 0.0;
        _yawVelocity = _idleRate;
        _applyPose();
      },
      child: SceneView(_scene, onTick: _onTick),
    );

    if (!widget.showBackdrop) return view;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.0,
          colors: <Color>[Color(0xFF232026), Color(0xFF0B0A0C)],
        ),
      ),
      child: view,
    );
  }
}

class _PinMessage extends StatelessWidget {
  const _PinMessage({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(height: 10),
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}


/// Isolate entry point for the relief bake.
ArtworkRelief _analyzeArtwork((Uint8List, int) input) =>
    ArtworkAnalyzer.analyze(input.$1, input.$2);
