import 'package:flutter/material.dart';

import 'pin_outlines.g.dart';
import 'pin_view.dart';

/// The Tashkent landmark collection: one pin turning in 3D, with the rest of
/// the set below it.
class PinsPage extends StatefulWidget {
  const PinsPage({super.key});

  @override
  State<PinsPage> createState() => _PinsPageState();
}

class _PinsPageState extends State<PinsPage> {
  int _selected = 0;

  /// Geometry is built once per pin and cached: tessellating on every tap
  /// would stutter the selection.
  final Map<String, PinGeometry?> _geometry = <String, PinGeometry?>{};

  PinOutline get _pin => kPinOutlines[_selected];

  PinGeometry? _geometryFor(PinOutline pin) =>
      _geometry.putIfAbsent(pin.slug, () => PinGeometry.build(pin.pathData));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (kPinOutlines.isEmpty) {
      return const Scaffold(
        body: Center(child: Text('No pins have been built yet.')),
      );
    }

    final geometry = _geometryFor(_pin);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Column(
                children: <Widget>[
                  Text(
                    'TASHKENT LANDMARK COLLECTION',
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _pin.title,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

            // The hero. A live 3D view is for the one pin in focus; the rest
            // of the set stays flat below.
            //
            // Kept square: the lens is a narrow 26 degrees and its field of
            // view is vertical, so a tall panel is the one shape that wastes
            // the most of it.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: geometry == null
                          ? _FailedPin(pin: _pin)
                          : PinView(
                              key: ValueKey<String>(_pin.slug),
                              pin: _pin,
                              geometry: geometry,
                            ),
                    ),
                  ),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
              child: Text(
                'Drag any direction to turn it. Flick to spin, '
                'double tap to reset.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),

            SizedBox(
              height: 104,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: kPinOutlines.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final pin = kPinOutlines[index];
                  final isSelected = index == _selected;
                  return _PinChip(
                    pin: pin,
                    selected: isSelected,
                    onTap: () => setState(() => _selected = index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinChip extends StatelessWidget {
  const _PinChip({
    required this.pin,
    required this.selected,
    required this.onTap,
  });

  final PinOutline pin;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: pin.title,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 84,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected
                ? theme.colorScheme.primaryContainer
                : Colors.transparent,
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Image.asset(
            pin.assetPath,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}

/// A pin whose outline could not be extruded. It renders as nothing at all in
/// 3D, so it says so rather than showing an empty panel.
class _FailedPin extends StatelessWidget {
  const _FailedPin({required this.pin});

  final PinOutline pin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.report_gmailerrorred_outlined,
                  size: 36, color: theme.colorScheme.error),
              const SizedBox(height: 10),
              Text('${pin.title} could not be extruded',
                  style: theme.textTheme.titleSmall,
                  textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                'Its traced outline failed to tessellate. Re-run '
                'tool/build_pins.py to retrace it.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
