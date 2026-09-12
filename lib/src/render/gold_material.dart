// Ported from Minted by Haplo LLC (MIT) -- see third_party/minted/LICENSE.
// https://github.com/haplollc/Minted
//
// Materials follow `CoinScene.swift`. SceneKit takes `diffuse.contents` as a
// UIColor, which is sRGB-encoded; flutter_scene's `baseColorFactor` is linear.
// The colours below are therefore written in Minted's original sRGB values and
// converted, so the provenance stays readable and the shading stays correct.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../geometry/contour.dart';

/// The sRGB electro-optical transfer function, per component.
double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

vm.Vector4 _linear(double r, double g, double b) => vm.Vector4(
  _srgbToLinear(r),
  _srgbToLinear(g),
  _srgbToLinear(b),
  1.0,
);

/// A coin's colours.
class CoinPalette {
  const CoinPalette({
    this.field = const <double>[0.16, 0.20, 0.58],
    this.art = const <double>[0.94, 0.91, 0.84],
    this.artLower,
    this.artSplit = 1.0,
    this.gold = roseGoldSrgb,
  });

  /// Minted's default: "a warm rose gold that reads as real metal under the
  /// studio lights." sRGB.
  static const List<double> roseGoldSrgb = <double>[1.0, 0.80, 0.52];

  /// Measured reflectance of real gold, for comparison. sRGB.
  static const List<double> trueGoldSrgb = <double>[1.0, 0.84, 0.60];

  static const List<double> silverSrgb = <double>[0.97, 0.96, 0.94];

  /// The enamel behind the art.
  final List<double> field;

  /// The centre art's enamel.
  final List<double> art;

  /// The art's lower cells when [artSplit] drops below 1.
  final List<double>? artLower;

  /// Where the art's colour splits, as a fraction of its height from the top.
  final double artSplit;

  /// The metal everywhere else.
  final List<double> gold;

  CoinPalette copyWith({List<double>? field, List<double>? art, List<double>? gold}) =>
      CoinPalette(
        field: field ?? this.field,
        art: art ?? this.art,
        artLower: artLower,
        artSplit: artSplit,
        gold: gold ?? this.gold,
      );

  /// Builds the material for one surface.
  ///
  /// The numbers are Minted's: gold is metalness 1.0 / roughness 0.28, enamel
  /// is metalness 0.0 / roughness 0.08, engraved gold is metalness 0.55 /
  /// roughness 0.42, and the orange-peel reverse drops to roughness 0.36.
  PhysicallyBasedMaterial materialFor(
    CoinSurface surface, {
    List<double>? enamelColor,
    double? roughnessOverride,
  }) {
    switch (surface) {
      case CoinSurface.gold:
        return PhysicallyBasedMaterial()
          ..baseColorFactor = _linear(gold[0], gold[1], gold[2])
          ..metallicFactor = 1.0
          ..roughnessFactor = roughnessOverride ?? 0.28;

      case CoinSurface.orangePeelGold:
        return PhysicallyBasedMaterial()
          ..baseColorFactor = _linear(gold[0], gold[1], gold[2])
          ..metallicFactor = 1.0
          ..roughnessFactor = roughnessOverride ?? 0.36;

      case CoinSurface.enamel:
        final c = enamelColor ?? art;
        return PhysicallyBasedMaterial()
          ..baseColorFactor = _linear(c[0], c[1], c[2])
          // A dielectric. Enamel is glassy, not metallic.
          ..metallicFactor = 0.0
          ..roughnessFactor = roughnessOverride ?? 0.08;

      case CoinSurface.engravedGold:
        return PhysicallyBasedMaterial()
          ..baseColorFactor = _linear(0.60, 0.42, 0.24)
          ..metallicFactor = 0.55
          ..roughnessFactor = roughnessOverride ?? 0.42;
    }
  }
}

/// Camera and lighting rig, from `CoinScene.makeScene`.
class CoinRig {
  const CoinRig._();

  /// Minted uses a narrow 26-degree lens at z = 2.75 on a coin of diameter 1.
  /// A long lens keeps the coin from splaying in perspective.
  static const double fieldOfViewDegrees = 26.0;
  static const double cameraDistance = 2.75;

  /// The coin spans [-0.5, 0.5]; the diamond squircle reaches 0.524.
  static const double coinRadius = 0.53;

