// The bug this exists for: a camera node translated to +Z with no rotation
// looks *away* from the coin, because flutter_scene's NodeCamera reads its
// forward off the node's +Z column while SceneKit's camera looks down -Z.
// The frame comes back empty with no error, so it has to be caught here.
import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_dimensional_gold_medallion/src/render/gold_material.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The node's +Z column, which is what `NodeCamera.forward` returns.
vm.Vector3 forwardOf(Node node) {
  final t = node.globalTransform;
  return vm.Vector3(t[8], t[9], t[10]).normalized();
}

void main() {
  test('the camera sits on the +Z side and looks back at the coin', () {
    final camera = Node(name: 'camera');
    camera.lookAtFrom(
      vm.Vector3(0, 0, CoinRig.cameraDistance),
      vm.Vector3.zero(),
    );

    final position = camera.globalTransform.getTranslation();
    expect(position.z, closeTo(CoinRig.cameraDistance, 1e-5));

    // The coin's front cap is at +Z, so the camera must be in front of it
    // and looking back down -Z.
    final forward = forwardOf(camera);
    expect(forward.z, closeTo(-1.0, 1e-5),
        reason: 'camera is facing away from the coin');
    expect(forward.x.abs(), lessThan(1e-5));
    expect(forward.y.abs(), lessThan(1e-5));
  });

  group('framing', () {
    /// What the camera can see at [distance], as (half-width, half-height).
    (double, double) extentAt(double distance, double aspect) {
      final halfHeight =
          distance * math.tan(CoinRig.fieldOfViewDegrees * vm.degrees2Radians / 2);
      return (halfHeight * aspect, halfHeight);
    }

    test('Minted\'s fixed distance only frames a square view', () {
      // The value carried over from SwiftUI's .frame(300, 300).
      final (squareWidth, _) = extentAt(CoinRig.cameraDistance, 1.0);
      expect(squareWidth, greaterThan(CoinRig.coinRadius));

      // The same distance in a portrait view crops the coin's sides off,
      // because the field of view is vertical. This is the bug.
      final (portraitWidth, _) = extentAt(CoinRig.cameraDistance, 0.65);
      expect(portraitWidth, lessThan(CoinRig.coinRadius));
    });

    test('the coin fits at every aspect ratio, portrait included', () {
      for (final aspect in <double>[0.4, 0.55, 0.65, 0.8, 1.0, 1.6, 2.2]) {
        final (halfWidth, halfHeight) =
            extentAt(CoinRig.distanceFor(aspect), aspect);
        expect(halfWidth, greaterThanOrEqualTo(CoinRig.coinRadius),
            reason: 'cropped left and right at aspect $aspect');
        expect(halfHeight, greaterThanOrEqualTo(CoinRig.coinRadius),
            reason: 'cropped top and bottom at aspect $aspect');
      }
    });

    test('a square view keeps Minted\'s own framing', () {
      expect(CoinRig.distanceFor(1.0),
          closeTo(CoinRig.cameraDistance, 0.05));
    });

    test('a landscape view is not pushed further back than a square one', () {
      // Only the narrow axis limits the fit, so widening the view must not
      // shrink the coin.
      expect(CoinRig.distanceFor(2.0),
          closeTo(CoinRig.distanceFor(1.0), 1e-9));
    });

    test('a degenerate aspect ratio does not produce a broken camera', () {
      for (final aspect in <double>[0.0, -1.0, double.nan, double.infinity]) {
        final distance = CoinRig.distanceFor(aspect);
        expect(distance.isFinite, isTrue, reason: 'aspect $aspect');
        expect(distance, greaterThan(0), reason: 'aspect $aspect');
      }
    });
  });

  test('the three fixed lights are world-space and light both faces', () {
    final lights = CoinRig.lights();
    final key = lights.firstWhere((l) => l.name == 'key');
    final back = lights.firstWhere((l) => l.name == 'back');

    // The key travels toward -Z, so it comes from the viewer's side and lights
    // the front; the back light travels toward +Z and lights the reverse.
    expect(key.direction.z, lessThan(0));
    expect(back.direction.z, greaterThan(0));
    expect(key.ridesCamera, isFalse);
  });

  test('the headlight points along the camera\'s own forward axis', () {
    final headlight =
        CoinRig.lights().firstWhere((l) => l.name == 'headlight');
    expect(headlight.ridesCamera, isTrue);
    // Camera-local, and flutter_scene's camera looks along +Z. Copying
    // SceneKit's -Z here would aim the headlight out of the screen.
    expect(headlight.direction.z, closeTo(1.0, 1e-9));
  });

  test('Minted\'s light ratios survive the intensity rescale', () {
    final lights = <String, CoinLight>{
      for (final l in CoinRig.lights()) l.name: l,
    };
    // 800 : 300 : 500 : 320 in SceneKit's units.
    expect(
      lights['key']!.intensity / lights['fill']!.intensity,
      closeTo(800 / 300, 1e-9),
    );
    expect(
      lights['back']!.intensity / lights['headlight']!.intensity,
      closeTo(500 / 320, 1e-9),
    );
  });
}
