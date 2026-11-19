import 'dart:math' as math;

/// The soft change between two songs: the last seconds of a song fade out and the first half of that time of the next
/// song fades in. The songs do not overlap, so no moment of the room's timeline moves. Dart counterpart of
/// `Crossfade.kt`.
///
/// Only the volume is a function of the position; whether a fade applies at the start (the song came by itself, not by a
/// press on Next) and at the end (a song follows) is for the player's side to say.
class Crossfade {
  const Crossfade._();

  static const maxSeconds = 12;

  /// A song shorter than this many times the fade time is played as it is.
  static const _minSongFactor = 3;

  static const _endSlackMs = 1500;

  /// The fade is on for songs of this length.
  static bool applies(int durationMs, int seconds) =>
      seconds >= 1 &&
      seconds <= maxSeconds &&
      durationMs >= _minSongFactor * seconds * 1000;

  /// The share (0..1) of the volume that [positionMs] of a song [durationMs] long gets; 1 outside the two fades.
  static double ramp(
    int positionMs,
    int durationMs,
    int seconds, {
    required bool fadeIn,
    required bool fadeOut,
  }) {
    if (!applies(durationMs, seconds)) return 1;
    final outMs = seconds * 1000;
    final inMs = outMs ~/ 2;
    var level = 1.0;
    if (fadeOut && durationMs - positionMs < outMs) {
      level *= _curve(math.max(durationMs - positionMs, 0) / outMs);
    }
    if (fadeIn && positionMs < inMs) {
      level *= _curve(math.max(positionMs, 0) / inMs);
    }
    return level;
  }

  /// Whether a song that was last seen playing at [lastPositionMs], [elapsedMs] ago, has played to its end by now.
  static bool endedItself(int lastPositionMs, int durationMs, int elapsedMs) =>
      durationMs > 0 &&
      lastPositionMs + elapsedMs >=
          durationMs - (_endSlackMs + elapsedMs ~/ 20);

  /// 0 to 1 over [share] 0 to 1; sin squared, so that the two ends are soft.
  static double _curve(double share) {
    final s = math.sin(math.pi / 2 * share);
    return s * s;
  }
}
