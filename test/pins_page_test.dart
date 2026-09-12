// What can honestly be checked about the page without a GPU.
//
// flutter_scene renders through Flutter GPU, which needs Impeller, which the
// test binding does not provide. `Scene`'s constructor throws here, so the
// whole 3D subtree is replaced by an ErrorWidget before it lays out. Nothing
// inside the panel -- the camera, the pose, the materials -- can be exercised
// from a widget test at all; that needs a device.
//
// What is left is the chrome around it, and the pure-Dart geometry the page
// feeds the panel. Those are worth guarding: a pin whose outline fails to
// build shows an error card instead of an empty box, and the page must not
// crash while selecting between pins.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_dimensional_gold_medallion/src/pins/pin_outlines.g.dart';
import 'package:three_dimensional_gold_medallion/src/pins/pin_view.dart';
import 'package:three_dimensional_gold_medallion/src/pins/pins_page.dart';

/// The one failure this environment is expected to produce.
bool isMissingGpu(Object error) =>
    error.toString().contains('Flutter GPU requires the Impeller');

/// Drains recorded exceptions, failing on anything that is not the known
/// Impeller limitation.
void expectOnlyGpuFailures(WidgetTester tester) {
  for (var i = 0; i < 16; i++) {
    final error = tester.takeException();
    if (error == null) return;
    expect(error, predicate<Object>(isMissingGpu),
        reason: 'unexpected widget failure: $error');
  }
}

void main() {
  testWidgets('the page renders its chrome around the 3D panel',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PinsPage()));
    await tester.pump();
    expectOnlyGpuFailures(tester);

    expect(find.text('TASHKENT LANDMARK COLLECTION'), findsOneWidget);
    expect(find.text(kPinOutlines.first.title), findsOneWidget);
    expect(find.byType(Image), findsWidgets, reason: 'no thumbnail strip');
  });

  testWidgets('selecting another pin does not crash the page', (tester) async {
    if (kPinOutlines.length < 2) return;

    await tester.pumpWidget(const MaterialApp(home: PinsPage()));
    await tester.pump();
    expectOnlyGpuFailures(tester);

    await tester.tap(
      find.bySemanticsLabel(kPinOutlines[1].title).first,
      warnIfMissed: false,
    );
    await tester.pump();
    expectOnlyGpuFailures(tester);

    expect(find.text(kPinOutlines[1].title), findsWidgets);
  });

  test('every pin the page can select has buildable geometry', () {
    // The page shows an error card when this returns null, so a regression
    // here is visible rather than an empty panel -- but it should not happen.
    for (final pin in kPinOutlines) {
      expect(PinGeometry.build(pin.pathData), isNotNull, reason: pin.slug);
    }
  });
}
