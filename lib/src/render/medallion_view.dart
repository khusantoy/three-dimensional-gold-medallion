// Ported from Minted by Haplo LLC (MIT) -- see third_party/minted/LICENSE.
// https://github.com/haplollc/Minted
//
// The scene graph, camera, light rig, and the momentum-flick interaction
// follow `CoinScene.makeScene` and `SpinningCoinView.swift`.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../geometry/coin_assembly.dart';
import '../geometry/contour.dart';
import 'gold_material.dart';

/// Which image-based lighting environment the coin reflects.
enum MedallionEnvironment {
  /// flutter_scene's built-in procedural studio map. The closest analogue to
  /// Minted's generated studio panorama: a cool ceiling, a warm floor bounce,
  /// and soft key lobes, built at runtime with no HDRI to ship.
  studio,

  /// A photographic 2:1 equirectangular panorama bundled inside the
  /// flutter_scene package. Busier, so reflections have more to sweep across.
  panorama;

  String get label => switch (this) {
    MedallionEnvironment.studio => 'Studio',
    MedallionEnvironment.panorama => 'Panorama',
  };
}

/// The full 3D coin, alive: idles in a slow spin, and a drag flicks it with
/// momentum.
class MedallionView extends StatefulWidget {
  const MedallionView({
    super.key,
    required this.assembly,
    required this.palette,
    this.environment = MedallionEnvironment.studio,
    this.roughnessOverride,
    this.idlePeriodSeconds = CoinRig.idlePeriodSeconds,
    this.initialRotation = 0.0,
    this.useLightRig = true,
    this.showBackdrop = true,
  });

  final CoinAssembly assembly;
  final CoinPalette palette;
  final MedallionEnvironment environment;

  /// Sweeps every metal surface's roughness together, for tuning.
  final double? roughnessOverride;

  /// Seconds per idle revolution. Minted: "slower reads as heavier."
  final double idlePeriodSeconds;

  /// Radians around Y applied at creation, so a host can present the coin's
  /// back by passing pi.
  final double initialRotation;

  /// Whether to add Minted's four directional lights on top of the
  /// environment. With it off, the environment lights the coin alone.
  final bool useLightRig;

  final bool showBackdrop;

  @override
  State<MedallionView> createState() => _MedallionViewState();
}

class _MedallionViewState extends State<MedallionView> {
  final Scene _scene = Scene();
  final Map<MedallionEnvironment, EnvironmentMap> _environments = {};

  /// The node that spins. Minted keeps the tilt on a parent so the tilt never
  /// wobbles as the coin turns.
  Node? _coin;
  Node? _cameraNode;
  final List<Node> _slabNodes = <Node>[];

  bool _ready = false;
  String? _failure;

  double _spin = 0.0;

  /// Radians per second currently being applied. Settles back to the idle
  /// rate after a flick.
  double _angularVelocity = 0.0;
  bool _dragging = false;

  double get _idleRate =>
      widget.idlePeriodSeconds <= 0 ? 0 : 2 * math.pi / widget.idlePeriodSeconds;

  @override
  void initState() {
    super.initState();
    _spin = widget.initialRotation;
    _angularVelocity = _idleRate;
    _boot();
  }

  Future<void> _boot() async {
    try {
      // Geometry and materials touch the shader bundle, so nothing may be
      // built before the engine's static resources are up.
      await Scene.initializeStaticResources();
      if (!mounted) return;

      _buildRig();
      await _applyEnvironment();
      _buildCoin();

      if (mounted) setState(() => _ready = true);
    } on Object catch (e, stack) {
      debugPrint('MedallionView failed to initialize: $e\n$stack');
      if (mounted) setState(() => _failure = '$e');
    }
  }

  void _buildRig() {
    // A slight fixed tilt gives the coin depth even in still renders; the
    // child spins so the tilt never wobbles.
    final tilt = Node(name: 'tilt')
      ..localTransform = vm.Matrix4.rotationX(CoinRig.tiltRadians);
    _scene.add(tilt);

    final coin = Node(name: 'coin');
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
    // A NodeCamera looks along its node's +Z. SceneKit's looks along -Z, so
    // Minted's camera at z = +2.75 with no rotation would face away from the
    // coin here and render an empty frame. Aim it explicitly instead of
    // translating and hoping.
    camera.lookAtFrom(
      vm.Vector3(0, 0, CoinRig.cameraDistance),
      vm.Vector3.zero(),
    );
    _scene.add(camera);
    _cameraNode = camera;

    if (!widget.useLightRig) return;

    for (final light in CoinRig.lights()) {
      final node = Node(name: 'light-${light.name}')
        ..addComponent(
          DirectionalLightComponent.aimed(light.toLight(), light.direction),
        );
      // The headlight rides the camera so whatever face the viewer sees is
      // never unlit, no matter how far the coin has turned.
      if (light.ridesCamera) {
        _cameraNode!.add(node);
      } else {
        _scene.add(node);
      }
    }
  }

