import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/web/crossfade.dart';

// The cases of CrossfadeTest.kt, for the Dart copy: the three platforms fade by the same amount

void main() {
  // position, duration, seconds, fadeIn, fadeOut, level
  const table = <(int, int, int, bool, bool, double)>[
    // 6 s: the start fades in over 3 s, the end out over 6 s
    (0, 200000, 6, true, true, 0),
    (750, 200000, 6, true, true, 0.1464),
    (1500, 200000, 6, true, true, 0.5),
    (2250, 200000, 6, true, true, 0.8536),
    (3000, 200000, 6, true, true, 1),
    (100000, 200000, 6, true, true, 1),
    (194000, 200000, 6, true, true, 1),
    (195500, 200000, 6, true, true, 0.8536),
    (197000, 200000, 6, true, true, 0.5),
    (198500, 200000, 6, true, true, 0.1464),
    (200000, 200000, 6, true, true, 0),
    (201000, 200000, 6, true, true, 0),
    // A song that did not come by itself starts at full, one with nothing after it ends at full
    (0, 200000, 6, false, true, 1),
    (200000, 200000, 6, true, false, 1),
    // Off, and songs shorter than three times the fade
    (0, 200000, 0, true, true, 1),
    (0, 17999, 6, true, true, 1),
    (17999, 17999, 6, true, true, 1),
    (0, 18000, 6, true, true, 0),
    // The shortest and the longest setting
    (500, 200000, 1, true, true, 1),
    (199500, 200000, 1, true, true, 0.5),
    (6000, 600000, 12, true, true, 1),
    (3000, 600000, 12, true, true, 0.5),
  ];

  test('the volume of a position follows the table', () {
    for (final (position, duration, seconds, fadeIn, fadeOut, level) in table) {
      expect(
        Crossfade.ramp(
          position,
          duration,
          seconds,
          fadeIn: fadeIn,
          fadeOut: fadeOut,
        ),
        closeTo(level, 0.0001),
        reason: '$position of $duration ms, $seconds s',
      );
    }
  });

  test('a seconds value out of range is no fade', () {
    expect(Crossfade.applies(600000, 0), isFalse);
    expect(Crossfade.applies(600000, 13), isFalse);
    expect(Crossfade.applies(600000, 12), isTrue);
  });

  test(
    'a song seen near its end ended by itself, one seen in the middle did not',
    () {
      expect(Crossfade.endedItself(197000, 200000, 3200), isTrue);
      expect(Crossfade.endedItself(100000, 200000, 100500), isTrue);
      expect(Crossfade.endedItself(100000, 200000, 20000), isFalse);
      expect(Crossfade.endedItself(0, 0, 5000), isFalse);
    },
  );
}