  /// Camera distance that fits the coin in a view of the given aspect ratio
  /// (width / height).
  ///
  /// Minted's fixed 2.75 assumes a square frame -- SwiftUI's
  /// `.frame(width: 300, height: 300)`. The field of view is *vertical*, so a
  /// portrait view's horizontal extent is narrower by the aspect ratio and a
  /// fixed distance crops the coin's sides off.
  ///
  /// Dividing by the narrow axis holds the horizontal half-extent constant at
  /// whatever Minted's distance gives a square view, so the framing margin is
  /// preserved by construction rather than by a second tuned number. A
  /// landscape view is not pushed back at all: only the narrow axis can crop.
  static double distanceFor(double aspect) {
    final limiting = aspect.isFinite && aspect > 0 ? math.min(1.0, aspect) : 1.0;
    return cameraDistance / limiting;
  }

  /// A slight fixed tilt gives the coin depth even in still renders. The coin
  /// spins as a child of the tilt, so the tilt never wobbles.
  static const double tiltRadians = -0.14;

  /// Seconds per idle revolution. "Slower reads as heavier."
  static const double idlePeriodSeconds = 11.0;

  /// `lightingEnvironment.intensity = 1.5`.
  static const double environmentIntensity = 1.5;

  /// The four lights, as world-space travel directions with Minted's relative
  /// intensities.
  ///
  /// Minted's SceneKit intensities are 800 / 300 / 500 / 320 on SceneKit's
  /// lumen-ish scale, which does not transfer to flutter_scene. The *ratios*
  /// do, so they are kept and scaled by [lightScale], which is the one number
  /// that needs calibrating against a screenshot.
  static const double lightScale = 3.0 / 800.0;

  static List<CoinLight> lights() => <CoinLight>[
    // Key light for a hot specular hit; the environment does the rest.
    CoinLight(
      name: 'key',
      direction: vm.Vector3(-0.3418, -0.4794, -0.8083),
      colorSrgb: const <double>[1.0, 0.96, 0.90],
      sceneKitIntensity: 800,
    ),
    // Cool fill from the far side so a spinning face never goes muddy.
    CoinLight(
      name: 'fill',
      direction: vm.Vector3(0.7745, -0.1494, -0.6146),
      colorSrgb: const <double>[0.88, 0.92, 1.0],
      sceneKitIntensity: 300,
    ),
    // Warm kicker aimed at the back so the reverse gleams too.
    CoinLight(
      name: 'back',
      direction: vm.Vector3(-0.3720, -0.2955, 0.8800),
      colorSrgb: const <double>[1.0, 0.93, 0.85],
      sceneKitIntensity: 500,
    ),
    // Headlight riding the camera: whatever face the viewer sees is never
    // unlit, no matter how far the coin has turned.
    //
    // This direction is camera-*local*, not world: the node's rotation carries
    // it. flutter_scene's camera looks along its own +Z, so the headlight
    // travels along +Z too. (SceneKit's looks along -Z, which is why Minted's
    // value cannot be copied across unchanged.)
    CoinLight(
      name: 'headlight',
      direction: vm.Vector3(0.0, 0.0, 1.0),
      colorSrgb: const <double>[1.0, 0.97, 0.92],
      sceneKitIntensity: 320,
      ridesCamera: true,
    ),
  ];
}

/// One light in the rig.
class CoinLight {
  const CoinLight({
    required this.name,
    required this.direction,
    required this.colorSrgb,
    required this.sceneKitIntensity,
    this.ridesCamera = false,
  });

  final String name;

  /// The direction the light travels: world-space for the three fixed lights
  /// (derived from Minted's SceneKit euler angles, whose directional lights
  /// travel along their node's -Z), and camera-local for the headlight, whose
  /// node rides the camera and inherits its rotation.
  final vm.Vector3 direction;

  final List<double> colorSrgb;

  /// Minted's original value, kept for provenance.
  final double sceneKitIntensity;

  /// Whether the light is parented to the camera rather than the world.
  final bool ridesCamera;

  double get intensity => sceneKitIntensity * CoinRig.lightScale;

  vm.Vector3 get colorLinear => vm.Vector3(
    _srgbToLinear(colorSrgb[0]),
    _srgbToLinear(colorSrgb[1]),
    _srgbToLinear(colorSrgb[2]),
  );

  DirectionalLight toLight() => DirectionalLight(
    color: colorLinear,
    intensity: intensity,
  );
}
