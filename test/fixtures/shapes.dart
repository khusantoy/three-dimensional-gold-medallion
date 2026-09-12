/// Test artwork, authored for this repository.
///
/// Chosen to break a naive triangulator: concave notches, reflex corners,
/// counters that must become holes, and an outline with no close command.
class TestShape {
  const TestShape(this.name, this.pathData);

  final String name;
  final String pathData;

  static const heart = TestShape(
    'Heart',
    'M 50 92 C 18 66, 4 46, 4 30 C 4 14, 17 4, 32 4 '
        'C 41 4, 47 9, 50 16 C 53 9, 59 4, 68 4 '
        'C 83 4, 96 14, 96 30 C 96 46, 82 66, 50 92 Z',
  );

  static const star = TestShape(
    'Star',
    'M 50 3 L 61.17 34.63 L 94.7 35.48 L 68.07 55.87 L 77.63 88.02 '
        'L 50 69 L 22.37 88.02 L 31.93 55.87 L 5.3 35.48 L 38.83 34.63 Z',
  );

  static const ring = TestShape(
    'Ring',
    'M 50 3 A 47 47 0 1 0 50 97 A 47 47 0 1 0 50 3 Z '
        'M 50 24 A 26 26 0 1 1 50 76 A 26 26 0 1 1 50 24 Z',
  );

  static const hexNut = TestShape(
    'Hex nut',
    'M 50 3 L 90.7 26.5 L 90.7 73.5 L 50 97 L 9.3 73.5 L 9.3 26.5 Z '
        'M 50 28 A 22 22 0 1 1 50 72 A 22 22 0 1 1 50 28 Z',
  );

  static const crescent = TestShape(
    'Crescent',
    'M 62 6 A 46 46 0 1 0 62 94 A 36 36 0 1 1 62 6 Z',
  );

  static const letterB = TestShape(
    'Letter B',
    'M 22 6 L 58 6 C 76 6, 86 16, 86 30 C 86 40, 80 47, 71 50 '
        'C 82 52, 90 60, 90 72 C 90 86, 79 94, 60 94 L 22 94 Z '
        'M 42 24 L 42 42 L 56 42 C 63 42, 67 38, 67 33 '
        'C 67 28, 63 24, 56 24 Z '
        'M 42 58 L 42 76 L 58 76 C 66 76, 70 72, 70 67 '
        'C 70 62, 66 58, 58 58 Z',
  );

  static const cross = TestShape(
    'Cross',
    'M 38 4 L 62 4 L 62 38 L 96 38 L 96 62 L 62 62 '
        'L 62 96 L 38 96 L 38 62 L 4 62 L 4 38 L 38 38 Z',
  );

  static const openOutline = TestShape(
    'Open outline',
    'M 12 78 L 50 10 L 88 78',
  );

  static const all = <TestShape>[
    heart, star, ring, hexNut, crescent, letterB, cross, openOutline,
  ];
}