  Future<void> _applyEnvironment() async {
    final cached = _environments[widget.environment];
    final map = cached ??
        switch (widget.environment) {
          MedallionEnvironment.studio => EnvironmentMap.studio(),
          MedallionEnvironment.panorama =>
            await EnvironmentMap.fromEquirectImageAsset(
              assetPath: 'packages/flutter_scene/assets/royal_esplanade.png',
            ),
        };
    _environments[widget.environment] = map;
    _scene.environment = map;
    // Minted: `lightingEnvironment.intensity = 1.5`.
    _scene.environmentIntensity = CoinRig.environmentIntensity;
  }

  /// Uploads every slab as its own node, positioned at its rise.
  void _buildCoin() {
    final coin = _coin;
    if (coin == null) return;

    for (final node in _slabNodes) {
      coin.remove(node);
    }
    _slabNodes.clear();

    for (final slab in widget.assembly.slabs) {
      final geometry = MeshGeometry.fromArrays(
        positions: slab.mesh.positions,
        normals: slab.mesh.normals,
        texCoords: slab.mesh.texCoords,
        // Layer A guarantees every index is in range and every triangle winds
        // counter-clockwise, both verified by unit test.
        indices: slab.mesh.indices,
      );

      final node = Node(
        name: slab.name,
        mesh: Mesh(geometry, _materialFor(slab.surface)),
      )..localTransform = vm.Matrix4.translation(
          vm.Vector3(0, 0, slab.centreZ),
        );

      coin.add(node);
      _slabNodes.add(node);
    }
  }

  PhysicallyBasedMaterial _materialFor(CoinSurface surface) {
    final isMetal = surface != CoinSurface.enamel;
    return widget.palette.materialFor(
      surface,
      enamelColor: widget.palette.art,
      // The roughness sweep is for tuning the metal; enamel keeps its own.
      roughnessOverride: isMetal ? widget.roughnessOverride : null,
    );
  }

  void _applyMaterials() {
    for (var i = 0; i < _slabNodes.length; i++) {
      final mesh = _slabNodes[i].getComponent<MeshComponent>()?.mesh;
      if (mesh == null) continue;
      mesh.primitives.first.material =
          _materialFor(widget.assembly.slabs[i].surface);
    }
  }

  @override
  void didUpdateWidget(MedallionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;

    if (!identical(oldWidget.assembly, widget.assembly)) {
      _buildCoin();
    } else if (!identical(oldWidget.palette, widget.palette) ||
        oldWidget.roughnessOverride != widget.roughnessOverride) {
      _applyMaterials();
    }
    if (oldWidget.environment != widget.environment) {
      _applyEnvironment().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _onTick(Duration elapsed, double deltaSeconds) {
    final coin = _coin;
    if (coin == null || _dragging) return;

    // Ease a flick back down to the idle rate, the way Minted's momentum
    // action eases out and then hands back to the idle spin.
    final settle = 1 - math.exp(-deltaSeconds / 0.9);
    _angularVelocity += (_idleRate - _angularVelocity) * settle;
    _spin += _angularVelocity * deltaSeconds;

    // Assign a fresh transform. Editing the matrix a getter returns never
    // moves the node (silent failure trap #1) and throws in debug.
    coin.localTransform = vm.Matrix4.rotationY(_spin);
  }

  void _onPanStart(DragStartDetails _) => _dragging = true;

  void _onPanUpdate(DragUpdateDetails details) {
    final coin = _coin;
    if (coin == null) return;
    // Minted: `coin.eulerAngles.y += translation.x * 0.012`.
    _spin += details.delta.dx * 0.012;
    coin.localTransform = vm.Matrix4.rotationY(_spin);
  }

  void _onPanEnd(DragEndDetails details) {
    _dragging = false;
    // Minted converts the gesture's pixel velocity into a spin; the same
    // constant, expressed as radians per second rather than a 1.4s action.
    _angularVelocity = details.velocity.pixelsPerSecond.dx * 0.0022;
  }

  @override
  Widget build(BuildContext context) {
    if (_failure != null) {
      return _Message(
        title: 'The 3D view could not start',
        detail: '$_failure\n\nFlutter GPU must be enabled: run with '
            '--enable-flutter-gpu.',
      );
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());

    Widget view = GestureDetector(
      onHorizontalDragStart: _onPanStart,
      onHorizontalDragUpdate: _onPanUpdate,
      onHorizontalDragEnd: _onPanEnd,
      child: SceneView(_scene, onTick: _onTick),
    );

    if (!widget.showBackdrop) return view;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.25),
          radius: 1.1,
          colors: <Color>[Color(0xFF2A2620), Color(0xFF0C0B0A)],
        ),
      ),
      child: view,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
